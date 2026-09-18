# Atrium 0.3.5 verification

## Incident evidence

On the maintainer Mac, 10 session directories existed on 2026-09-18. Nine had
raw CAF tracks but no `session.m4a`; only one had a transcript. This matches the
reported recording, playback, and transcript failures. The old writer cancelled
its polling task without awaiting its final drain, closed the files, and then
mixed them. It also suppressed write/finalization errors. The capture fallback
started asynchronously after the app reported recording, and the detail view
loaded audio only on first appearance.

## Stack coverage

| Layer | Applies | Proof or change | Status |
| --- | --- | --- | --- |
| Product workflow | Yes | Record, stop, save, transcribe, select, play, and retry states reviewed | Code complete; real call pending |
| Architecture | Yes | Existing local capture → CAF → M4A → WhisperKit → SwiftData flow retained | Code reviewed |
| Interface | Yes | New recording selected; audio and transcript reload when processing ends; missing audio surfaced | Code reviewed; visual check pending |
| Backend logic | Local only | Capture startup awaited; writer drains before file close; errors propagate | Hosted build and export test passed on commit `9b43fba` |
| Data and storage | Yes | No schema change; raw CAF tracks can rebuild a missing or invalid mix on retry | Recovery path coded; user data not mutated by this release process |
| Identity and permissions | Yes | Existing microphone and Screen Recording gates retained; no silent system tap attempted without consent | Hardware check pending |
| Hosting | No server | GitHub Actions distributes an ad-hoc signed DMG | Release pending |
| CI and delivery | Yes | Xcodegen project, hosted macOS build/test, versioned tag and release | Pending |
| Security and privacy | Yes | Audio stays local; no new network path or secrets | Code reviewed |
| Reliability | Yes | Stop awaits final drain; write/export errors visible; fallback starts deterministically | Hosted export test passed |
| Observability | Yes | Existing OSLog plus visible save/playback errors | Code reviewed |
| Testing | Yes | Swift parse, capture/writer typecheck, diff check, writer export and missing-word tests | Hosted CI passed on `9b43fba`; final commit and real hardware pending |
| Scale and economics | Limited | No new services or recurring cost; ring buffer unchanged | No load claim |
| Lifecycle | Yes | Existing failed sessions can retry mix/transcription; normal update route retained | Recovery verification pending |

The [hosted Xcode build and tests](https://github.com/madeinphantom/granola-dubbed/actions/runs/35359573208)
passed on `9b43fba`, including a generated-audio export test. The hosted tests
prove the file finalization/export path without hardware.
They cannot prove CoreAudio, microphone, permissions, or a live meeting on the
maintainer Mac. Do not call 0.3.5 end-to-end hardware verified until a real
recording confirms both tracks, the mix, transcript, and playback.
