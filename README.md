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
- **Structured transcripts** (versioned JSON with word timings and talk-time
  stats, Markdown with front matter) and **exports** to any synced folder
  (Google Drive, Dropbox, iCloud, an Obsidian vault) and to a Notion
  database.

## Install

```sh
swift build -c release
sudo cp .build/release/mysli /usr/local/bin/mysli
mysli doctor                      # permissions, models, vocabulary, exports
mysli install --launch-at-login   # optional: run in the background on login
```

Requires macOS 15+ and Apple Silicon. `swift test` runs the unit tests for
the transcript logic (needs Xcode, since the Command Line Tools alone may not
ship XCTest).

## Use

1. Run `mysli`. The window opens and the feather appears in the menu bar.
2. Press **Start recording** (⌘R) when the call begins. The first run asks
   for microphone and System Audio Recording permission. The live transcript
   panel opens.
3. Press **Stop** when the call ends. The meeting shows as transcribing in
   the list and the transcript appears a few seconds later.

The window lists meetings by day. Selecting one shows its transcript with
timestamps, a talk-time bar, **Copy transcript** (as Markdown) and **Show in
Finder**. The gear button opens settings for language, live transcript, echo
removal, export folders and Notion; they apply from the next recording.
Closing the window leaves mysli in the menu bar, where **Open mysli…** brings
it back. When mysli starts at login it stays in the menu bar.

Each session lands in `~/Recordings/<yyyy.MM.dd-HHmm>/`:

| File | Contents |
|---|---|
| `mic.caf` | your side (default input device, AAC) |
| `system.caf` | the call audio (AAC) |
| `live.md` | the live draft, written as you go |
| `transcript.md` | the final transcript with YAML front matter |
| `transcript.json` | the same with word timings and stats (`mysli.transcript/2`) |
| `exports.json` | where the transcript was exported, or why it failed |
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

## Transcript format

`transcript.json` is the canonical record, meant for scripts and LLM
pipelines:

```json
{
  "schema": "mysli.transcript/2",
  "session": { "id": "2026.09.26-1400", "title": "Meeting 2026-09-26 14:00",
               "started_at": "2026-09-26T14:00:03+02:00", "ended_at": "…",
               "duration_seconds": 1805, "timezone": "Europe/Berlin" },
  "engine": { "name": "parakeet", "model": "parakeet-tdt-0.6b-v2-coreml",
              "vocabulary": true, "echo_filter": true, "echo_words_removed": 42 },
  "speakers": [
    { "id": "me", "label": "Me", "source": "microphone",
      "talk_seconds": 712.4, "talk_share": 0.46, "word_count": 1893, "segment_count": 120 },
    { "id": "them", "label": "Them", "source": "system_audio", "…": "…" }
  ],
  "segments": [
    { "id": 0, "speaker": "them", "start_ms": 1200, "end_ms": 3400,
      "text": "How is the launch going?",
      "words": [ { "text": "How", "start_ms": 1200, "end_ms": 1380 }, "…" ] }
  ],
  "created_at": "2026-09-26T14:31:10+02:00"
}
```

`transcript.md` carries the same session and speaker fields as YAML front
matter above the readable transcript, so Obsidian, Notion imports and LLMs
get the metadata without parsing JSON.

## Exports

Every new transcript is copied to the destinations under `exports` in the
config. Each session's `exports.json` records the result per destination; a
failed export (sync app not running, offline, Notion down) is retried the
next time mysli starts, and a finished one is never repeated.

**Google Drive, Dropbox, iCloud, Obsidian:** add the folder to
`exports.folders`. mysli writes `<session>.md` and `<session>.json` there and
the sync app does the rest, so no Google account setup is needed. With Google
Drive for desktop the path looks like
`~/Library/CloudStorage/GoogleDrive-you@gmail.com/My Drive/Meetings`. The
folder must exist; mysli won't create it, so a stopped sync app shows up as a
failed export instead of files landing in a dead folder. Audio is never
exported.

**Notion:** each transcript becomes a page in a database, titled with the
meeting time, with the summary line and the timestamped transcript as the
page body. If the database has a date property, the meeting's start and end
go there.

1. Create an internal integration at notion.so/profile/integrations and copy
   its token.
2. Store the token in the Keychain (it prompts, so the token stays out of
   your shell history):
   `security add-generic-password -s mysli.notion -a notion -w`
3. Create a database (any title property works; add a Date property if you
   want dates), open its `…` menu → Connections, and add the integration.
4. Put the database id (the 32-character id in its URL) in
   `exports.notion.database_id`.

`mysli doctor` checks that export folders exist and the token is present.
Adding a destination later doesn't upload old meetings; run
`mysli export ~/Recordings/*` to backfill.

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
  "exports": {
    "folders": [],
    "notion": { "database_id": null }
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
mysli                        # open the window and menu bar (^C to quit)
mysli run --background       # menu bar only (what the login agent runs)
mysli run --out <dir>        # custom recordings root
mysli doctor                 # check permissions, models, vocabulary, exports
mysli export <session>...    # export older sessions to the configured destinations
mysli install --launch-at-login
mysli install --uninstall
```

## Layout

- `Sources/MysliCore`: echo filter, sentence segmenter, vocabulary
  alignment, the transcript document and Notion payloads. Plain Foundation code with unit tests in `Tests/`.
- `Sources/mysli/Audio`: mic capture (AVAudioEngine) and system capture
  (Core Audio process tap), both streaming AAC into CAF so a crash loses
  nothing already written.
- `Sources/mysli/Live`: resampling feeds, the streaming recognizer and the
  live transcript model.
- `Sources/mysli/Transcription`: the batch queue, the Parakeet engine and
  vocabulary boosting.
- `Sources/mysli/Export`: folder and Notion exports.
- `Sources/mysli/UI`: menu bar and live panel.

All models run through [FluidAudio](https://github.com/FluidInference/FluidAudio)
on the Neural Engine and download on first use.
