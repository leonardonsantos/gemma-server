#!/data/data/com.termux/files/usr/bin/bash
#
# gemma-server installer — native LiteRT-LM on Android/Termux via the CMake Super-Build.
#
#   curl -fsSL https://raw.githubusercontent.com/leonardonsantos/gemma-server/main/install.sh | bash
#
# This script is self-contained. It:
#   1. Installs the Termux toolchain (clang, cmake, rust, openjdk-17, zlib, …).
#   2. Clones google-ai-edge/LiteRT-LM and compiles the native `litert_lm_main`
#      binary on-device (Bionic libc, no glibc fallback). See upstream issue #2413.
#   3. Downloads the Gemma model from HuggingFace.
#   4. Writes an OpenAI-compatible HTTP server (Python stdlib) and a `gemma-server`
#      launcher into ~/.gemma-server.
#
# Every step is idempotent and resumable: re-running skips work already done.
# Override behaviour with environment variables (see CONFIG below).

set -Eeuo pipefail

# ── Config (override via environment) ────────────────────────────────────────
PREFIX_HOME="${HOME}"
GEMMA_HOME="${GEMMA_HOME:-$PREFIX_HOME/.gemma-server}"
SRC_DIR="${GEMMA_SRC_DIR:-$GEMMA_HOME/LiteRT-LM}"
BUILD_DIR="$SRC_DIR/cmake/build"
MODEL_DIR="${GEMMA_MODEL_DIR:-$PREFIX_HOME/models}"
MODEL_FILE="${GEMMA_MODEL_FILE:-$MODEL_DIR/gemma-4-E2B-it.litertlm}"
MODEL_URL="${GEMMA_MODEL_URL:-https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm?download=true}"
LITERTLM_REPO="${LITERTLM_REPO:-https://github.com/google-ai-edge/LiteRT-LM}"
LITERTLM_REF="${LITERTLM_REF:-main}"
REBUILD="${REBUILD:-0}"
SKIP_MODEL="${SKIP_MODEL:-0}"
BUILD_JOBS="${BUILD_JOBS:-auto}"
GEMMA_ANDROID_API="${GEMMA_ANDROID_API:-30}"
SERVER_BIN="$GEMMA_HOME/litert_lm_main"
BIN_DIR="$PREFIX_HOME/.local/bin"

# ── Pretty output ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()  { echo -e "${BLUE}==>${NC} ${BLUE}$*${NC}"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
trap 'error "Installation failed on line $LINENO. Fix the issue above and re-run — completed steps are skipped."' ERR

# ── 0. Preflight ─────────────────────────────────────────────────────────────
step "Preflight checks"

[ -n "${PREFIX:-}" ] && [ -d "/data/data/com.termux/files/usr" ] \
    || warn "This does not look like Termux. The script targets Termux/Android; continuing anyway."

ARCH="$(uname -m)"
[ "$ARCH" = "aarch64" ] || warn "Architecture is '$ARCH' (expected aarch64). The model is ARM64-only."

# Disk space (need ~8 GB: model ~2.6 GB + build tree + deps)
avail_kb="$(df -Pk "$PREFIX_HOME" | awk 'NR==2{print $4}')"
avail_gb=$(( avail_kb / 1024 / 1024 ))
info "Free space in $PREFIX_HOME: ${avail_gb} GB"
[ "$avail_gb" -ge 8 ] || warn "Less than 8 GB free — the build + model may not fit."

# RAM / swap
mem_total_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
swap_total_kb="$(awk '/SwapTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
mem_gb=$(( mem_total_kb / 1024 / 1024 ))
swap_gb=$(( swap_total_kb / 1024 / 1024 ))
info "RAM: ${mem_gb} GB, swap: ${swap_gb} GB"
if [ $(( mem_gb + swap_gb )) -lt 6 ]; then
    warn "Upstream recommends ~5.5 GB RAM + swap for the build. With less, expect OOM (Signal 9)."
    warn "Add swap, e.g.: mkdir -p ~/swap && dd if=/dev/zero of=~/swap/file bs=1M count=6144 && mkswap ~/swap/file && sudo swapon ~/swap/file"
fi

# Decide parallel jobs: RAM/8GB, min 1, capped at nproc.
if [ "$BUILD_JOBS" = "auto" ]; then
    ncpu="$(nproc 2>/dev/null || echo 4)"
    j=$(( (mem_gb + swap_gb) / 8 ))
    [ "$j" -lt 1 ] && j=1
    [ "$j" -gt "$ncpu" ] && j="$ncpu"
    BUILD_JOBS="$j"
fi
info "Build parallelism: -j${BUILD_JOBS}  (low on purpose — high -j causes OOM-kills)"

mkdir -p "$GEMMA_HOME" "$MODEL_DIR" "$BIN_DIR"

# ── 1. Toolchain ─────────────────────────────────────────────────────────────
step "Installing the build toolchain"
if command -v pkg >/dev/null 2>&1; then
    pkg update -y
    # clang/cmake/make/ninja: build. git: clone. rust: llguidance. openjdk-17: ANTLR4.
    # zlib/openssl/libcurl: deps probed by CMake. python: the HTTP server. binutils/patch: misc.
    # libglvnd-dev: EGL/GLES/KHR headers for TFLite's GPU GL delegate (headers only;
    # Termux ships no EGL/egl.h otherwise, and the delegate is compiled unconditionally).
    # vulkan-headers: <vulkan/vulkan.h> pulled in by the same GPU delegate (headers only).
    pkg install -y \
        clang cmake make ninja git rust python \
        openjdk-17 zlib openssl libcurl binutils patch which curl libglvnd-dev vulkan-headers
else
    warn "'pkg' not found — install equivalents of: clang cmake make ninja git rust python openjdk-17 zlib openssl libcurl"
fi
info "clang: $(clang --version 2>/dev/null | head -1)"
info "cmake: $(cmake --version 2>/dev/null | head -1)"
info "rustc: $(rustc --version 2>/dev/null || echo 'missing')"
info "java:  $(java -version 2>&1 | head -1 || echo 'missing')"

# ── 2. Clone LiteRT-LM ───────────────────────────────────────────────────────
step "Fetching LiteRT-LM source ($LITERTLM_REF)"
if [ -d "$SRC_DIR/.git" ]; then
    info "Reusing existing clone at $SRC_DIR"
    git -C "$SRC_DIR" fetch --depth 1 origin "$LITERTLM_REF" || warn "fetch failed; using current checkout"
    git -C "$SRC_DIR" checkout -q "$LITERTLM_REF" 2>/dev/null || true
    git -C "$SRC_DIR" reset --hard "origin/$LITERTLM_REF" 2>/dev/null || true
else
    git clone --depth 1 --branch "$LITERTLM_REF" "$LITERTLM_REPO" "$SRC_DIR" \
        || git clone --depth 1 "$LITERTLM_REPO" "$SRC_DIR"
fi

# --- Native KleidiAI link fix ------------------------------------------------
# On aarch64, XNNPACK is built with KleidiAI and references its kai_* microkernels
# (xnnpack/src/reference/packing.cc). But LiteRT-LM only adds libkleidiai.a to the
# TFLite link map when cross-compiling:
#     if(LITERTLM_TOOLCHAIN_ARGS)
#         list(APPEND TFLITE_TARGET_MAP "kleidiai=${TFLITE_LIB_DIR}/libkleidiai.a")
#     endif()
# A native Termux build leaves LITERTLM_TOOLCHAIN_ARGS empty, so the archive is
# never linked and the run_model/litert_lm_main link fails with hundreds of
# "undefined symbol: kai_*". Broaden the guard to also fire on native aarch64.
# (Re-applied every run because the clone step does `git reset --hard`.)
TARGET_MAP="$SRC_DIR/cmake/packages/tflite/tflite_target_map.cmake"
if [ -f "$TARGET_MAP" ] && ! grep -q 'CMAKE_SYSTEM_PROCESSOR MATCHES.*aarch64' "$TARGET_MAP"; then
    sed -i.bak \
        's/if(LITERTLM_TOOLCHAIN_ARGS)/if(LITERTLM_TOOLCHAIN_ARGS OR CMAKE_SYSTEM_PROCESSOR MATCHES "(aarch64|arm64|armv8)")/' \
        "$TARGET_MAP" \
        && rm -f "$TARGET_MAP.bak" \
        && info "Patched TFLite target map to link libkleidiai.a on native aarch64."
fi

# --- Flatbuffer schema generation ordering fix -------------------------------
# The schema header `schema/core/litertlm_header_schema_generated.h` is produced
# by flatc via a `compile_schemas` step on the `flatbuffers_external` target. But
# every LiteRT-LM library only depends on the `generator_complete` aggregate,
# which lists protobuf + cxxbridge generation and NOT flatbuffers. With a parallel
# `-j` build the schema .cc files (schema_core_litertlm_utils/read/print) compile
# before flatc runs -> "fatal error: '...litertlm_header_schema_generated.h' file
# not found". A clean (REBUILD=1) build reliably exposes the race. Make
# generator_complete depend on flatbuffers_external so the gate waits for flatc.
LM_CML="$SRC_DIR/cmake/packages/litert_lm/CMakeLists.txt"
if [ -f "$LM_CML" ] && ! grep -q 'gemma-server.*flatbuffers schema gate' "$LM_CML"; then
    cat >> "$LM_CML" <<'CMAKE_EOF'

# [gemma-server] flatbuffers schema gate: ensure flatc has generated the schema
# headers before any LiteRT-LM library compiles (fixes parallel-build race on
# litertlm_header_schema_generated.h).
if(TARGET generator_complete AND TARGET flatbuffers_external)
    add_dependencies(generator_complete flatbuffers_external)
endif()
CMAKE_EOF
    info "Patched litert_lm CMakeLists to gate compilation on flatc schema generation."
fi

# On a *resume* (flatbuffers already installed), upstream replaces the real
# ExternalProject with a do-nothing `add_custom_target(flatbuffers_external)`, so
# the schema headers are never (re)generated and the build fails at ~66% again.
# Make that fallback target actually recompile the schemas with the host flatc.
FB_CML="$SRC_DIR/cmake/packages/flatbuffers/flatbuffers.cmake"
if [ -f "$FB_CML" ] && ! grep -q 'gemma-server] Recompiling' "$FB_CML"; then
    sed -i.bak \
        's|add_custom_target(flatbuffers_external)|add_custom_target(flatbuffers_external ALL COMMAND ${CMAKE_COMMAND} -D FLATC_BIN=${FLATC_EXECUTABLE} -D SCHEMA_DIR=${GENERATED_SRC_DIR}/schema -P ${LITERTLM_SCRIPTS_DIR}/compile_flatbuffers.cmake COMMENT "[gemma-server] Recompiling Flatbuffer schemas")|' \
        "$FB_CML" \
        && rm -f "$FB_CML.bak" \
        && info "Patched flatbuffers fallback target to recompile schemas on resume."
fi

# --- LiteRT API drift fix ----------------------------------------------------
# LiteRT-LM `main` has drifted ahead of the LiteRT commit it pins
# (cmake/packages/litert/litert.cmake, fb16353…, 2026-03-24): it calls two
# option setters that don't exist in that LiteRT yet, so compilation fails at
# ~88% in runtime/executor/llm_executor_settings_utils.cc:
#   * litert::GpuOptions::SetKernelBatchSize
#   * litert::RuntimeOptions::SetDisableDelegateClustering
# Both are optional tuning hints: SetKernelBatchSize is GPU-only and only fires
# when an (unset-by-default) hint is present; SetDisableDelegateClustering just
# forwards a default-valued flag on the CPU path. Drop both calls so the source
# matches the pinned LiteRT API; default inference is unaffected. (Bumping the
# LiteRT pin instead would risk the fb16353-specific fixes already in place.)
LM_EXEC="$SRC_DIR/runtime/executor/llm_executor_settings_utils.cc"
if [ -f "$LM_EXEC" ]; then
    python3 - "$LM_EXEC" <<'PY' && info "Patched llm_executor_settings_utils.cc to drop setters absent in pinned LiteRT."
import re, sys
p = sys.argv[1]
s = open(p).read()
marker = "gemma-server: setter absent in pinned LiteRT"
if marker not in s:
    repl = "; /* %s */" % marker
    s = re.sub(r'gpu_compilation_options\.SetKernelBatchSize\([^;]*;', repl, s)
    s = re.sub(r'runtime_options\.SetDisableDelegateClustering\([^;]*;', repl, s)
    open(p, 'w').write(s)
PY
fi

# ── 3. Build the native binary ───────────────────────────────────────────────
# The top-level CMake project is an *orchestrator*: it wraps the real build in an
# ExternalProject named `litert_lm`. There is no top-level `litert_lm_main`
# target (building `-t litert_lm_main` fails with "No rule to make target"), so we
# build the default target and then locate the binary inside the sub-build tree.
step "Building litert_lm (orchestrator → litert_lm_main; can take several hours)"

find_built_binary() {
    find "$BUILD_DIR" -type f -name litert_lm_main 2>/dev/null | head -n1
}

EXISTING_BIN="$(find_built_binary || true)"
if [ -n "$EXISTING_BIN" ] && [ "$REBUILD" != "1" ]; then
    info "Binary already built — skipping (set REBUILD=1 to force a rebuild)."
else
    # --- Native host-tool wiring -------------------------------------------------
    # The orchestrator builds protoc/flatc in a "Host Prebuild" phase only when
    # cross-compiling. On a native Termux build that phase is skipped, yet the
    # orchestrator still defaults LITERTLM_HOST_PROTOC/FLATC to the (never built)
    # prebuild directory. Proto/flatc codegen then fails right after
    # `protobuf_external` builds. Since host == target here, point the host tools
    # at the in-tree binaries the build itself produces (version-matched, runnable
    # on-device). These paths mirror the ExternalProject BINARY_DIR layout.
    inner="$BUILD_DIR/litert_lm/build"
    host_protoc_bin="$inner/external/protobuf/install/bin"
    host_flatc_bin="$inner/external/flatbuffers/install/bin"

    # --- Android system libraries (liblog / EGL / GLES) -------------------------
    # Several upstream targets resolve system libraries via find_library():
    #   * TFLite's `benchmark_model`            -> ANDROID_LOG_LIB  (log)
    #   * LiteRT runtime / C-API shared lib     -> ANDROID_EGL_LIB  (EGL),
    #                                              ANDROID_GLESV2_LIB (GLESv2),
    #                                              ANDROID_GLESV3_LIB (GLESv3)
    # These ship only in Android's read-only system image (/system/lib{,64}) and
    # are NOT present as linkable .so files in Termux's $PREFIX/lib, so the finds
    # return NOTFOUND and CMake's generate step aborts. Since host == target
    # on-device, the system libs are ABI compatible: expose linkable symlinks in
    # $PREFIX/lib so `-llog`, `-lEGL`, `-lGLESv2`, `-lGLESv3` resolve.
    #
    # Note: Android has no standalone `libGLESv3.so` — GLES v3 entry points live
    # in the `libGLESv2.so` loader — so `find_library(GLESv3)` would still fail.
    # We therefore map each linker name to an ordered list of system-lib
    # candidates and symlink the first that exists (GLESv3 falls back to GLESv2).
    link_system_lib() {
        # $1 = linker name to expose (e.g. libGLESv3); $2.. = source basenames
        local want="$1"; shift
        [ -e "$PREFIX/lib/$want.so" ] && return 0
        local cand
        for cand in "$@"; do
            for dir in "$sys_libdir" /system/lib64 /system/lib /vendor/lib64 /vendor/lib; do
                if [ -e "$dir/$cand.so" ]; then
                    ln -sf "$dir/$cand.so" "$PREFIX/lib/$want.so" \
                        && info "Linked $want -> $dir/$cand.so into \$PREFIX/lib."
                    return 0
                fi
            done
        done
        return 1
    }
    if [ -n "${PREFIX:-}" ]; then
        case "$(uname -m)" in
            aarch64|arm64|x86_64) sys_libdir="/system/lib64" ;;
            *)                    sys_libdir="/system/lib"   ;;
        esac
        link_system_lib liblog       liblog                || warn "liblog not found; TFLite/LiteRT link may fail."
        link_system_lib libEGL       libEGL                || warn "libEGL not found; LiteRT GPU link may fail."
        link_system_lib libGLESv2    libGLESv2             || warn "libGLESv2 not found; LiteRT GPU link may fail."
        # No standalone libGLESv3.so on Android -> fall back to the v2 loader.
        link_system_lib libGLESv3    libGLESv3 libGLESv2   || warn "libGLESv3 not found; LiteRT GPU link may fail."
        link_system_lib libGLESv1_CM libGLESv1_CM          || true

        # --- Stub archives for header-only INTERFACE targets --------------------
        # Upstream LiteRT defines `litert_cc_options` (and the consumer bundle
        # `litert_runtime_c_api_static`) as INTERFACE libraries, but several
        # shared targets (libLiteRt.so, libLiteRtDispatch_*.so) list them in
        # target_link_libraries. In this source-build configuration CMake emits
        # them as plain link items (`-llitert_cc_options`); since an INTERFACE
        # library produces no artifact, ld.lld fails with "unable to find
        # library". The actual option symbols are compiled into `litert_cc_api`
        # (linked separately) and `litert_c_options` is pulled in transitively via
        # `litert_c_api`, so dropping empty, valid stub archives on the linker
        # search path ($PREFIX/lib is on the default path — see the symlinks
        # above) satisfies `-l<name>` harmlessly. When CMake does resolve the
        # INTERFACE target correctly, the stub is simply never referenced.
        _stub_obj="$(mktemp "${TMPDIR:-/tmp}/gemma_stub.XXXXXX.o")"
        if echo 'static int _gemma_litert_stub;' | clang -x c -c -o "$_stub_obj" - 2>/dev/null; then
            for _ilib in litert_cc_options litert_runtime_c_api_static; do
                ar rcs "$PREFIX/lib/lib$_ilib.a" "$_stub_obj" 2>/dev/null \
                    && info "Created stub lib$_ilib.a (header-only INTERFACE target)."
            done
        else
            warn "Could not build INTERFACE stub archives; LiteRT shared-lib link may fail."
        fi
        rm -f "$_stub_obj"
    fi

    cmake -B "$BUILD_DIR" -S "$SRC_DIR" -G "Unix Makefiles" \
        -DCMAKE_BUILD_TYPE=Release \
        -DLITERTLM_HOST_PROTOC="$host_protoc_bin/protoc" \
        -DLITERTLM_HOST_PROTOC_BIN_DIR="$host_protoc_bin" \
        -DLITERTLM_HOST_FLATC="$host_flatc_bin/flatc" \
        -DLITERTLM_HOST_FLATC_BIN_DIR="$host_flatc_bin"

    # The build compiles Rust crates (cxx, llguidance) via cc-rs. cc-rs invokes
    # clang with `--target=aarch64-linux-android` (no API suffix), which resolves
    # to a default API level below 30. Bionic's libc++ <condition_variable>
    # header then references `pthread_cond_clockwait` (introduced in API 30),
    # failing with "use of undeclared identifier". Pin the API level so the
    # symbol is visible. cc-rs appends these target-specific flags after its own
    # `--target`, and clang's last `--target` wins. Requires Android >= API 30.
    local_target="aarch64-linux-android${GEMMA_ANDROID_API}"
    export CFLAGS_aarch64_linux_android="--target=${local_target} ${CFLAGS_aarch64_linux_android:-}"
    export CXXFLAGS_aarch64_linux_android="--target=${local_target} ${CXXFLAGS_aarch64_linux_android:-}"
    export BINDGEN_EXTRA_CLANG_ARGS="--target=${local_target} ${BINDGEN_EXTRA_CLANG_ARGS:-}"
    info "Pinned Rust/cc-rs target to ${local_target} (override with GEMMA_ANDROID_API)."

    info "Compiling with -j${BUILD_JOBS} — grab a coffee (or two)…"
    # No -t: build the default `all` target, which drives the `litert_lm`
    # ExternalProject. The make jobserver propagates -j to the inner build.
    # Tee to a log so the real compile error is recoverable (parallel builds bury
    # it above the make failure cascade).
    BUILD_LOG="$GEMMA_HOME/build.log"
    if ! cmake --build "$BUILD_DIR" -j"${BUILD_JOBS}" 2>&1 | tee "$BUILD_LOG"; then
        echo ""
        warn "Build failed. Most relevant errors from the log:"
        grep -nE 'error:|fatal error:|No rule to make|undeclared identifier|cannot find' "$BUILD_LOG" | tail -n 30 || true
        error "Build failed — full log at $BUILD_LOG. Re-run to resume; for a clearer single error, retry with BUILD_JOBS=1."
    fi
fi

BUILT_BIN="$(find_built_binary || true)"
[ -n "$BUILT_BIN" ] || error "Build finished but no 'litert_lm_main' was produced under $BUILD_DIR."
cp -f "$BUILT_BIN" "$SERVER_BIN"
chmod +x "$SERVER_BIN"
info "Native binary built at: $BUILT_BIN"
info "Native binary installed: $SERVER_BIN"

# ── 4. Download the model ────────────────────────────────────────────────────
step "Downloading the Gemma model"
if [ "$SKIP_MODEL" = "1" ]; then
    info "SKIP_MODEL=1 — skipping model download."
elif [ -f "$MODEL_FILE" ] && [ "$(stat -c%s "$MODEL_FILE" 2>/dev/null || echo 0)" -gt 1000000000 ]; then
    info "Model already present ($(du -h "$MODEL_FILE" | cut -f1)): $MODEL_FILE"
else
    info "Fetching to $MODEL_FILE (~2.6 GB, resumable)…"
    # -C - resumes a partial download; -L follows the HF redirect.
    curl -fL -C - -o "$MODEL_FILE" "$MODEL_URL" \
        || error "Model download failed. Re-run to resume, or set GEMMA_MODEL_URL."
    info "Model downloaded: $(du -h "$MODEL_FILE" | cut -f1)"
fi

# ── 5. Write the HTTP server ─────────────────────────────────────────────────
step "Installing the OpenAI-compatible HTTP server"
cat > "$GEMMA_HOME/gemma_server.py" <<'PYEOF'
#!/usr/bin/env python3
"""OpenAI-compatible HTTP wrapper around the one-shot `litert_lm_main` binary.

NOTE: litert_lm_main has no server/REPL mode, so every request reloads the model.
Requests are therefore serialized and the wrapper reports mode="one-shot-wrapper".
"""
import json
import os
import re
import subprocess
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GEMMA_HOME = os.path.dirname(os.path.abspath(__file__))
BINARY = os.environ.get("GEMMA_BINARY", os.path.join(GEMMA_HOME, "litert_lm_main"))
MODEL_PATH = os.environ.get(
    "GEMMA_MODEL_FILE",
    os.path.join(os.path.expanduser("~"), "models", "gemma-4-E2B-it.litertlm"),
)
MODEL_ID = os.environ.get("GEMMA_MODEL_ID", "gemma-4-E2B")
BACKEND = os.environ.get("GEMMA_BACKEND", "cpu")
HOST = os.environ.get("GEMMA_HOST", "127.0.0.1")
PORT = int(os.environ.get("GEMMA_PORT", "8080"))
TIMEOUT = int(os.environ.get("GEMMA_TIMEOUT", "600"))
MAX_PROMPT_CHARS = int(os.environ.get("GEMMA_MAX_PROMPT_CHARS", "100000"))

# Only one inference at a time — a second 2.5 GB model load would OOM the device.
_infer_lock = threading.Lock()


def build_prompt(messages):
    """Flatten OpenAI chat messages into a single Gemma turn.

    litert_lm_main applies the model's Jinja chat template to the input, so we
    pass a readable role-labelled transcript as the user turn.
    """
    parts = []
    for m in messages:
        role = m.get("role", "user")
        content = m.get("content", "")
        if isinstance(content, list):  # OpenAI "parts" form
            content = "".join(p.get("text", "") for p in content if isinstance(p, dict))
        content = (content or "").strip()
        if not content:
            continue
        if role == "system":
            parts.append(f"[System instructions]\n{content}")
        elif role == "assistant":
            parts.append(f"Assistant: {content}")
        else:
            parts.append(f"User: {content}")
    return "\n\n".join(parts).strip()


_BENCH_RE = re.compile(r"^BenchmarkInfo:", re.M)


def clean_output(stdout, prompt):
    """Strip litert_lm_main's prompt echo and trailing BenchmarkInfo block."""
    text = stdout

    # Remove the leading "input_prompt: <prompt>" echo if present.
    lines = text.splitlines()
    if lines and lines[0].startswith("input_prompt:"):
        echoed = lines[0][len("input_prompt:"):].strip()
        drop = 1
        # The echoed prompt may span multiple lines; skip them all.
        if echoed and prompt.startswith(echoed):
            remaining = prompt[len(echoed):].lstrip("\n")
            extra = remaining.count("\n") + 1 if remaining else 0
            drop += extra
        text = "\n".join(lines[drop:])

    # Cut everything from the BenchmarkInfo separator onward.
    m = _BENCH_RE.search(text)
    if m:
        text = text[: m.start()]
    # Drop the dashed separator line that precedes the benchmark block.
    text = re.sub(r"\n-{10,}\s*$", "", text.rstrip())
    return text.strip()


def run_inference(prompt):
    """Invoke the binary once. Returns (text, error_or_None)."""
    if not os.path.exists(BINARY):
        return None, f"Binary not found: {BINARY}"
    if not os.path.exists(MODEL_PATH):
        return None, f"Model not found: {MODEL_PATH}"
    if len(prompt) > MAX_PROMPT_CHARS:
        return None, f"Prompt too long ({len(prompt)} > {MAX_PROMPT_CHARS} chars)."

    # Pass the prompt via a file (not argv) to avoid OS argument-length limits
    # and any shell-quoting concerns. shell=False, argv list — no injection.
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as fh:
        fh.write(prompt)
        prompt_file = fh.name
    try:
        with _infer_lock:
            proc = subprocess.run(
                [
                    BINARY,
                    f"--model_path={MODEL_PATH}",
                    f"--backend={BACKEND}",
                    f"--input_prompt_file={prompt_file}",
                ],
                shell=False,
                capture_output=True,
                text=True,
                timeout=TIMEOUT,
            )
    except subprocess.TimeoutExpired:
        return None, f"Inference timed out after {TIMEOUT}s."
    finally:
        try:
            os.unlink(prompt_file)
        except OSError:
            pass

    if proc.returncode != 0:
        tail = (proc.stderr or proc.stdout or "").strip()[-800:]
        return None, f"litert_lm_main exited with {proc.returncode}: {tail}"
    return clean_output(proc.stdout, prompt), None


class Handler(BaseHTTPRequestHandler):
    server_version = "gemma-server/2.0"

    def log_message(self, fmt, *args):
        print(f"[http] {self.address_string()} {fmt % args}")

    def _send_json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _error(self, code, message, etype="invalid_request_error"):
        self._send_json(code, {"error": {"message": message, "type": etype}})

    def do_GET(self):
        if self.path == "/health":
            self._send_json(200, {
                "status": "ok",
                "mode": "one-shot-wrapper",
                "persistent_model": False,
                "model": MODEL_ID,
                "backend": BACKEND,
                "model_path": MODEL_PATH,
                "binary": BINARY,
            })
        elif self.path == "/v1/models":
            self._send_json(200, {
                "object": "list",
                "data": [{"id": MODEL_ID, "object": "model", "owned_by": "google"}],
            })
        else:
            self._error(404, f"Unknown path: {self.path}", "not_found")

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            return self._error(404, f"Unknown path: {self.path}", "not_found")

        length = int(self.headers.get("Content-Length", 0) or 0)
        try:
            req = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            return self._error(400, "Invalid JSON body.")

        messages = req.get("messages")
        if not isinstance(messages, list) or not messages:
            return self._error(400, "'messages' must be a non-empty array.")

        # The wrapper reloads the model per call and serializes requests; refuse
        # if another inference holds the lock rather than queueing into an OOM.
        if _infer_lock.locked():
            return self._error(429, "Server busy: a model load/inference is already running. Retry shortly.", "rate_limit")

        prompt = build_prompt(messages)
        if not prompt:
            return self._error(400, "No usable text content in 'messages'.")

        text, err = run_inference(prompt)
        if err:
            return self._error(503, err, "engine_error")

        created = int(time.time())
        cid = "chatcmpl-" + uuid.uuid4().hex[:24]
        if req.get("stream"):
            self._stream(cid, created, text)
        else:
            self._send_json(200, {
                "id": cid,
                "object": "chat.completion",
                "created": created,
                "model": MODEL_ID,
                "choices": [{
                    "index": 0,
                    "message": {"role": "assistant", "content": text},
                    "finish_reason": "stop",
                }],
                "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
            })

    def _stream(self, cid, created, text):
        # Non-incremental: the one-shot binary produces the full answer at once,
        # so we emit it as a single SSE chunk for client compatibility.
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        def chunk(delta, finish=None):
            payload = {
                "id": cid, "object": "chat.completion.chunk", "created": created,
                "model": MODEL_ID,
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
            }
            self.wfile.write(f"data: {json.dumps(payload)}\n\n".encode())

        chunk({"role": "assistant"})
        chunk({"content": text})
        chunk({}, finish="stop")
        self.wfile.write(b"data: [DONE]\n\n")


def main():
    print(f"gemma-server (one-shot wrapper)")
    print(f"  binary : {BINARY}")
    print(f"  model  : {MODEL_PATH}")
    print(f"  backend: {BACKEND}")
    print(f"  listen : http://{HOST}:{PORT}")
    if HOST in ("127.0.0.1", "localhost"):
        print("  (bound to localhost; set GEMMA_HOST=0.0.0.0 to expose on the LAN)")
    print("  NOTE: the model reloads on every request — expect per-request latency.")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
PYEOF
info "HTTP server written: $GEMMA_HOME/gemma_server.py"

# ── 6. Launcher ──────────────────────────────────────────────────────────────
cat > "$BIN_DIR/gemma-server" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
# Launcher for gemma-server. Env vars (GEMMA_BACKEND, GEMMA_HOST, GEMMA_PORT, …) override defaults.
export GEMMA_BINARY="\${GEMMA_BINARY:-$SERVER_BIN}"
export GEMMA_MODEL_FILE="\${GEMMA_MODEL_FILE:-$MODEL_FILE}"
exec python3 "$GEMMA_HOME/gemma_server.py" "\$@"
EOF
chmod +x "$BIN_DIR/gemma-server"
info "Launcher installed: $BIN_DIR/gemma-server"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        if ! grep -q "/.local/bin" "$PREFIX_HOME/.bashrc" 2>/dev/null; then
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$PREFIX_HOME/.bashrc"
        fi
        warn "Added $BIN_DIR to PATH in ~/.bashrc — run 'source ~/.bashrc' or open a new session."
        ;;
esac

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
step "Setup complete!"
cat <<EOF

  Start the server:
    gemma-server
        or
    python3 $GEMMA_HOME/gemma_server.py

  Test it (from another Termux session):
    curl http://localhost:8080/health
    curl http://localhost:8080/v1/chat/completions \\
      -H 'Content-Type: application/json' \\
      -d '{"model":"gemma-4-E2B","messages":[{"role":"user","content":"Hello!"}]}'

  Paths:
    binary : $SERVER_BIN
    model  : $MODEL_FILE
    server : $GEMMA_HOME/gemma_server.py

  The model reloads on every request (litert_lm_main is one-shot). See README.md.
EOF
