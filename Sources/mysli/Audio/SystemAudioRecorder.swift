import AVFoundation
import CoreAudio
import Foundation

/// Records system audio output to a file via a Core Audio process tap
/// (macOS 14.2+). No virtual device, no kernel extension — the tap mixes the
/// selected processes' output to stereo and hands us buffers through a
/// private aggregate device. First use triggers the one-time "System Audio
/// Recording" TCC prompt and lights the purple recording indicator while
/// active.
///
/// Which processes the tap hears is a `TapScope`: by default everything
/// except media players, or only the listed apps. Processes come and go
/// during a meeting (a browser spins up its audio helper when the call
/// connects), so the tap's process list follows Core Audio's process list
/// for the whole session.
final class SystemAudioRecorder: @unchecked Sendable {
    enum RecorderError: Error, CustomStringConvertible {
        case tapCreationFailed(OSStatus)
        case tapFormatUnreadable(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case deviceStartFailed(OSStatus)
        case fileCreationFailed(Error)

        var description: String {
            switch self {
            case .tapCreationFailed(let s):
                return "process tap creation failed (OSStatus \(s)) — check System Settings → Privacy & Security → Screen & System Audio Recording"
            case .tapFormatUnreadable(let s): return "couldn't read tap stream format (OSStatus \(s))"
            case .aggregateCreationFailed(let s): return "aggregate device creation failed (OSStatus \(s))"
            case .ioProcCreationFailed(let s): return "IO proc creation failed (OSStatus \(s))"
            case .deviceStartFailed(let s): return "device start failed (OSStatus \(s))"
            case .fileCreationFailed(let e): return "output file creation failed: \(e)"
            }
        }
    }

    private let scope: TapScope
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapDescription: CATapDescription?
    private var tappedProcesses: [AudioObjectID] = []
    private var processListListener: AudioObjectPropertyListenerBlock?
    private var tapUpdateFailed = false
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "com.jommi9.mysli.system-tap")
    private(set) var isRecording = false
    /// Wall-clock time of the first captured buffer — the track's true start,
    /// used to offset-align the two tracks' transcript timestamps.
    private(set) var firstBufferAt: Date?

    /// Start capturing system audio, encoding AAC into `url` (use a .caf
    /// extension — CAF needs no finalization pass, so a crash mid-meeting
    /// loses nothing already written).
    init(scope: TapScope = .fromConfig()) {
        self.scope = scope
    }

    func start(writingTo url: URL) throws {
        guard !isRecording else { return }

        let processes = scope.matchingProcesses()
        let description = scope.isInclusive
            ? CATapDescription(stereoMixdownOfProcesses: processes)
            : CATapDescription(stereoGlobalTapButExcludeProcesses: processes)
        description.name = "mysli system tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else { throw RecorderError.tapCreationFailed(status) }
        tapID = newTapID
        tapDescription = description
        tappedProcesses = processes
        FileHandle.standardError.write(Data(
            "system tap: \(scope.summary) · \(processes.count) matching process(es) now\n".utf8
        ))

        do {
            let format = try tapStreamFormat()
            try createAggregateDevice(tapUUID: description.uuid)
            file = try makeFile(url: url, format: format)
            try installIOProc(format: format)
            watchProcessList()
        } catch {
            cleanup()
            throw error
        }

        isRecording = true
    }

    /// Stop capturing and finalize the file. Idempotent.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
        }
        cleanup()
    }

    // MARK: -

    private func tapStreamFormat() throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw RecorderError.tapFormatUnreadable(status)
        }
        return format
    }

    private func createAggregateDevice(tapUUID: UUID) throws {
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "mysli-tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &newAggregateID)
        guard status == noErr else { throw RecorderError.aggregateCreationFailed(status) }
        aggregateID = newAggregateID
    }

    private func makeFile(url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ]
        do {
            return try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        } catch {
            throw RecorderError.fileCreationFailed(error)
        }
    }

    private func installIOProc(format: AVAudioFormat) throws {
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
            [weak self] _, inInputData, _, _, _ in
            guard let self, let file = self.file else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: inInputData,
                deallocator: nil
            ) else { return }
            do {
                try file.write(from: buffer)
            } catch {
                FileHandle.standardError.write(Data("system track write failed: \(error)\n".utf8))
            }
        }
        guard status == noErr, let procID else { throw RecorderError.ioProcCreationFailed(status) }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw RecorderError.deviceStartFailed(status) }
    }

    /// Re-evaluate the scope whenever Core Audio's process list changes and
    /// push the new process set into the live tap.
    private func watchProcessList() {
        var address = Self.processListAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshTappedProcesses()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, listener
        )
        if status == noErr {
            processListListener = listener
        } else {
            FileHandle.standardError.write(Data(
                "warning: can't watch audio processes (OSStatus \(status)) — tap scope fixed at start\n".utf8
            ))
        }
    }

    /// Runs on `queue`.
    private func refreshTappedProcesses() {
        guard !tapUpdateFailed, tapID != kAudioObjectUnknown, let description = tapDescription else { return }
        let processes = scope.matchingProcesses()
        guard processes != tappedProcesses else { return }

        description.processes = processes
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = description
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(
                tapID, &address, 0, nil,
                UInt32(MemoryLayout<CATapDescription>.size), pointer
            )
        }
        if status == noErr {
            tappedProcesses = processes
            FileHandle.standardError.write(Data(
                "system tap: now \(processes.count) matching process(es)\n".utf8
            ))
        } else {
            // Keep recording with the set we have rather than retrying on
            // every process-list change.
            tapUpdateFailed = true
            FileHandle.standardError.write(Data(
                "warning: tap update failed (OSStatus \(status)) — keeping the process set from start\n".utf8
            ))
        }
    }

    private static var processListAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func cleanup() {
        if let listener = processListListener {
            var address = Self.processListAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, listener
            )
            processListListener = nil
            // Let a refresh already running on the queue finish before the
            // tap it touches is destroyed.
            queue.sync {}
        }
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        tapDescription = nil
        tappedProcesses = []
        tapUpdateFailed = false
        file = nil
    }
}
