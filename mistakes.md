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
