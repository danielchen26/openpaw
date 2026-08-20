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

export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-/tmp/opaw-check}

step "host · fmt"            in_dir host cargo fmt --all --check
step "host · clippy"         in_dir host cargo clippy --workspace --all-targets -- -D warnings
step "host · test"           in_dir host cargo test --workspace
step "protocol · goldens"    git diff --exit-code -- protocol/fixtures/normalized

for pkg in swift-agent-protocol swift-terminal-core swift-ssh-transport swift-openpaw-ui; do
  step "packages/$pkg · test" in_dir "packages/$pkg" swift test
done

step "app · build" in_dir apps/ios xcodebuild \
  -project OpenPaw.xcodeproj -scheme OpenPaw \
  -destination 'generic/platform=iOS Simulator' \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
  -quiet build

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
