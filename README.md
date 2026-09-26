# mysli

A local macOS meeting recorder for 1:1 calls. It records your mic and the
call audio as two separate tracks, shows a live transcript while you talk,
and writes a "me / them" transcript to disk when you stop. Nothing leaves
the Mac.

mysli is a fork of [quill](https://github.com/humanitas-labs/quill) (MIT).
On top of quill it adds:

- **Live transcript** in a floating panel that doesn't steal focus and is
  hidden from screen sharing.
- **Echo filter**, so that when you're on speakers the other person's words
  don't also show up as yours.
- **Scoped system audio**: media players (Spotify, Music and so on) are left
  out of the "them" track by default, or you can record only named apps.
- **Custom vocabulary** for names the model doesn't know (protocols, tokens,
  people, companies).
- **Parakeet v3** as an option for Finnish and 24 other European languages.

## Install

```sh
swift build -c release
sudo cp .build/release/mysli /usr/local/bin/mysli
mysli doctor                      # permissions, models, vocabulary
mysli install --launch-at-login   # optional: run in the background on login
```

Requires macOS 15+ and Apple Silicon. `swift test` runs the unit tests for
the transcript logic (needs Xcode, since the Command Line Tools alone may not
ship XCTest).

## Use

1. Run `mysli` (or let the LaunchAgent start it).
2. Click the feather in the menu bar and pick **Start recording**, or press
   ⌘R with the menu open. The first run asks for microphone and System Audio
   Recording permission. The live transcript panel opens.
3. Pick **Stop recording** when the call ends. The batch transcript is
   written a few seconds later and a notification fires.

**Show live transcript** (⌘L in the menu) reopens the panel.

Each session lands in `~/Recordings/<yyyy.MM.dd-HHmm>/`:

| File | Contents |
|---|---|
| `mic.caf` | your side (default input device, AAC) |
| `system.caf` | the call audio (AAC) |
| `live.md` | the live draft, written as you go |
| `transcript.md` | the final transcript, "me" and "them" with timestamps |
| `transcript.json` | the same, machine-readable |
| `meta.json` | start/end times, per-track start offsets |
| `transcribe.log` | what the transcription pass did, echo filter and vocabulary included |

The audio stays on disk, so you can re-run a better model over old meetings
later. Delete a session's `transcript.json` and restart mysli to redo it.

## How the transcript is made

Your mic is always "me" and the system audio is always "them", so a 1:1 needs
no speaker-recognition model.

**While recording**, each track streams through Parakeet EOU 120M, a small
English streaming model that commits a line when the speaker pauses. The
panel shows those lines plus what each person is saying right now. It's a
draft and less accurate than the final pass.

**After you stop**, both files go through Parakeet TDT 0.6B, which takes
roughly 20 seconds per hour of audio. Then:

1. The optional vocabulary pass fixes names (see below).
2. The echo filter removes mic words that repeat system words within about a
   second. It only removes runs of three or more matching words, or a whole
   utterance of two or more, so your own "yeah" and words you say over them
   are kept.
3. Words are grouped into sentences and the two tracks are merged by time.

On headphones the echo filter has nothing to do. On laptop speakers it
handles the bleed, and `mic_voice_processing: true` adds Apple's echo
canceller on top (see the config notes).

## Custom vocabulary

Parakeet takes no prompt, so a name it hasn't seen comes out as its nearest
English guess ("hyper liquid", "Igan layer"). Put the names in
`~/.config/mysli/vocabulary.txt`, one per line, optionally with known
mishearings after a colon:

```
Hyperliquid: hyper liquid
EigenLayer: eigen layer
Ethena
```

`examples/vocabulary.txt` has a starting list. On the first transcription
with a vocabulary, mysli downloads a small CTC model that checks each term
against the audio. A term replaces the transcript's words only when the
audio supports it better, so extra terms don't hurt. If short terms start
replacing ordinary words, launch mysli with `FLUID_SPOTTER_RESCUE=0` in its
environment to make the matching stricter.

## Config

Optional, at `~/.config/mysli/config.json`. Every key is optional; these are
the defaults:

```json
{
  "recordings_dir": "~/Recordings",
  "transcription": {
    "enabled": true,
    "model": "v2",
    "echo_filter": true,
    "vocabulary": "~/.config/mysli/vocabulary.txt"
  },
  "live": { "enabled": true, "show_window": true },
  "system_audio": {
    "exclude_apps": ["com.spotify.client", "com.apple.Music", "com.apple.podcasts",
                     "com.apple.TV", "com.apple.QuickTimePlayerX", "org.videolan.vlc",
                     "com.colliderli.iina"],
    "only_apps": []
  },
  "mic_voice_processing": false,
  "on_stop": null
}
```

- `transcription.model`: `"v2"` is English-only and the most accurate on
  English. `"v3"` covers 25 European languages including Finnish and German
  and detects the language per recording. The live view is English-only
  either way.
- `transcription.echo_filter`: turn off only if you suspect it's eating your
  own words; `transcribe.log` says how many words it dropped.
- `live.enabled`: turn off to skip the live pass (saves some CPU and battery).
  `live.show_window: false` keeps the panel closed until you open it.
- `system_audio.exclude_apps`: bundle-id prefixes left out of the "them"
  track. Prefixes match helper processes too, so `com.google.Chrome` covers
  `com.google.Chrome.helper`.
- `system_audio.only_apps`: if set, record only these apps, for example
  `["us.zoom.xos", "com.google.Chrome"]`. Safari plays audio from
  `com.apple.WebKit.GPU`, so list that for calls in Safari. Check a test
  recording before relying on this mode: if the meeting app's audio process
  isn't matched, the "them" track is silent.
- `mic_voice_processing`: Apple's echo canceller on the mic. Useful on
  speakers; while it runs, macOS ducks other playback slightly.
- `on_stop`: shell command run with the session folder as its argument once
  the transcript exists. Wire it to summaries, filing or indexing.

## CLI

```sh
mysli                        # run the menu-bar daemon (^C to quit)
mysli run --out <dir>        # custom recordings root
mysli doctor                 # check permissions, models, vocabulary
mysli install --launch-at-login
mysli install --uninstall
```

## Layout

- `Sources/MysliCore`: echo filter, sentence segmenter and vocabulary
  alignment. Plain Foundation code with unit tests in `Tests/`.
- `Sources/mysli/Audio`: mic capture (AVAudioEngine) and system capture
  (Core Audio process tap), both streaming AAC into CAF so a crash loses
  nothing already written.
- `Sources/mysli/Live`: resampling feeds, the streaming recognizer and the
  live transcript model.
- `Sources/mysli/Transcription`: the batch queue, the Parakeet engine and
  vocabulary boosting.
- `Sources/mysli/UI`: menu bar and live panel.

All models run through [FluidAudio](https://github.com/FluidInference/FluidAudio)
on the Neural Engine and download on first use.
