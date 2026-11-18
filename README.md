# Atrium

Local-first call recorder for macOS. Records your microphone and your Mac's
audio as two tracks, then transcribes each track on-device with WhisperKit.
Your track is "Me", the call's track is "Them".

**Requires:** macOS 15.0+ · Apple Silicon · Xcode Command Line Tools
(`xcode-select --install`; full Xcode also works).

## Use

Atrium lives in the menu bar. Press **⌃⌥⌘R** (or use the menu) to start and
stop recording. Transcription runs when you stop; the Whisper model
(`openai_whisper-large-v3_turbo`, about 1 GB) downloads on first use.

Each call gets its own folder, named after what was said, holding two files
with the same name:

```
~/Documents/Atrium/Pricing review/
├── Pricing review.mp4    both sides of the call, mixed (about 30 MB per hour)
└── Pricing review.md     the transcript, speaker by speaker
```

Apple's on-device model writes the title once the call is transcribed;
nothing leaves the Mac. Without it (macOS 15, or Apple Intelligence off) a
call keeps its date name, `Call 2026-11-17 at 16.01.18`.

While a call is recorded and transcribed the folder holds the raw tracks
(`me.caf`, `them.caf`). If transcription fails they stay, with
`transcription-error.txt`, until you retry from the menu.

A smaller model: `defaults write app.atrium.mac WhisperModel openai_whisper-small`.

## Install

```bash
./scripts/install-cli.sh   # once: puts `atrium` on your PATH
atrium install             # build, sign, copy to /Applications, launch
atrium selftest            # prove the installed app works end to end
```

| Command | Does |
|---|---|
| `atrium build` | Build `dist/Atrium.app` |
| `atrium install` | Build, then install to `/Applications` and launch |
| `atrium test` | Run the unit tests |
| `atrium selftest` | Record a spoken phrase and a test tone through your speakers with the installed app, transcribe, and check every stage |
| `atrium update` | `git pull`, then install |

Run `atrium selftest` after every install. It is the only check that runs the
real capture and transcription on real hardware.

## Permissions

Atrium needs **Microphone** and **Screen & System Audio Recording** (the
latter is how macOS gates system-audio capture; Atrium never records the
screen). macOS applies a new Screen & System Audio Recording grant only after
the app relaunches.

### Keep permissions across updates

macOS ties permission grants to the app's code signature. An ad-hoc signature
changes on every build, so every rebuild would silently lose system audio.
`atrium build` signs with the identity named "Atrium Self-Signed Code
Signing" when your keychain has one; its designated requirement pins the
certificate, so grants survive rebuilds. Create it once:

```bash
cat > cs.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Atrium Self-Signed Code Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cs.cnf
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -out id.p12 -passout pass:atrium
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P atrium -T /usr/bin/codesign
rm key.pem id.p12 cs.cnf cert.pem
```

The certificate does not need to be trusted. `ATRIUM_SIGNING_IDENTITY`
overrides the identity name.

## How it works

```
Sources/
├── AtriumCore/          Recording and transcription. No UI.
│   ├── Capture/         SystemAudioTap, SystemAudioConverter, MicCapture,
│   │                    AudioRingBuffer, CallRecorder
│   ├── Transcription/   SpeechRecognizer (WhisperKit), CallProcessor, Transcript
│   ├── SessionStore     Call folders and their state
│   └── ToneAnalysis     Test-tone checks used by the self-test
└── Atrium/              The menu bar app: StatusMenu, AppController,
                         GlobalHotKey, Permissions, SelfTest
```

1. **Capture.** `SystemAudioTap` taps system audio with a CoreAudio process
   tap in a tap-only aggregate device; `SystemAudioConverter` converts whatever
   the tap delivers to 48 kHz. `MicCapture` records the microphone and converts
   it to the same format. Both feed lock-free ring buffers that `CallRecorder`
   drains to `me.caf` and `them.caf`, padding whichever track started late so
   both share the same start.
2. **Transcribe.** `CallProcessor` transcribes each track separately; the
   speaker comes from the track. Echo of the other side picked up by the mic
   is dropped. Calls left untranscribed when Atrium quit are resumed at launch.
3. **Compress.** Once the transcript is written, both raw tracks are mixed
   into one 64 kbps AAC `.mp4` and deleted.
4. **Name.** `CallTitler` asks the on-device model what the call was about,
   and the folder and both files are renamed to that title.

The app runs with the hardened runtime and is not sandboxed: CoreAudio process
taps are unavailable inside the App Sandbox.

## Privacy & consent

Everything stays on your Mac. Recording starts as soon as you press the
shortcut; you are responsible for telling participants where the law requires
it.

## Known limits

- Everyone on the far side of the call is one speaker, "Them".
- Not notarized. A downloaded build needs
  `xattr -dr com.apple.quarantine /Applications/Atrium.app` before it opens.
