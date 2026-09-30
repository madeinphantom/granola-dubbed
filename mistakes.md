# Mistakes

Append-only log of lessons from previous failures in this repo.

## 2026-09-07 — Swift stops typechecking function bodies after a file-level error

**What happened.** Compiling `Atrium/Capture/*.swift` together reported only 1
error, while compiling `SystemAudioTap.swift` alone reported 16. The single
error in `DualCaptureSession.swift` halted the compiler before it typechecked
the other files' function bodies, hiding six genuine errors in the system-audio
tap — the core capture path.

**Why it matters.** "The build only has one error left" was false comfort. A
low error count after a batch compile is not evidence of health; it can mean
the compiler gave up early.

**How to apply.** When fixing Swift compile errors, re-run the build after each
fix and expect the error count to *rise* as earlier blockers clear. Do not
conclude a target is close to building from a shrinking error list alone.

## 2026-09-07 — CoreAudio constants were near-miss invented names

**What happened.** `kAudioAggregateDeviceMainSubdeviceKey` and
`kAudioAggregateDeviceSubdeviceListKey` do not exist. The real names capitalise
Device: `...MainSubDeviceKey`, `...SubDeviceListKey`. `AudioDeviceIOBlock` was
also written with 6 parameters when it takes 5, and the frame count passed to
the handler was the placeholder `mSampleTime.isFinite ? 0 : 0` — zero on both
branches, so no audio would ever have been captured.

**How to apply.** For C-family Apple APIs, grep the SDK headers
(`$(xcrun --show-sdk-path)/System/Library/Frameworks/...`) to confirm symbol
spelling and arity before trusting recalled signatures. A ternary whose two
branches are identical is a placeholder, not logic.

## 2026-09-07 — Build config referenced assets that do not exist

**What happened.** `project.yml` set `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`
with no `.xcassets` anywhere in the repo, and `Atrium.entitlements` was an empty
`<dict/>` despite hardened runtime being enabled and the app needing microphone
access.

**How to apply.** Treat build settings as claims to verify against the
filesystem, not as inert configuration.

## 2026-09-07 — Aligner silently discarded every word when speaker detection failed

**What happened.** `TranscriptAligner.align` dropped any word that overlapped no
speaker turn. If `DualChannelAssigner` returned no turns — both tracks quiet,
a missing `them.caf`, or energy below threshold — all ASR words were discarded.
The pipeline then wrote an empty `transcript.json`, set `state = .ready`, and
reported success. A full meeting would transcribe to nothing, with no error.

**Why it matters.** The failure is invisible at exactly the moment it costs
most: after a real call, when the audio is already gone. Silent data loss is
worse than a crash.

**How to apply.** When a stage filters records, ask what happens when the
filter's input is empty or degraded. Default to preserving data with a fallback
attribution rather than dropping it. Never mark a result `.ready` without
asserting it is non-empty.

## 2026-09-07 — Fixed-size drain loop could never catch up with a jittery producer

**What happened.** `SessionWriter.startPolling` read exactly 2400 frames (50ms)
per tick, then slept 50ms. `Task.sleep` guarantees only a *minimum* delay, so
ticks routinely run late and more than one chunk accumulates — but the consumer
could only ever remove one. Simulated with 10% late ticks, 2.0s of audio was
permanently stranded in the buffer after 200 ticks. Sustained, the 10s ring
buffer overflows and `AudioRingBuffer.write` discards the oldest frames
returning Void — no error, no counter, nothing to observe.

**Why it matters.** Two silent-loss mechanisms stacked: a consumer that cannot
drain, and a buffer that discards without reporting. The recording just has
gaps.

**How to apply.** A drain loop must consume *all available* data per tick, never
a fixed quantum sized to the average production rate — there is no headroom to
recover from jitter. Any lossy buffer must count what it discards and something
must read that counter.

## 2026-09-08 — "Needs Xcode" was half wrong, and the untested half hid four bugs

**What happened.** I claimed the project could not be verified without Xcode.
Only half true: SwiftData's `@Model` macro genuinely requires the
`SwiftDataMacros` plugin that ships with Xcode, but **WhisperKit builds fine
under plain SwiftPM**. Because I accepted the blanket claim, `ASREngine` was
"verified" against a hand-written stub instead of the real library — and the
stub agreed with whatever I wrote. Building it against actual WhisperKit found
four bugs in ~40 lines:

1. `progressInfo.progress` — no such member; the callback returns `Bool?`, not Void.
2. `wordTimestamps` defaults to **false**, so `segment.words` was always nil.
   Every meeting would have produced an empty transcript.
3. `result?.segments` — overload resolution returned `[TranscriptionResult]`,
   so only the first chunk would have been used.
4. The model name `openai_whisper-large-v3-turbo` does not exist (the real one
   uses an underscore: `..._turbo`), and an explicit name is used verbatim as a
   download path with no validation or fallback.

Running it on real audio then exposed a fifth: segment text arrives with raw
Whisper special tokens (`<|startoftranscript|>`, `<|en|>`, `<|0.00|>`) that
would have been written into transcripts and exports.

**How to apply.** Test the blocking claim before accepting it — "I need X" is
itself a hypothesis. Never verify integration code against a stub you wrote:
the stub encodes your assumptions, so it confirms them. Pull the real dependency
even when the full app cannot be built, and run it on real input.

## 2026-09-08 — Delete path could have wiped all of Application Support

**What happened.** `AudioStore.delete` built the directory to remove from
`meeting.audioMixRelativePath`:

```swift
appSupport.appendingPathComponent("Atrium/\(meeting.audioMixRelativePath)")
          .deletingLastPathComponent()
```

For a normal meeting that path is `Sessions/<uuid>/session.m4a`, so this
correctly resolves to the session directory. But `audioMixRelativePath` defaults
to `""` on `Meeting`, and `"Atrium/" + ""` then `deletingLastPathComponent()`
resolves to **Application Support itself** — `removeItem` would recursively
delete every application's data on the Mac.

Only one construction site sets the property, so the state was not reachable
today. It was one careless `Meeting(...)` away from being reachable, and the
blast radius was the user's whole machine.

**How to apply.** Never derive a destructive path by trimming a string field
whose empty value walks *up* the tree. Derive it from an identifier that cannot
be empty, and add a containment check asserting the target is strictly inside
the directory you own before calling `removeItem`. Treat every delete path as
hostile input, including your own model's defaults.

## 2026-09-09 — A stub that was "close enough" hid a build-breaking error

**What happened.** CI failed with:

```
ContentView.swift:240: error: generic struct 'ObservedObject' requires that
'Meeting' conform to 'ObservableObject'
```

`@ObservedObject var meeting: Meeting` is wrong for a SwiftData model: `@Model`
expands to `Observable` + `PersistentModel`, never `ObservableObject`. My local
shim stripped `@Model` down to a **plain class**, which happens to satisfy
`ObservedObject`'s constraint — so the shim accepted code the real macro
rejects.

Changing the shim to `@Observable` reproduced the failure locally.

**How to apply.** When stubbing a macro or dependency, model its *conformances*,
not just its shape. A stub that is more permissive than the real thing silently
grants permission the compiler would deny. If a stub cannot express the real
constraints, treat everything that depends on it as unverified and get it onto
real CI early — this is the second time in this project that a stub manufactured
false confidence (see the WhisperKit entry).

## 2026-09-09 — xcodegen silently reverted the entitlements file

**What happened.** I edited `Atrium/Atrium.entitlements` to add
`com.apple.security.device.audio-input`, and the commit claimed it. But
`project.yml` declared `entitlements.path` with no `properties`, so **xcodegen
regenerates that file as an empty `<dict/>` on every run** — wiping the edit.
The commit captured the empty version, CI signed it faithfully, and the shipped
DMG had no entitlements at all. Microphone capture would have failed at runtime
on every user's machine.

Only inspecting the actual downloaded artifact caught it:
`codesign -d --entitlements :- Atrium.app` → `<dict></dict>`.

**How to apply.** For generated projects, edit the *generator's* input
(`project.yml`), never the generated output — the output is a build artifact and
will be overwritten. And verify security-relevant settings on the **built,
signed artifact**, not in the source tree: the release workflow now greps the
signed app's entitlements and fails if `audio-input` is absent.

## 2026-09-11 — First real recording failed: pids are not AudioObjectIDs

**What happened.** The first real test call produced `you.caf` with 64.5s of
microphone audio and `them.caf` with **0 frames**. Transcription then failed
with "Resource path does not exist … session.m4a".

Two independent bugs:

1. `CATapDescription(stereoGlobalTapButExcludeProcesses:)` takes
   **AudioObjectIDs**, not Unix pids. The app passed `getpid()`, so
   `AudioHardwareCreateProcessTap` returned `kAudioHardwareBadObjectError`
   ('!obj', 560947818) and the tap never started. Proven by probe: excluding
   `[]` succeeds, excluding `[getpid()]` fails; pid 82074 translates to
   AudioObjectID 149 via `kAudioHardwarePropertyTranslatePIDToProcessObject`.

   Earlier I "fixed" this line by changing `Int($0)` to `AudioObjectID($0)`,
   which made it **compile** while leaving it semantically wrong. A cast that
   silences a type error is not a fix.

2. `muxToM4A` guarded `themAsset.loadTracks(...).first` with `else { return }`.
   An empty them.caf has no track, so the mux silently returned, never wrote
   `session.m4a`, and `stopAndFinalize` reported success. One failed input
   discarded a whole good recording.

**How to apply.** A CoreAudio OSStatus is a FourCC — decode it
(`560947818` → `'!obj'`) instead of treating it as an opaque number. When an
API takes an opaque integer id, confirm what *kind* of id it wants; identical
Swift types do not imply identical semantics. And never let one empty input
cause a silent `return` in a pipeline that has already captured unrecoverable
data — degrade to what succeeded and report the rest.

## 2026-09-11 — Audio taps are gated by Screen Recording consent, and fail SILENTLY

**What happened.** After fixing the pid→AudioObjectID bug, the tap started
successfully and delivered 275 callbacks / 140800 frames — but **every sample
was zero**. The aggregate device was configured correctly (1 input buffer, 2
channels) and the tap format matched exactly what the app assumed (48kHz stereo
interleaved Float32). Nothing reported an error.

The cause: CoreAudio process taps require the same TCC consent as screen
capture. Without it macOS does not fail the tap — it delivers **silent
buffers**. `CGPreflightScreenCaptureAccess()` returned false.

Worse, `PermissionService.checkScreenCapture()` already existed but was **never
called**. `startRecording` only checked the microphone, so the app cheerfully
recorded meetings with system audio silently zeroed.

**How to apply.** When a capture API "works" but produces zeroes, suspect
permission before suspecting format or configuration — TCC-gated media APIs
routinely degrade to silence/black frames rather than erroring. And an
unreferenced permission check is not a permission check: grep for call sites,
not just definitions.

## 2026-09-11 — Voice processing changes the input format; reading it first loses 83% of the mic

**What happened.** With system audio finally working, a ~6 minute recording
produced `them.caf` at 370.15s (correct) and `you.caf` at 61.4s — a 6x
discrepancy. The tap was measured at 0.97x real time, so capture was fine.

`MicCapture` did:

```swift
let format = input.inputFormat(forBus: 0)      // read FIRST
try input.setVoiceProcessingEnabled(true)      // then enabled
input.installTap(onBus: 0, bufferSize: 1024, format: format) { ... }
```

Enabling voice processing **changes the input node's format**: measured 1ch
before, **9ch after** on the built-in mic. The tap was installed with the stale
1-channel format, and `handleMicAudio` read only `channelData[0]`, so most of
the microphone audio never reached the ring buffer.

Fix: enable voice processing first, read the format after, and downmix
multi-channel input to mono. Verified 1.00x real time over a steady-state
window.

**How to apply.** Configuring an audio node can renegotiate its format. Always
read the format *after* every configuration call, never before. And when two
parallel tracks of the same recording disagree in duration, measure each
capture path independently — the shorter one is not necessarily the broken one,
but the ratio points straight at a channel-count or sample-rate assumption.

## 2026-09-14 — Hosted unit tests launched the whole app, hanging headless CI

**What happened.** CI's Build step passed but Test hung indefinitely (11+
minutes, repeatedly). I first blamed the two new hardware tests and skipped
them; it still hung. The actual cause was structural: `AtriumTests` depends on
the `Atrium` app target, so running tests **launches the app**, which starts
Sparkle's updater (`startingUpdater: true`, spawning XPC services and a network
check), sets an activation policy, and runs session recovery. None of that
completes on a headless runner.

**How to apply.** Guessing which test hangs wastes runs. Ask instead what the
test *host* does at launch — hosted macOS unit tests execute the full app
lifecycle before a single test runs. Anything the app starts automatically
(updaters, XPC, network schedulers, window setup) must be suppressed under
XCTest. Detect with `NSClassFromString("XCTestCase") != nil` or the
`XCTestConfigurationFilePath` environment variable.

Also: always bound a CI step with `timeout-minutes`. An unbounded hang costs a
runner and gives no diagnostic, whereas a timeout at least fails fast.

## 2026-09-14 — `xcodebuild` does not forward the shell environment to tests

**What happened.** After fixing the app-launch hang, CI still timed out. The log
named the culprit exactly: `MicCaptureFormatTests` started, then CoreAudio spun
for 8 minutes — `HALC_ShellObject::HasProperty: call to the proxy failed`,
then `throwing -10877`. The `XCTSkipUnless(environment["CI"] == nil)` guard
never fired, because `xcodebuild` does not pass the shell environment into the
test process.

**Then that failed too.** Querying CoreAudio for a default input device returns
**true** on GitHub's macOS runners — they expose a virtual device — so the skip
never fired and `setVoiceProcessingEnabled` still hung in the HAL.

**How to apply.** There is no reliable probe that distinguishes real audio
hardware from a runner's virtual device. A test that must drive the audio HAL
does not belong in CI at all. Delete it and pin the part that is actually ours:
the downmix arithmetic that made the bug destructive. Behaviour of the OS is
Apple's to test; behaviour of our code is ours. Three CI runs were spent
learning this.

Also: read the failing log before theorising. The first hang I blamed on these
tests and was wrong (it was the app host); the second genuinely was them, and
the log said so in both cases.

## 2026-09-30 — Why Atrium kept "failing" release after release

**Root cause, two parts.**

1. **Ad-hoc signing revoked permissions on every update.** TCC keys
   Microphone/Screen Recording grants on the code signature's designated
   requirement. Ad-hoc signatures embed a per-build CDHash, so each new release
   was a new app to macOS. Screen Recording silently lapsed, the process tap
   delivered silence, and the user saw "failed" again. Fixed by signing
   releases with a fixed self-signed identity (secret `ATRIUM_SIGNING_P12`),
   which keeps the designated requirement stable. No Apple account needed.

2. **No release was ever tested with a real recording.** Every bug was found by
   the user after shipping. Fixed with `--selftest`: the installed app records
   while `say` speaks a known phrase, transcribes, checks both tracks and the
   transcript, writes a JSON report, deletes the recording, and quits.
   **Run it before calling any release done:** `atrium selftest`.

## 2026-09-30 — Mic sample rate is whatever voice processing negotiates

The first passing-transcript self-test still flagged you.caf at 3.8 s against
them.caf at 8.15 s. Voice processing on this Mac delivered **24 kHz / 3ch**
(an earlier session had delivered 48 kHz / 9ch), and those frames were written
into a file declared 48 kHz, halving the duration. Earlier "verified 1.00x"
checks measured frames against the device's own rate, so they could not catch
a rate mismatch. Now every mic buffer passes through AVAudioConverter to the
file's 48 kHz mono, keeping only channel 0 (the echo-cancelled voice). The mic
also starts before the system tap, so both tracks begin together.
Lesson: normalise to the file format at capture time, and measure duration
against the wall clock, not against the device's own frame count.

## 2026-09-30 — System audio was static: the aggregate device was not the tap

**What happened.** A 59 s recording (19:30:04 to 19:31:03 by file times)
produced a 350 s them.caf of static. The samples' autocorrelation peaked at a
6-frame lag, i.e. 12 floats per real frame: the IO block was delivering far
more channels than the tap's 2, and `handleSystemAudio` flattened every buffer
into a file declared 48 kHz stereo. A probe of the real aggregate showed why:
it included the default output device as main subdevice, so its rate and
stream layout followed that device. With AirPods in their headset profile
(mic active) the block received **two stereo buffers at 24 kHz**. The
Sep 11 check that saw "1 buffer, 2 ch, 48 kHz" was done on the built-in
speakers and generalised from one device.

Fix: the aggregate contains only the tap (probe: 1 buffer, 2 ch, 48 kHz, 1.0000x
real time, with the AirPods mic active); every callback is validated against
the tap's current format (`kAudioTapPropertyFormat`, with a change listener)
and dropped and counted if it does not match; `SystemAudioConverter` resamples
and interleaves to 48 kHz stereo. The SCK fallback had the same class of bug:
it copied non-interleaved bytes as interleaved.

**How to apply.** Never write a buffer list into a file whose format you
assumed; read the source format, check the buffer layout against it, and
convert. And an RMS check cannot detect static: the self-test now plays a
1 kHz tone and requires it back at 1 kHz with SNR above 20 dB, and checks each
track's duration against the wall clock.
