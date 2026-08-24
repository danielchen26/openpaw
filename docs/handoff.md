# Taking over on another machine

Nothing about this repository is tied to the machine it was written on. There are no secrets in version control,
and no local state is required: `~/.openpaw/` — the device tokens, HMAC keys and hook token — is generated per
machine and is gitignored. Clone and go.

## What the new machine needs

| Tool | Why | Check |
| --- | --- | --- |
| Xcode, with first launch completed | building the iOS app, the iOS SDK | `xcodebuild -project apps/ios/OpenPaw.xcodeproj -list` must print schemes |
| An iOS simulator runtime | running the app at all | `xcrun simctl list runtimes` must list an iOS runtime |
| Rust stable | the host daemon | `cargo --version` |
| `git` | the git routes shell out to the real binary | `git --version` |
| Python 3 | `scripts/smoke.py`, standard library only | `python3 --version` |

If `xcodebuild` fails to load its plug-ins, the machine's Xcode first-launch content is older than Xcode itself:

```sh
sudo xcodebuild -runFirstLaunch      # needs an administrator password
```

That is exactly what blocked the iOS build on the machine this repo was written on, which is why
`scripts/check.sh` falls back to `apps/ios/scripts/typecheck-ios.sh` — a swiftc type-check against the iOS
simulator SDK that needs no IDE plug-ins.

## One command

```sh
git clone https://github.com/danielchen26/openpaw && cd openpaw
bash scripts/check.sh
```

It runs, failing fastest first: `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test --workspace`, a
check that the protocol goldens are unchanged, `swift test` in all four packages, the iOS app build, the headless
UI snapshot render, and `scripts/smoke.py` end to end against the freshly built daemon.

Latest verified on 2026-08-22: **all canonical steps passed** in 245s, including **276 non-blank snapshots** and
**39 host end-to-end checks**. The script prints the current test counts; do not freeze them here as the suites
are growing.

## Real local Quick Connect acceptance

Run the opt-in acceptance harness on a Mac with Xcode first launch completed, an installed iOS simulator, `sshd`,
Rust, and Python 3:

```sh
JCODE_SCRATCH_DIR="$HOME/.cache/jcode" python3 scripts/quick-pairing-live.py
```

The command selects the newest installed phone simulator unless `--simulator UDID` is supplied. It creates every
mutable artifact beneath `JCODE_SCRATCH_DIR`, including generated SSH keys, a user-level high-port SSH daemon,
`openpaw-host` state, a fixture Git repository, a scratch copy of the iOS project, DerivedData, and captured logs.
The per-run directory and child processes are removed on success, failure, SIGINT, and SIGTERM. The live run is not
part of `scripts/check.sh`; only `scripts/tests/test_quick_pairing_live.py`'s hermetic contracts run there.

Acceptance is local and real: after XCUITest signals `/ready`, `openpaw-host pair --qr` issues the exact five-minute
envelope and `simctl openurl` is invoked immediately. The localhost `/ready` response also lets XCTest perform its
automation-safe `app.open` without putting the secret URL in arguments, environment variables, or logs. XCUITest
confirms the preselected credential and unknown host key, the app establishes real SSH and redeems real `/v1/pair`
exactly once, a relaunch proves the signer is available for the selected host, Terminal is selected, and a direct
replay receives a rejection. No camera injection or cloud service is used.

Credential boundary: the generated private key remains outside the repository and is supplied only to the existing
DEBUG+simulator `-openpaw-debug-seed-key` launch hook. The hook imports it through OpenPaw's own
`KeychainStore`/credential path. The Python harness never edits the simulator Keychain. The private key, hook token,
pairing code, returned bearer token, HMAC key, and secret-bearing `openpaw://` URL must not appear in console output.
Xcode diagnostics are captured and redacted before any failure is printed; long-lived `sshd` and host daemon output is
sent to `/dev/null` so an undrained pipe cannot block the real service under test.

Completed on 2026-08-24. After building the current host binary, two consecutive runs of:

```sh
python3 scripts/quick-pairing-live.py --binary host/target/debug/openpaw-host
```

exited zero and printed all five required evidence lines: real SSH connected, real pairing redeemed once, signer
persisted for the selected host, Terminal selected, and pairing-code replay rejected. Both runs also verified child
process and scratch-directory cleanup.

The intermittent server-committed/client-timed-out failure was caused by the harness, not pairing persistence or the
SSH forwarder. It launched the long-lived host and `sshd` with `stdout=PIPE` but never drained either pipe. With the
fixture home, the host emitted 17,224 bytes in 45 seconds, enough to fill the macOS pipe. `/v1/pair` durably inserts the
device, syncs the audit, and publishes recovery before its final `tracing::info!`; a full pipe therefore blocked after
commit but before HTTP response while retaining the recovery lock, so both 15-second client attempts timed out. The
harness now sends daemon output to `/dev/null`, with a contract test preventing undrained pipes.

A separate relaunch race was also fixed. Automatic reconnect could reach Terminal after the test checked the pager but
before the Resume button appeared. The generated XCUITest now waits for either Terminal or a visible Resume action,
then proves the terminal surface and authenticated Home workspace before reporting signer persistence. Secret-safe
phase diagnostics are restricted to fixed DEBUG+simulator categories and confirmed successful phases in the passing
runs. The unrelated `apps/ios/OpenPaw.xcodeproj/project.pbxproj` modification remained unstaged and uncommitted.

## Simulator acceptance completed on 2026-08-21

The Milestone 1 app was built, installed and launched on an **iPhone 16 Pro simulator running iOS 18.2**.

- A clean defaults domain opens the biometric lock screen. Clearing the lock preference for the simulator opens the
  local first-run Home without contacting a host or presenting an error.
- The first-run Home renders its signal hero, local-control explanation and visible **Add a Tailscale or SSH device**
  action. The populated Home is covered with real presentation models in the snapshot catalogue.
- The first simulator pass exposed a real defect the test suite had missed: a flexible spacer let the custom tab bar
  consume the lower half of the phone. The bar is now bounded to 64pt, or 72pt and icon-only at accessibility text
  sizes. Focused root navigation tests and the full 157-test UI suite pass after the fix.
- Standard text and `accessibility-extra-extra-extra-large` were both launched in the simulator. At the largest size
  content reflows vertically and the six navigation targets remain visible without truncated visual labels; their
  full spoken accessibility labels remain attached to the buttons. The scroll gesture itself remains part of the
  interactive automation debt below.
- Reduce Motion was enabled in the simulator preferences and the app relaunched successfully with its static motion
  policy.
- The snapshot executable builds in release configuration and produced 188 written, 22 intentionally skipped,
  0 failed and 0 blank renders.
- A structured visual comparison against the Moshi Home reference scored the populated OpenPaw Home 92/100 and
  passed category and usability review. This is design evidence, not transport or device evidence.

## Remaining acceptance debt

1. **Interactive simulator walk.** macOS Accessibility permission was not granted to the automation process, so the
   live Add Device sheet and tab-by-tab touch walk could not be driven programmatically. The same states are covered
   by model tests and snapshots, but a real touch path still needs one run after granting that local permission.
2. **A credentialed Tailscale/SSH session.** A running local Tailscale environment and SSH port were observed, but no
   private key was copied and no `authorized_keys` entry was changed. The phone-side tunnel therefore remains blocked
   until a test credential is deliberately imported.
3. **On-device security and audio.** Face ID / Touch ID, Keychain access control, background re-gating, microphone
   permission and Apple Speech recognition require physical hardware.
   The local dictation engines are the sharpest edge here. `tools/dictation-cer` proves the *models* are right —
   Apple 21.6% mean CER against Qwen3-ASR 0.6B's 2.3% on the same clips — and the settings screen is verified
   through the snapshot catalogue in all five of its states. What has never run is the path between them: a real
   finger held on a real phone, `AVAudioEngine` capturing at 16 kHz, weights loading over a real network, and the
   transcript landing in the composer. Every piece has been exercised in isolation and none of them together.
   **A simulator cannot close this gap, and that is now settled rather than suspected.** MLX fails there twice
   over: `MTLSimDevice` returns a null `architecture()->name()` which MLX copies into a `std::string` and aborts
   on, and past that (`MLX_METAL_GPU_ARCH` sets the name by hand) Metal asserts `MTLStorageModePrivate is required
   for heaps`, because MLX allocates shared-storage heaps on the premise of unified memory. Both are aborts inside
   C++, not Swift errors, so nothing can catch them. The app therefore reports the local engines as
   `.unsupported` on a simulator and refuses to build, download or load one, and that refusal is driven through
   the real screen by `DictationEngineSettingsUITests` — which was confirmed to catch the crash by deleting the
   guards and watching `XCUIApplicationState` drop to `notRunning`. `LocalDictationAccuracyTests` is written and
   registered against the app target and skips there with that reason, so a cable is the only thing between this
   repository and a measured on-device answer.
   Two things worth knowing before trusting the guard. The sentence the settings row shows lives in
   `LocalASRModelStore.simulatorReason`, and `DictationEngineSettingsUITests` finds that row by searching the
   screen for "real device" — nothing but a unit test connects those, so reword the reason and read
   `testTheUnsupportedReasonStaysTheSentenceTheUITestSearchesFor` before blaming the picker. And
   `DictationEngineChoiceState.isActionable` is not what draws the button: the row switches over the state
   exhaustively so that a new case cannot be silently absorbed by a boolean. Both are exhaustive, and a test
   asserts they agree.
   When a phone does arrive, two of the three things that test needs are already known to work. The audio
   harness (`synthesise`/`readSamples`) and the scorer (`characterErrorRate`) both run and are asserted on this
   machine, so a failure on hardware points at the model or the wrapper rather than at the test. Note that the
   0.15 threshold does not catch a leaked `<|zh|>` on a sentence of ordinary length — that costs 0.146 — which is
   why `testTranscriptsArriveWithoutModelTags` is a separate test and must not be folded into the accuracy one.
   One honest gap in the UI coverage. `testHoldingDictationAfterChoosingALocalModelDoesNotKillTheApp` currently
   **skips**, and that is not a bug to be silenced. The microphone lives in `ComposerView`, reachable only through
   `ChatView` -> `transcript(sessionID)`, so it needs a real agent session and therefore a live daemon; with no
   host, both Chat and Terminal render empty states. An earlier version of that test pressed a coordinate on the
   terminal text view and passed while touching nothing, which is worse than the skip. Guard removal is still
   caught, by `testChoosingALocalModelOnASimulatorExplainsItselfAndOffersNoDownload` on the settings screen,
   because selecting the engine is already enough to reach MLX. Point that test at a running daemon and it becomes
   the genuine end-to-end crash check.
   Being stuck there is worth something anyway: reading the wrapper instead of running it turned up a defect the
   models could never have exposed. The transcript cleaner stripped everything between angle brackets, so a
   dictated `cat < in.txt > out.txt` reached the draft as `cat  out.txt` — a different command, still valid,
   waiting on Execute. Fixed, covered by a test that needs no GPU, and the benchmark's duplicate copy of that
   function is now checked for drift rather than asked politely to stay in step.
4. **Terminal input and media.** Real PTY bytes, rotation resize, hardware keyboard chords, bracketed paste, OSC 8,
   OSC 52 pasteboard handoff, pinch zoom, Pinyin composition and image upload still need a credentialed live session.
5. **Resilient transport and ecosystem claims.** Production terminal transport is SSH. Native Mosh is not implemented
   and still has licensing and iOS feasibility gates. The Eternal Terminal foundation is isolated, disabled by
   default, excluded from default `TransportSelector` planning through `ExperimentalTransportFeatures.disabled`, and
   not app-integrated or validated against real `etserver` or physical devices. Push, Live Activities, Dynamic Island
   and Watch approvals remain future work.

## Where things are

| Path | Trust it because |
| --- | --- |
| `host/` | 268 tests, plus `scripts/smoke.py` driving the shipped binary through pairing, signing, replay, the approval gate, git, preview and uploads |
| `packages/swift-agent-protocol` | 108 tests; decodes the same golden files the Rust side generates, so protocol drift is a test failure |
| `packages/swift-terminal-core` | 91 tests over real `tmux`/`zellij`/`screen` output samples, keymaps, OSC 52/8, scrollback |
| `packages/swift-ssh-transport` | 57 tests against an in-process NIOSSH server: auth, PTY, resize, host-key verdicts, port forwarding |
| `packages/swift-openpaw-ui` | 157 tests in the latest full run, plus 188 non-blank renders across the snapshot catalogue |
| `apps/ios/` | real `xcodebuild`, install and launch verified on iPhone 16 Pro / iOS 18.2, plus the package and structural checks |

## A warning worth keeping

Five defects in this repo were invisible to both the type-checker and the test suites, and were found only by
rendering screens and looking at the pixels: `ImageRenderer` silently dropping every `ScrollView` child, a
platform-branched size class making every "iPhone" render actually the iPad layout, a two-axis `ScrollView`
centring and squeezing its content, a frozen type scale, and an unbounded custom tab bar consuming half a phone.
See the note at the top of
`tools/openpaw-snapshot/Sources/openpaw-snapshot/SnapshotRenderer.swift`.

Run the snapshot tool and open the images. A green test suite is not evidence that a screen is right.
