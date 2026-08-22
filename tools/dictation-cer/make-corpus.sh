#!/usr/bin/env bash
# Regenerates the benchmark clips from `phrases.tsv`.
#
# The audio is synthesised rather than committed because a repository is not the place for a WAV corpus, and
# because `say` is deterministic enough that two machines produce the same numbers. The voices are chosen per
# language: a Chinese sentence read by an English voice measures the voice, not the recogniser.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

command -v ffmpeg >/dev/null || {
  echo "error: ffmpeg is required to make 16 kHz mono clips (brew install ffmpeg)" >&2
  exit 1
}

while IFS=$'\t' read -r id text; do
  [ -n "${id:-}" ] || continue
  case "$id" in
    zh*) voice=Tingting ;;
    *) voice=Samantha ;;
  esac
  say -v "$voice" -o "$id.aiff" "$text"
  ffmpeg -loglevel error -y -i "$id.aiff" -ar 16000 -ac 1 "$id.wav"
  rm -f "$id.aiff"
  echo "wrote $id.wav  [$voice]  $text"
done < phrases.tsv
