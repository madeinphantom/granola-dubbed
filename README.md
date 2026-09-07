# Atrium

Local-first meeting recorder for macOS. Records system audio + microphone, transcribes with WhisperKit, and identifies speakers using dual-channel VAD.

**Requires:** macOS 15.0+ · Apple Silicon

## Architecture

```
Atrium/
├── Application/         SessionController, ExportService, PermissionService
├── Capture/             SystemAudioTap, MicCapture, SCKFallback, AudioRingBuffer, SessionWriter
├── Features/            SwiftUI views — ContentView, MenuBar, RecPill, Player
├── Inference/           ASREngine (WhisperKit), DualChannelAssigner, TranscriptAligner
└── Persistence/         SwiftData models (Meeting, Speaker), AudioStore
```

## How it works

1. **Dual capture.** `SystemAudioTap` intercepts system audio via a private `CATapDescription` + aggregate device (pre-volume, 48kHz stereo). `MicCapture` uses AVAudioEngine with Voice Processing for mic. Both feed into lock-free `AudioRingBuffer` instances.
2. **Fallback.** If the CoreAudio tap fails (permissions, older macOS), the app falls back to `SCKFallbackCapture` using ScreenCaptureKit.
3. **Writing.** `SessionWriter` polls the ring buffers at 50ms intervals and writes to `you.caf` (mic) and `them.caf` (system). On stop, it muxes both into a single `session.m4a` via `AVAssetExportSession`.
4. **Transcription.** `ASREngine` runs WhisperKit (large-v3-turbo) on the M4A file. `DualChannelAssigner` calculates RMS energy on each track using Accelerate (`vDSP_rmsqv`) to determine who's speaking when.
5. **Alignment.** `TranscriptAligner` maps ASR words to speaker turns by overlap, producing speaker-attributed `TranscriptSegment`s.
6. **Storage.** Everything persists to `~/Library/Application Support/Atrium/Sessions/<uuid>/` with a `transcript.json` alongside the audio files. SwiftData manages the meeting index.

## Build

```bash
# Install xcodegen if not present
brew install xcodegen

# Generate Xcode project
xcodegen

# Open and build
open Atrium.xcodeproj
# Set your Development Team in Signing & Capabilities
# ⌘R to build and run
```

Requires a full Xcode install (not just Command Line Tools) — SwiftData's `@Model`
macro and the WhisperKit SPM dependency are both resolved by Xcode.

Run the unit tests with:

```bash
xcodebuild test -scheme Atrium -destination 'platform=macOS'
```

## Menu Bar

Atrium lives in the menu bar as a waveform icon, which turns into a red record
indicator while recording. Click it to start/stop and see recent sessions. The
app also keeps a normal window and Dock icon (`LSUIElement` is `false`); set it
to `true` in `project.yml` for a menu-bar-only tool.

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| ⌘R | Start / stop recording |
| Space | Play / pause audio |

## Export Formats

- **Markdown** — Speaker-attributed transcript with timestamps
- **JSON** — Full `TranscriptDocument` with word-level timing
- **SRT** — Standard subtitle format
- **TXT** — Plain `[MM:SS] Speaker: text`

## Privacy & Consent

Atrium requires:
- **Microphone access** — to record your voice
- **Screen recording** — to capture system audio (SCK fallback path)

Recording starts immediately on ⌘R — there is no onboarding or consent gate.
You are responsible for notifying participants where the law requires it.

## Notarization (Distribution)

Create an `ExportOptions.plist` for Developer ID distribution first (it is not
checked in, since it carries your team ID):

```bash
xcodebuild -scheme Atrium -configuration Release archive -archivePath build/Atrium.xcarchive
xcodebuild -exportArchive -archivePath build/Atrium.xcarchive -exportPath build/ -exportOptionsPlist ExportOptions.plist
xcrun notarytool submit build/Atrium.dmg --apple-id YOUR_ID --team-id YOUR_TEAM --password YOUR_APP_SPECIFIC_PASSWORD --wait
xcrun stapler staple build/Atrium.dmg
```

The app runs with the hardened runtime and is **not** sandboxed (the CoreAudio
process tap and aggregate-device APIs are unavailable inside the App Sandbox),
so it is distributable via Developer ID but not the Mac App Store.

## Status

Working: dual capture (CoreAudio process tap + SCK fallback), session writing and
muxing, WhisperKit transcription, energy-based You/Them attribution, transcript
alignment, playback, and all four export formats.

Not yet implemented: neural diarization for splitting multiple remote speakers.
`SortformerDiarizer` is scaffolding only — it loads a CoreML model if one is
present but its `diarize` method returns no segments and is not yet wired into
the pipeline. Remote speakers are currently attributed as a single "Them".
