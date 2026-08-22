# Dictation accuracy benchmark

Measures how badly each dictation engine mishears the sentence OpenPaw exists to carry: Chinese with an English
command name in the middle of it.

This is the evidence behind the recogniser picker in Settings. Offering a 450 MB download as an alternative to a
recogniser built into the OS is only defensible if the built-in one really is unusable for this, and "really is"
has to be a number somebody else can reproduce.

## Running it

```bash
brew install ffmpeg          # once
./make-corpus.sh             # synthesises the clips from phrases.tsv
swift build -c release
BUILD_DIR="$PWD/.build" ./.build/checkouts/speech-swift/scripts/build_mlx_metallib.sh release
./.build/release/dictation-cer . apple qwen3-0.6b
```

The metallib step is only needed for the MLX engines from a command line tool. Xcode builds MLX's Metal shader
library into the app bundle automatically, so the phone does not need it; a SwiftPM executable does, and without
it the first `transcribe` call dies with "Failed to load the default metallib". `BUILD_DIR` has to be set because
the script otherwise looks for a `.build` beside its own checkout, which does not exist when SwiftPM has vendored
it as a dependency. It takes about two minutes and only has to be done once per checkout.

Engines: `apple`, `qwen3-0.6b`, `qwen3-1.7b`, `parakeet`. Each is given byte-identical audio, the same 16 kHz mono
float the microphone path produces, and the same language hint the user's setting would supply.

## What it measured

On an M-series Mac, macOS 15, 8 clips (6 mixed Chinese/English, 2 English):

| engine | mean CER | per clip |
|---|---|---|
| Apple `SFSpeechRecognizer`, on-device | 21.6% | 0.1–0.5 s |
| Qwen3-ASR 0.6B, 4-bit MLX | 2.3% | 0.03–0.08 s |

The mean understates the problem, because Apple's errors are not spread evenly. It transcribes pure-Chinese and
pure-English spans fine and then destroys the command name in the middle, which is the only part of the sentence
that has to be exact:

| said | Apple heard |
|---|---|
| 运行 **npm install** 安装依赖 | 运行**BPM in so**安装 |
| 用 **git commit** 提交这个改动 | 用**jacket**提交这个改动 |
| 帮我看一下 **docker ps** 的输出 | 帮我看一下**周可PS**的输出 |
| 这个 **pull request** 需要 **review** 一下 | 这个**poo request**需要**rave**一下 |

A word that is 40% wrong in a chat message is a typo. A word that is 40% wrong in a terminal is a command that
does not exist, or worse, a different one that does. Qwen3 got every one of those four exactly right.

Apple also mangles English command names in English sentences — `npm install` came back as "and p.m. installed" —
so this is not only a Chinese problem. It is a vocabulary problem, and a general-purpose dictation model that has
never been told it is talking to a shell has no reason to solve it.

## Caveats worth stating

The clips are synthesised with `say`, not recorded from a human in a room. Synthetic speech is cleaner than
reality, so these numbers are the best case for both engines; a real microphone in a café would move both of them
up. What it does establish is the *gap*, measured on identical input, which is the only thing the picker needs to
justify itself.

This tool runs on a Mac, and that is not a stylistic choice. The MLX engines cannot run on an iOS simulator at
all: `MTLSimDevice` hands MLX a null `architecture()->name()` which it copies straight into a `std::string` and
aborts on, and setting `MLX_METAL_GPU_ARCH` past that only reaches the real obstacle, Metal asserting
`MTLStorageModePrivate is required for heaps` because MLX allocates shared-storage heaps. Both are C++ aborts, so
no Swift `catch` helps. Measuring on the Mac and running the same code on a phone are the only two options, which
is why `apps/ios/OpenPawAppTests/LocalDictationAccuracyTests.swift` exists as the on-device half and skips
anywhere else.
