SHELL := /bin/bash

# Local convenience targets for driving the llama.cpp checkout at $(LLAMA_CPP).
# This used to be a GNUmakefile so it would win over the upstream Makefile stub
# while living inside that tree; the two are separate directories now, so the
# name no longer has to dodge anything. Upstream's own stub is untouched over
# there and still just points at CMake -- see `make build-help`.

HF_CACHE   ?= $(HOME)/.cache/huggingface/hub
HF_REPO    ?= models--meta-models--Muse-Glimmer-30B-GGUF
SNAPSHOTS  := $(HF_CACHE)/$(HF_REPO)/snapshots

HF_MODEL    ?= meta-models/Muse-Glimmer-30B-GGUF
MODEL_FILE  ?= muse-glimmer-30B-kquant-17gb.gguf
MMPROJ_FILE ?= mmproj-kquant.gguf
DRAFT_FILE  ?= dflash-kquant.gguf

ALIAS ?= muse-glimmer-30B
CTX   ?= 131072
NP    ?= 4
HOST  ?= 127.0.0.1
PORT  ?= 8080

TEMP  ?= 1.0
TOP_P ?= 0.95
TOP_K ?= 64

LOG    ?= server.log

DEMO_CTX    ?= 32768
DEMO_PROMPT ?= What is 17 * 23? Reply with just the number.

# chat talks to an already-running server; /v1/chat/completions applies the chat
# template, unlike /completion, which echoes the raw control tokens back
CHAT_PROMPT  ?= $(DEMO_PROMPT)
CHAT_TOKENS  ?= 512
CHAT_TIMEOUT ?= 180

# this model reasons before answering: it fills reasoning_content first and only
# then content, so a small CHAT_TOKENS truncates mid-reasoning and content comes
# back empty -- chat treats that as an error and exits 1, so it can gate a build.
# CHAT_REASONING=1 prints the reasoning trace on stderr.
CHAT_REASONING ?= 0

# opencode drives the server over the same OpenAI-compatible endpoint chat uses.
# The context limit it advertises is per *slot*: run splits CTX across NP slots,
# so a session only ever gets CTX/NP -- that, not CTX, is what opencode must see.
OPENCODE      ?= opencode
OC_PROVIDER   ?= llama-cpp
OC_CONFIG     ?= opencode.json
OC_MODEL      ?= $(OC_PROVIDER)/$(ALIAS)
OC_CTX        ?= $(shell expr $(CTX) / $(NP))
OC_MAX_TOKENS ?= 8192
OC_PROMPT     ?= $(CHAT_PROMPT)

# opencode-sandbox runs opencode *from* OC_SANDBOX, so files it creates land
# there rather than in this repo, and loads OC_SANDBOX_CONFIG (which is this
# repo's config plus a deny rule for this repo) via OPENCODE_CONFIG. Generated
# per run because it hardcodes absolute paths -- gitignored, don't commit it.
OC_SANDBOX        ?= $(HOME)/tmp/muse-glimmer-sandbox
OC_SANDBOX_CONFIG ?= opencode.sandbox.json

# the llama.cpp checkout is a sibling clone, not this directory
LLAMA_CPP ?= $(HOME)/projects/llama-cpp/llama.cpp
BUILD_DIR ?= $(LLAMA_CPP)/build
JOBS      ?= $(shell sysctl -n hw.ncpu)

SERVER ?= $(BUILD_DIR)/bin/llama-server
CLI    ?= $(BUILD_DIR)/bin/llama-cli
LLAMA  ?= $(BUILD_DIR)/bin/llama

# Muse Glimmer is a new architecture, so a checkout that predates it can't load
# the model at all -- it fails on the unknown arch. Cheaper to catch that in the
# source than after a full build, so check-arch gates build.
ARCH_SYM ?= LLM_ARCH_MUSE_GLIMMER
ARCH_SRC ?= $(LLAMA_CPP)/src/llama-arch.cpp

.PHONY: run help build check-arch version clean server status stop demo chat check-server \
        opencode opencode-config opencode-check opencode-run opencode-sandbox \
        download-models list-models build-help

help:
	@echo "Targets:"
	@echo "  build            configure and build $(LLAMA_CPP) with CMake (Release, CURL on)"
	@echo "  check-arch       verify the checkout knows $(ARCH_SYM) (build runs this first)"
	@echo "  version          print the built llama-cli version"
	@echo "  clean            remove the $(BUILD_DIR) directory"
	@echo "  download-models  fetch the $(ALIAS) GGUFs from Hugging Face"
	@echo "  list-models      list the downloaded GGUFs in the HF cache"
	@echo "  run              start llama-server with $(ALIAS) (logs to $(LOG))"
	@echo "  server           build, then run"
	@echo "  status           report if llama-server is up on $(HOST):$(PORT)"
	@echo "  stop             stop the llama-server on $(HOST):$(PORT)"
	@echo "  demo             one-shot llama-cli prompt (no server)"
	@echo "  chat             one-shot /v1/chat/completions prompt (needs a running server)"
	@echo "  opencode         open the opencode TUI against $(OC_MODEL)"
	@echo "  opencode-run     one-shot headless opencode prompt"
	@echo "  opencode-sandbox opencode in $(OC_SANDBOX), read-only against this repo"
	@echo "  opencode-config  (re)write $(OC_CONFIG) from the vars above"
	@echo "  build-help       show the upstream build instructions"
	@echo
	@echo "Overridable: HF_REPO HF_MODEL MODEL_FILE MMPROJ_FILE DRAFT_FILE ALIAS CTX NP HOST PORT TEMP TOP_P TOP_K LLAMA_CPP SERVER CLI LLAMA LOG BUILD_DIR JOBS ARCH_SYM ARCH_SRC CHAT_PROMPT CHAT_TOKENS CHAT_TIMEOUT CHAT_REASONING OPENCODE OC_PROVIDER OC_CONFIG OC_MODEL OC_CTX OC_MAX_TOKENS OC_PROMPT OC_SANDBOX OC_SANDBOX_CONFIG OC_BASH"
	@echo "  e.g. make run PORT=8081 NP=2"
	@echo "  llama.cpp checkout: $(LLAMA_CPP)"

build: check-arch
	cmake -S $(LLAMA_CPP) -B $(BUILD_DIR) -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=ON
	cmake --build $(BUILD_DIR) --config Release -j $(JOBS)

check-arch:
	@if [ ! -f "$(ARCH_SRC)" ]; then \
	    echo "error: $(ARCH_SRC) not found" >&2; \
	    echo "  LLAMA_CPP=$(LLAMA_CPP) does not look like a llama.cpp clone." >&2; \
	    echo "  Clone it (no --depth 1, it breaks the build number):" >&2; \
	    echo "    git clone https://github.com/ggml-org/llama.cpp $(LLAMA_CPP)" >&2; \
	    exit 1; \
	fi; \
	if ! grep -q '$(ARCH_SYM)' "$(ARCH_SRC)"; then \
	    echo "error: $(ARCH_SYM) not found in $(ARCH_SRC)" >&2; \
	    echo "  This checkout predates $(ALIAS) support and cannot load the model." >&2; \
	    echo "  Update it, then rebuild:" >&2; \
	    echo "    git -C $(LLAMA_CPP) pull" >&2; \
	    exit 1; \
	fi; \
	REF=$$(git -C "$(LLAMA_CPP)" describe --tags 2>/dev/null); \
	echo "check-arch: $(ARCH_SYM) present in $(notdir $(ARCH_SRC))$${REF:+ ($$REF)}"

version:
	@if [ ! -x "$(CLI)" ]; then \
	    echo "error: $(CLI) not found -- run: make build" >&2; \
	    exit 1; \
	fi; \
	$(CLI) --version

clean:
	rm -rf $(BUILD_DIR)

server:
	$(MAKE) build
	$(MAKE) run

# /health answers 503 while the model still loads, so report the pid separately
status:
	@PID=$$(lsof -ti tcp:$(PORT) -sTCP:LISTEN 2>/dev/null | head -1); \
	if [ -z "$$PID" ]; then \
	    echo "llama-server: not running (nothing listening on $(HOST):$(PORT))"; \
	    exit 1; \
	fi; \
	echo "llama-server: pid $$PID listening on $(HOST):$(PORT)"; \
	CODE=$$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://$(HOST):$(PORT)/health); \
	case "$$CODE" in \
	    200) echo "health: ok" ;; \
	    503) echo "health: loading model" ;; \
	    000) echo "health: no response (port owned by another process?)"; exit 1 ;; \
	    *)   echo "health: http $$CODE" ;; \
	esac

# only kills the port owner if it really is llama-server
stop:
	@PID=$$(lsof -ti tcp:$(PORT) -sTCP:LISTEN 2>/dev/null | head -1); \
	if [ -z "$$PID" ]; then \
	    echo "llama-server: not running (nothing listening on $(HOST):$(PORT))"; \
	    exit 0; \
	fi; \
	NAME=$$(ps -p $$PID -o comm=); NAME=$${NAME##*/}; \
	if [ "$$NAME" != "$(notdir $(SERVER))" ]; then \
	    echo "error: pid $$PID on port $(PORT) is $$NAME, not $(notdir $(SERVER)) -- refusing to kill" >&2; \
	    exit 1; \
	fi; \
	kill $$PID; \
	for i in $$(seq 20); do \
	    kill -0 $$PID 2>/dev/null || break; \
	    sleep 0.5; \
	done; \
	if kill -0 $$PID 2>/dev/null; then \
	    echo "llama-server: pid $$PID ignored SIGTERM, sending SIGKILL"; \
	    kill -9 $$PID; \
	fi; \
	echo "llama-server: stopped (pid $$PID)"

demo:
	@set -o pipefail; \
	SNAP=$$(find "$(SNAPSHOTS)" -maxdepth 1 -mindepth 1 -type d | head -1); \
	if [ -z "$$SNAP" ]; then \
	    echo "error: no snapshot found under $(SNAPSHOTS)" >&2; \
	    exit 1; \
	fi; \
	if [ ! -x "$(CLI)" ]; then \
	    echo "error: $(CLI) not found -- run: make build" >&2; \
	    exit 1; \
	fi; \
	$(CLI) \
	    -m "$$SNAP"/$(MODEL_FILE) \
	    -c $(DEMO_CTX) \
	    --jinja \
	    --temp $(TEMP) --top-p $(TOP_P) --top-k $(TOP_K) \
	    -st -p "$(DEMO_PROMPT)"

# gate for every target that talks to a running server, so they fail with one
# message instead of a client-side timeout or a connection refused
check-server:
	@CODE=$$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://$(HOST):$(PORT)/health 2>/dev/null); \
	case "$$CODE" in \
	    200) ;; \
	    503) echo "error: llama-server on $(HOST):$(PORT) is still loading the model" >&2; exit 1 ;; \
	    *)   echo "error: no llama-server on $(HOST):$(PORT) (health: $${CODE:-no response}) -- run: make run" >&2; exit 1 ;; \
	esac

chat: check-server
	@set -o pipefail; \
	export ALIAS="$(ALIAS)" CHAT_PROMPT="$(CHAT_PROMPT)" CHAT_TOKENS="$(CHAT_TOKENS)" \
	       TEMP="$(TEMP)" TOP_P="$(TOP_P)" TOP_K="$(TOP_K)" CHAT_REASONING="$(CHAT_REASONING)"; \
	python3 -c 'import json, os, sys; json.dump({"model": os.environ["ALIAS"], "messages": [{"role": "user", "content": os.environ["CHAT_PROMPT"]}], "max_tokens": int(os.environ["CHAT_TOKENS"]), "temperature": float(os.environ["TEMP"]), "top_p": float(os.environ["TOP_P"]), "top_k": int(os.environ["TOP_K"])}, sys.stdout)' \
	| curl -s -m $(CHAT_TIMEOUT) http://$(HOST):$(PORT)/v1/chat/completions \
	    -H 'Content-Type: application/json' -d @- \
	| python3 -c 'import json, os, sys; \
	d = json.load(sys.stdin); \
	sys.exit("error: " + json.dumps(d["error"])) if "error" in d else None; \
	c = d["choices"][0]; m = c["message"]; u = d.get("usage", {}); \
	body = (m.get("content") or "").strip(); \
	trace = (m.get("reasoning_content") or "").strip(); \
	print(trace, file=sys.stderr) if trace and os.environ.get("CHAT_REASONING") == "1" else None; \
	print(body) if body else None; \
	print("[finish: %s  tokens: %s prompt / %s completion]" % (c.get("finish_reason"), u.get("prompt_tokens"), u.get("completion_tokens")), file=sys.stderr); \
	sys.exit("error: content empty -- all %s tokens went to reasoning_content. Raise CHAT_TOKENS (now %s), or CHAT_REASONING=1 to see the trace." % (u.get("completion_tokens"), os.environ["CHAT_TOKENS"])) if not body else None'

# $(1) output path, $(2) directory to guard ("" for none). opencode evaluates
# the LAST matching permission rule, so the broad "*" goes first and the narrow
# deny last.
#
# The guard is a *substring* pattern on the directory's basename, not its
# absolute path, and that is not a shortcut -- edit patterns are matched against
# path.relative(worktree, target), so an absolute pattern silently never fires.
# Both "$(2)/**" and "../*" were tried against a real session and the write went
# through both times; "*basename*" is what actually denied it, and it holds
# whatever the path relativizes to. Patterns are regex-anchored with * -> .*, so
# a leading and trailing * is a plain substring match.
#
# bash needs its own rule: edit only governs the write/edit tools, and a model
# told "no" by those will reach for `echo > file` next (measured). Its patterns
# match the command string, which a determined model can trivially rephrase --
# hence OC_BASH=ask as the real backstop, with the substring deny on top.
# external_directory patterns *are* absolute paths, and $(2) is allowed there so
# the session can still read this repo without prompting.
OC_BASH ?= ask
define oc-write-config
ALIAS="$(ALIAS)" HOST="$(HOST)" PORT="$(PORT)" OC_PROVIDER="$(OC_PROVIDER)" \
OC_CTX="$(OC_CTX)" OC_MAX_TOKENS="$(OC_MAX_TOKENS)" TEMP="$(TEMP)" TOP_P="$(TOP_P)" \
OC_BASH="$(OC_BASH)" OC_PROTECT="$(2)" python3 -c 'import json, os, sys; \
e = os.environ; \
model = {"name": e["ALIAS"] + " (llama.cpp)", "attachment": True, "reasoning": True, "tool_call": True, "temperature": True, "limit": {"context": int(e["OC_CTX"]), "output": int(e["OC_MAX_TOKENS"])}, "options": {"temperature": float(e["TEMP"]), "top_p": float(e["TOP_P"])}}; \
provider = {"name": "llama.cpp (local)", "npm": "@ai-sdk/openai-compatible", "options": {"baseURL": "http://%s:%s/v1" % (e["HOST"], e["PORT"])}, "models": {e["ALIAS"]: model}}; \
cfg = {"$$schema": "https://opencode.ai/config.json", "model": e["OC_PROVIDER"] + "/" + e["ALIAS"], "provider": {e["OC_PROVIDER"]: provider}}; \
p = e.get("OC_PROTECT"); \
guard = "*" + os.path.basename(p.rstrip("/")) + "*" if p else None; \
cfg.update({"permission": {"edit": {"*": "allow", guard: "deny"}, "bash": {"*": e["OC_BASH"], guard: "deny"}, "external_directory": {"*": "ask", p + "/**": "allow"}}}) if p else None; \
json.dump(cfg, sys.stdout, indent=2); \
print()' > $(1).tmp && mv $(1).tmp $(1)
endef

# opencode merges ./$(OC_CONFIG) over ~/.config/opencode/opencode.json, so the
# provider only exists while opencode runs from this directory. Regenerate after
# changing HOST/PORT/ALIAS/CTX/NP -- the checked-in file holds the defaults.
opencode-config:
	@$(call oc-write-config,$(OC_CONFIG),)
	@echo "wrote $(OC_CONFIG): $(OC_MODEL) -> http://$(HOST):$(PORT)/v1 (context $(OC_CTX), max output $(OC_MAX_TOKENS))"

opencode: check-server opencode-check
	$(OPENCODE) --model $(OC_MODEL)

# headless equivalent of chat, but through opencode's agent loop (tools and all)
opencode-run: check-server opencode-check
	$(OPENCODE) run --model $(OC_MODEL) "$(OC_PROMPT)"

# OPENCODE_CONFIG loads an *additional* config, so the global one (and its
# providers) still applies -- only the cwd-based project config is left behind,
# which is the point: this repo stops being the project opencode edits.
opencode-sandbox: check-server opencode-check
	@$(call oc-write-config,$(OC_SANDBOX_CONFIG),$(CURDIR))
	@mkdir -p "$(OC_SANDBOX)"
	@echo "opencode sandbox: $(OC_SANDBOX)  (edits outside it are denied; $(CURDIR) stays readable)"
	cd "$(OC_SANDBOX)" && OPENCODE_CONFIG="$(CURDIR)/$(OC_SANDBOX_CONFIG)" $(OPENCODE) --model $(OC_MODEL)

opencode-check:
	@if ! command -v $(OPENCODE) >/dev/null 2>&1; then \
	    echo "error: $(OPENCODE) not found -- install it: brew install opencode" >&2; \
	    exit 1; \
	fi; \
	if [ ! -f "$(OC_CONFIG)" ]; then \
	    echo "error: $(OC_CONFIG) not found -- run: make opencode-config" >&2; \
	    exit 1; \
	fi

download-models:
	@if [ ! -x "$(LLAMA)" ]; then \
	    echo "error: $(LLAMA) not found -- run: make build" >&2; \
	    exit 1; \
	fi
	$(LLAMA) download -hf $(HF_MODEL) -hff $(MODEL_FILE)
	$(LLAMA) download -hf $(HF_MODEL) -hff $(MMPROJ_FILE)
	$(LLAMA) download -hf $(HF_MODEL) -hff $(DRAFT_FILE)

list-models:
	@if [ ! -d "$(SNAPSHOTS)" ]; then \
	    echo "error: $(SNAPSHOTS) not found -- run: make download-models" >&2; \
	    exit 1; \
	fi; \
	ls -lhL "$(SNAPSHOTS)"/*/

run:
	@set -o pipefail; \
	SNAP=$$(find "$(SNAPSHOTS)" -maxdepth 1 -mindepth 1 -type d | head -1); \
	if [ -z "$$SNAP" ]; then \
	    echo "error: no snapshot found under $(SNAPSHOTS)" >&2; \
	    exit 1; \
	fi; \
	if [ ! -x "$(SERVER)" ]; then \
	    echo "error: $(SERVER) not found -- build it first (see: make build-help)" >&2; \
	    exit 1; \
	fi; \
	$(SERVER) \
	    -m       "$$SNAP"/$(MODEL_FILE) \
	    --mmproj "$$SNAP"/$(MMPROJ_FILE) \
	    -a $(ALIAS) \
	    -c $(CTX) -np $(NP) \
	    --host $(HOST) --port $(PORT) \
	    --jinja \
	    --temp $(TEMP) --top-p $(TOP_P) --top-k $(TOP_K) 2>&1 | tee $(LOG)

build-help:
	@echo "The upstream Makefile build was replaced by CMake."
	@echo "See: https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md"
