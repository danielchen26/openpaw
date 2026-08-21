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

Expected on a healthy machine: **268 Rust tests, 375 Swift tests, 140 non-blank snapshots, 39 smoke checks, all
steps passed.**

## What has never been verified anywhere, and how to close it

Everything below needs a working Xcode and a simulator or device. It is the entire outstanding verification debt.

1. **A real `xcodebuild` build.**

   ```sh
   cd apps/ios
   xcodebuild -project OpenPaw.xcodeproj -scheme OpenPaw \
     -destination 'generic/platform=iOS Simulator' \
     -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
   ```

   This writes `OpenPaw.xcodeproj/project.xcworkspace/xcshareddata/Package.resolved`, which pins SwiftTerm to a
   commit rather than to `.upToNextMinor(from: "1.20.0")`. **Commit that file** — it is the last unpinned
   dependency in the repo.

2. **The app actually running.** Boot a simulator, install, and walk the five destinations. The parts that were
   only type-checked and unit-tested, never executed:
   - the SwiftTerm surface: bytes flowing from the transport, `resize` on rotation, hardware-keyboard chords,
     bracketed paste, OSC 8 link taps, pinch zoom;
   - CJK input: the marked-text rule has a unit-tested state machine, but a real Pinyin IME committing multi-stage
     candidates is the only way to confirm nothing reaches the PTY before composition commits;
   - dictation: `SFSpeechRecognizer` permission prompts, on-device recognition, and switching between `zh-CN` and
     `en-US` mid-session;
   - the image path end to end: paste, annotate, blur, compress, upload, and the remote path handed to the agent.

3. **Dynamic Type.** This cannot be verified on macOS at all — AppKit has no content size category, so a macOS
   snapshot renders identically whether the type scale is anchored or frozen. The theme's twelve tokens are
   anchored to `Font.TextStyle`, which is correct by construction and unconfirmed in fact. The real check:

   ```sh
   xcrun simctl launch booted dev.openpaw.app \
     -UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL
   ```

   Diff against a default-size run. Rows must grow, nothing may clip, no text may truncate.

4. **On a device, not a simulator.** Keychain items are `WhenUnlockedThisDeviceOnly` with biometric access control
   on export, so Face ID / Touch ID behaviour, the background re-gate, and the microphone all need real hardware.

5. **A real end-to-end session.** Point the app at a machine running `openpaw-host`, over a real SSH port forward:
   pair, attach a tmux session, let Claude Code request a destructive command, and approve it from the phone. The
   daemon side of that path is covered by `scripts/smoke.py`; the phone side is not.

## Where things are

| Path | Trust it because |
| --- | --- |
| `host/` | 268 tests, plus `scripts/smoke.py` driving the shipped binary through pairing, signing, replay, the approval gate, git, preview and uploads |
| `packages/swift-agent-protocol` | 108 tests; decodes the same golden files the Rust side generates, so protocol drift is a test failure |
| `packages/swift-terminal-core` | 91 tests over real `tmux`/`zellij`/`screen` output samples, keymaps, OSC 52/8, scrollback |
| `packages/swift-ssh-transport` | 57 tests against an in-process NIOSSH server: auth, PTY, resize, host-key verdicts, port forwarding |
| `packages/swift-openpaw-ui` | 119 tests, and every screen rendered headlessly by `tools/openpaw-snapshot` |
| `apps/ios/` | type-checked for `arm64-apple-ios17.0-simulator` under Swift 6, 32 unit tests on the pure logic, pbxproj validated structurally |

## A warning worth keeping

Four defects in this repo were invisible to both the type-checker and the test suites, and were found only by
rendering screens and looking at the pixels: `ImageRenderer` silently dropping every `ScrollView` child, a
platform-branched size class making every "iPhone" render actually the iPad layout, a two-axis `ScrollView`
centring and squeezing its content, and a frozen type scale. See the note at the top of
`tools/openpaw-snapshot/Sources/openpaw-snapshot/SnapshotRenderer.swift`.

Run the snapshot tool and open the images. A green test suite is not evidence that a screen is right.
