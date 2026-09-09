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
