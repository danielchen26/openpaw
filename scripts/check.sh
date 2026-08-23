#!/usr/bin/env bash
# Everything CI runs, in the order that fails fastest. Run from anywhere.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
FAILED=()

step() {
  local name=$1
  shift
  printf '\n\033[1m── %s\033[0m\n' "$name"
  if "$@"; then
    printf '\033[32m   ok\033[0m %s\n' "$name"
  else
    printf '\033[31m FAIL\033[0m %s\n' "$name"
    FAILED+=("$name")
  fi
}

in_dir() {
  local dir=$1
  shift
  (cd "$ROOT/$dir" && "$@")
}

latest_ios_simulator() {
  xcrun simctl list devices available -j | python3 -c '
import json
import re
import sys

candidates = []
for runtime, devices in json.load(sys.stdin)["devices"].items():
    match = re.search(r"\.iOS-(\d+)-(\d+)(?:-(\d+))?$", runtime)
    if match is None:
        continue
    version = tuple(int(part or 0) for part in match.groups())
    for device in devices:
        if not device.get("isAvailable"):
            continue
        candidates.append((
            version,
            device.get("state") == "Booted",
            "iPhone" in device.get("name", ""),
            device["udid"],
        ))

print(max(candidates)[-1] if candidates else "")
'
}

export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-/tmp/opaw-check}

step "host · fmt"            in_dir host cargo fmt --all --check
step "host · clippy"         in_dir host cargo clippy --workspace --all-targets -- -D warnings
step "host · test"           in_dir host cargo test --workspace
step "protocol · goldens"    git diff --exit-code -- protocol/fixtures/normalized

for pkg in swift-agent-protocol swift-terminal-core swift-ssh-transport swift-openpaw-ui; do
  step "packages/$pkg · test" in_dir "packages/$pkg" swift test
done

# `xcodebuild` is the real gate, but it refuses to load its IDE plug-ins on a machine whose Xcode first-launch
# content is older than Xcode itself (`sudo xcodebuild -runFirstLaunch` fixes that, and needs a password). When it
# cannot run at all, fall back to type-checking the app sources against the iOS simulator SDK with swiftc, which
# needs no IDE plug-ins and still catches every compile error in the app target.
app_step() {
  if xcodebuild -project apps/ios/OpenPaw.xcodeproj -list >/dev/null 2>&1; then
    in_dir apps/ios xcodebuild \
      -project OpenPaw.xcodeproj -scheme OpenPaw \
      -destination 'generic/platform=iOS Simulator' \
      -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
      -quiet build
  else
    printf '   xcodebuild cannot load its plug-ins here; run `sudo xcodebuild -runFirstLaunch`.\n'
    printf '   Falling back to the swiftc type-check.\n'
    in_dir apps/ios bash scripts/typecheck-ios.sh
  fi
}

step "app · build" app_step

# The app target's tests are hosted *in the app* and need a booted simulator, so they cannot run under the swiftc
# fallback above. Skipping them silently would be worse than not having them: these are the only tests that cover
# the terminal backends against a live transport.
app_test_step() {
  if ! xcodebuild -project apps/ios/OpenPaw.xcodeproj -list >/dev/null 2>&1; then
    printf '   xcodebuild cannot load its plug-ins here; skipping the app-hosted tests.\n'
    return 0
  fi
  local destination
  destination=$(latest_ios_simulator)
  if [ -z "$destination" ]; then
    printf '   no available iOS Simulator; skipping the app-hosted tests.\n'
    return 0
  fi
  in_dir apps/ios xcodebuild \
    -project OpenPaw.xcodeproj -scheme OpenPawAppTests \
    -destination "platform=iOS Simulator,id=$destination" \
    -skipPackagePluginValidation -skipMacroValidation \
    -quiet test
}

# One UI class, named explicitly rather than by running the whole suite.
#
# Most of OpenPawUITests needs a live host and a seeded key, so running all of it here would spend ten minutes
# mostly waiting for connections that cannot happen on a clean machine. This class needs neither, and it is the
# only automated check that the local recognisers are refused rather than fatal: without it, selecting Qwen on a
# simulator terminates the app the moment anyone holds the dictation button, and every other test in this
# repository still passes.
ui_test_step() {
  if ! xcodebuild -project apps/ios/OpenPaw.xcodeproj -list >/dev/null 2>&1; then
    printf '   xcodebuild cannot load its plug-ins here; skipping the dictation UI test.\n'
    return 0
  fi
  local destination
  destination=$(latest_ios_simulator)
  if [ -z "$destination" ]; then
    printf '   no available iOS Simulator; skipping the dictation UI test.\n'
    return 0
  fi
  in_dir apps/ios xcodebuild \
    -project OpenPaw.xcodeproj -scheme OpenPaw \
    -destination "platform=iOS Simulator,id=$destination" \
    -skipPackagePluginValidation -skipMacroValidation \
    -only-testing:OpenPawUITests/DictationEngineSettingsUITests \
    -quiet test
}

step "app · test" app_test_step

step "app · dictation ui" ui_test_step

step "ui · snapshots" in_dir tools/openpaw-snapshot \
  swift run openpaw-snapshot --output "${TMPDIR:-/tmp}/openpaw-snapshots"

step "host · end to end" python3 scripts/smoke.py

printf '\n'
if ((${#FAILED[@]})); then
  printf '\033[31m%d step(s) failed:\033[0m\n' "${#FAILED[@]}"
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
printf '\033[32mall steps passed\033[0m\n'
