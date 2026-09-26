import CoreAudio
import Foundation

/// Which processes the system-audio tap records, by bundle-id prefix.
/// Prefixes rather than exact ids because apps play audio from helper
/// processes: Chrome's is `com.google.Chrome.helper`, Teams' and Slack's
/// follow the same pattern.
struct TapScope: Sendable {
    /// Non-empty: record only processes matching these (include mode).
    let onlyApps: [String]
    /// Include mode off: record everything except processes matching these.
    let excludedApps: [String]

    var isInclusive: Bool { !onlyApps.isEmpty }

    static func fromConfig() -> TapScope {
        TapScope(
            onlyApps: Config.systemAudioOnlyApps(),
            excludedApps: Config.systemAudioExcludedApps()
        )
    }

    var summary: String {
        isInclusive
            ? "only \(onlyApps.joined(separator: ", "))"
            : "all apps except \(excludedApps.isEmpty ? "none" : excludedApps.joined(separator: ", "))"
    }

    /// Audio process objects the tap's process list should hold right now:
    /// the included apps in include mode, the excluded ones otherwise.
    func matchingProcesses() -> [AudioObjectID] {
        let prefixes = isInclusive ? onlyApps : excludedApps
        guard !prefixes.isEmpty else { return [] }
        return Self.audioProcesses()
            .filter { process in
                guard let bundleID = process.bundleID else { return false }
                return prefixes.contains { bundleID.hasPrefix($0) }
            }
            .map(\.id)
            .sorted()
    }

    /// Every process Core Audio currently tracks as an audio client.
    static func audioProcesses() -> [(id: AudioObjectID, bundleID: String?)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.map { ($0, bundleID(of: $0)) }
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        let id = value.takeRetainedValue() as String
        return id.isEmpty ? nil : id
    }
}
