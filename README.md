# Muse Glimmer 30B on llama.cpp (macOS)

Convenience `Makefile` for downloading and serving **Meta Muse Glimmer 30B** with
[llama.cpp](https://github.com/ggml-org/llama.cpp) on Apple Silicon.

Setup follows
[Run Muse Glimmer-30B Locally with llama.cpp on macOS](https://scriptable.com/posts/llama-cpp/run-muse-glimmer-llama-cpp-macos/),
which is the reference for the build flags, the three GGUFs, and the server
invocation wrapped up here. Read it first if you want the reasoning behind any
of the settings; this repo just automates them.

## llama.cpp lives in a separate folder

This repo contains **no llama.cpp source and no build tree** — only the
`Makefile`. The upstream clone is a sibling directory, which keeps these local
targets out of a tree you'll be pulling and rebuilding:

```
~/projects/llama-cpp/
├── llama.cpp/                  <- upstream clone (source + build/)
└── llama-cpp-muse-glimmer/     <- this repo (Makefile only)
```

The clone's location is the `LLAMA_CPP` variable at the top of the `Makefile`,
and everything else derives from it:

```make
LLAMA_CPP ?= $(HOME)/projects/llama-cpp/llama.cpp
BUILD_DIR ?= $(LLAMA_CPP)/build

SERVER ?= $(BUILD_DIR)/bin/llama-server
CLI    ?= $(BUILD_DIR)/bin/llama-cli
LLAMA  ?= $(BUILD_DIR)/bin/llama
```

**Point `LLAMA_CPP` at your own clone** — edit that line, or override it per
invocation:

```sh
make build LLAMA_CPP=~/src/llama.cpp
```

`make build` passes the source directory explicitly (`cmake -S $(LLAMA_CPP) -B
$(BUILD_DIR)`), so nothing is built relative to the current directory.

## You need a recent llama.cpp build

Muse Glimmer is a new architecture, so an older llama.cpp **cannot load the
model at all** — it fails on the unknown arch rather than doing anything
graceful.

- **Build `b10353` or newer** is required. The article notes Homebrew's formula
  was still on `b10330`, so `brew install llama.cpp` is not sufficient — build
  from source.
- **An existing clone needs updating.** If you cloned llama.cpp before Muse
  Glimmer landed, `make build` compiles a tree that can't load the model. Pull
  first:

  ```sh
  git -C ~/projects/llama-cpp/llama.cpp pull
  ```

- **`make build` verifies this for you.** It depends on `check-arch`, which
  greps `$(LLAMA_CPP)/src/llama-arch.cpp` for `LLM_ARCH_MUSE_GLIMMER` and stops
  before CMake runs if the symbol isn't there, so a stale checkout fails in a
  second instead of after a full build:

  ```sh
  $ make check-arch
  check-arch: LLM_ARCH_MUSE_GLIMMER present in llama-arch.cpp (b10362)
  ```

  On a stale tree it names the fix (`git -C … pull`) and exits 1. Run it
  standalone any time; override the symbol or path with `ARCH_SYM` / `ARCH_SRC`.

- **Do not shallow-clone.** `--depth 1` breaks llama.cpp's build-number
  calculation, and the build number is exactly what you're checking here.

  ```sh
  git clone https://github.com/ggml-org/llama.cpp ~/projects/llama-cpp/llama.cpp
  ```

Confirm what you actually built at any time with `make version`. Known-good:

```
$ make version
version: 10362 (4801e3c56)
built with AppleClang 21.0.0.21000101 for Darwin arm64
```

## Quick start

```sh
git clone https://github.com/ggml-org/llama.cpp ~/projects/llama-cpp/llama.cpp   # full clone
git -C ~/projects/llama-cpp/llama.cpp pull   # or this, if you already had a clone
make build              # check-arch, then cmake configure + build (Release, CURL on)
make download-models    # ~18 GB of GGUFs into the HF cache
make server             # build, then serve on 127.0.0.1:8080
make status             # is it up?
make chat               # one-shot prompt through /v1/chat/completions
make opencode           # drive the model from the opencode TUI
make stop               # shut it down
```

## Targets

| Target | What it does |
| --- | --- |
| `build` | Configure + build `$(LLAMA_CPP)` with CMake (Release, `LLAMA_CURL=ON`) |
| `check-arch` | Fail unless the checkout knows `LLM_ARCH_MUSE_GLIMMER`; `build` runs it first |
| `version` | Print the built `llama-cli` version |
| `clean` | Remove `$(BUILD_DIR)` — **inside the llama.cpp clone**, not here |
| `download-models` | Fetch the GGUFs from Hugging Face into the HF cache |
| `list-models` | List the downloaded GGUFs |
| `run` | Start `llama-server` (logs to `server.log`) |
| `server` | `build`, then `run` |
| `status` | Report pid + `/health`; exits non-zero if not running |
| `stop` | Stop the server, verifying the port owner is really `llama-server` |
| `demo` | One-shot `llama-cli` prompt, no server needed |
| `chat` | One-shot `/v1/chat/completions` prompt against a running server |
| `opencode` | Open the [opencode](https://opencode.ai) TUI against the running server |
| `opencode-run` | One-shot headless opencode prompt |
| `opencode-config` | (Re)write `opencode.json` from the Makefile variables |
| `build-help` | Upstream build docs pointer |

`make help` lists these along with every overridable variable.

## Models

`download-models` pulls three files from `meta-models/Muse-Glimmer-30B-GGUF`:

| File | Size | Role |
| --- | --- | --- |
| `muse-glimmer-30B-kquant-17gb.gguf` | 16 GB | main weights |
| `mmproj-kquant.gguf` | 1.3 GB | perception encoder (multimodal) |
| `dflash-kquant.gguf` | 1.5 GB | speculative drafter (optional) |

They land in `~/.cache/huggingface/hub/...`, and `run` resolves the snapshot
directory itself. Note the drafter is downloaded but **not** currently passed to
`llama-server` — wire it up with `-md` if you want speculative decoding.

`run` serves 131072 context across 4 slots (32768 each) with `--jinja` and the
model's recommended sampling (`--temp 1.0 --top-p 0.95 --top-k 64`).

## Using it from opencode

[opencode](https://opencode.ai) talks to the same OpenAI-compatible endpoint
`make chat` uses, so the running server is a drop-in local model for it. Start
the server, then:

```sh
make run                         # in one shell
make opencode                    # in another — opens the TUI on this model
make opencode-run                # or headless, one prompt and out
make opencode-run OC_PROMPT="explain the run target"
```

Both targets fail with one clear message if the server isn't up (or is still
loading) and if `opencode` isn't installed (`brew install opencode`).

### The `opencode.json` in this repo

opencode merges a project-local `opencode.json` over your global
`~/.config/opencode/opencode.json`, so the provider defined here **only exists
while opencode runs from this directory** — nothing global is touched, and your
usual default model is untouched everywhere else. The checked-in file registers
llama-server as an openai-compatible provider:

```json
{
  "model": "llama-cpp/muse-glimmer-30B",
  "provider": {
    "llama-cpp": {
      "npm": "@ai-sdk/openai-compatible",
      "options": { "baseURL": "http://127.0.0.1:8080/v1" },
      "models": { "muse-glimmer-30B": { "limit": { "context": 32768, "output": 8192 } } }
    }
  }
}
```

No API key is involved — llama-server doesn't ask for one unless you start it
with `--api-key`.

It holds the *defaults*. If you serve on another port, rename the alias, or
change the context split, regenerate it so opencode agrees with the server:

```sh
make opencode-config PORT=8081        # rewrites opencode.json from the Makefile vars
```

Verify what opencode resolved with `opencode models llama-cpp`.

### Give it the whole context window

`run` splits `CTX` across `NP` slots, so with the defaults (131072 / 4) a single
session only gets **32768 tokens** — which an agent chews through fast. That
per-slot number, not `CTX`, is what `opencode-config` writes as the context
limit (`OC_CTX`), because advertising more would let opencode pack a prompt the
slot can't hold.

For agent work, serve one slot and take the full window:

```sh
make run NP=1
make opencode-config NP=1    # context limit becomes 131072
make opencode
```

## Notes

**Use `/v1/chat/completions`, not `/completion`.** Raw completion skips the chat
template and the model emits its harmony control tokens as literal text
(`<|start|>assistant to=self<|message|>…`) instead of answering. The `chat`
target uses the right endpoint; `demo` passes `--jinja` to `llama-cli`.

**It reasons before answering.** Responses fill `reasoning_content` first and
only then `content`, so too small a token budget truncates mid-reasoning and
returns *empty* content with `finish_reason: length`. `make chat` treats that as
an error and exits 1 rather than printing nothing:

```sh
make chat                      # CHAT_TOKENS defaults to 512
make chat CHAT_REASONING=1     # show the reasoning trace on stderr
make chat TEMP=0               # deterministic; TEMP defaults to 1.0
make chat CHAT_PROMPT="..." CHAT_TOKENS=1024
```

The answer goes to stdout and diagnostics to stderr, so `make chat 2>/dev/null`
gives just the reply.

**Don't relocate a build tree.** CMake bakes absolute paths into
`CMakeCache.txt` and into each binary's `LC_RPATH`, so moving `build/` produces
`Library not loaded: @rpath/libllama-cli-impl.dylib` even though the dylibs sit
right beside the binary. CMake also refuses to reconfigure over a cache whose
`CMAKE_HOME_DIRECTORY` moved. Fix by rebuilding in place:

```sh
make clean && make build
```

**`/health` turns green in seconds** despite the 16 GB model, because llama.cpp
mmaps the GGUF and pages fault in lazily. That is not a partial load.
