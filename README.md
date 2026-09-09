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

Requires a full Xcode install (not just Command Line Tools): SwiftData's
`@Model` macro needs the `SwiftDataMacros` plugin, which ships only with Xcode.
(WhisperKit itself resolves fine under plain SwiftPM.)

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

## Download

Grab `Atrium.dmg` from the [latest release](../../releases/latest).

These builds are **not notarized**. No Apple Developer account is needed to
build, publish, or run Atrium — this is the normal situation for an open-source
Mac app. macOS just quarantines downloaded unsigned apps, so after dragging
Atrium to Applications:

```bash
xattr -dr com.apple.quarantine /Applications/Atrium.app
```

Then right-click the app → **Open** → **Open**. Grant Microphone and Screen
Recording when prompted.

Because these builds are ad-hoc signed, macOS identifies the app by a hash that
changes with every release. Privacy permissions are tied to that hash, so
**after each update you may need to re-grant Microphone and Screen Recording**
(System Settings → Privacy & Security). A Developer ID certificate would give
the app a stable identity and remove both this and the quarantine step, but it
is not required to use or distribute Atrium.

## Updates

Atrium checks for updates on launch and via **Atrium ▸ Check for Updates…**
(also in Settings ▸ General). Updates are delivered by
[Sparkle](https://sparkle-project.org) and install in place.

Because these builds are ad-hoc signed, each update changes the app's code
signature, so **macOS will ask you to re-grant Microphone and Screen Recording
after updating**. A Developer ID certificate would remove this.

### Enabling signed updates (maintainer)

The release workflow publishes an `appcast.xml` only when the
`SPARKLE_PRIVATE_KEY` secret is set. Without it the DMG still ships and
in-app updates stay inactive. To enable:

```bash
# Export the private key generated by Sparkle's generate_keys
./bin/generate_keys -x sparkle_priv.key
gh secret set SPARKLE_PRIVATE_KEY < sparkle_priv.key
rm sparkle_priv.key   # keep only the keychain copy
```

The matching public key is already in `project.yml` as `SUPublicEDKey`.

## Release

`.github/workflows/release.yml` builds an **unsigned** DMG on any `v*` tag (or
via workflow_dispatch) and publishes it to GitHub Releases — no certificate
required.

For a properly notarized build, `scripts/release.sh` archives, signs, notarizes,
staples, and verifies a Developer ID DMG. Copy `ExportOptions.plist.template` to `ExportOptions.plist`
and set your team ID first, then store a notarytool profile:

```bash
xcrun notarytool store-credentials atrium-notary \
  --apple-id YOU@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD
```

CI (`.github/workflows/ci.yml`) builds and tests on every push.

## Status

Working: dual capture (CoreAudio process tap + SCK fallback), session writing and
muxing, WhisperKit transcription, energy-based You/Them attribution, transcript
alignment, playback, and all four export formats.

The ASR path is verified end-to-end against real WhisperKit on real audio:
`openai_whisper-large-v3_turbo` transcribes with word-level timings and the
transcript comes back free of Whisper's special tokens.

Not yet implemented: neural diarization for splitting multiple remote speakers.
`SortformerDiarizer` is scaffolding only — it loads a CoreML model if one is
present but its `diarize` method returns no segments and is not yet wired into
the pipeline. Remote speakers are currently attributed as a single "Them".
