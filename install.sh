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
# Runtime dir for prebuilt shared libs the binary dlopen/links against
# (e.g. libGemmaModelConstraintProvider.so). Added to LD_LIBRARY_PATH by the launcher.
LIB_DIR="$GEMMA_HOME/lib"
# Prebuilt (closed-source) Gemma constraint provider .so, shipped via git-LFS in the
# LiteRT-LM tree. The CMake build links it; the Gemma data processors call its C API.
GEMMA_PREBUILT_SO="libGemmaModelConstraintProvider.so"
GEMMA_PREBUILT_REL="prebuilt/android_arm64/$GEMMA_PREBUILT_SO"
GEMMA_PREBUILT_URL="${GEMMA_PREBUILT_URL:-$LITERTLM_REPO/raw/$LITERTLM_REF/$GEMMA_PREBUILT_REL}"

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
# (cmake/packages/litert/litert.cmake, fb16353…, 2026-03-24): it calls a handful
# of option setters that don't exist in that LiteRT yet, so compilation fails in
# runtime/executor/*.cc. A full scan of every GpuOptions/RuntimeOptions/CpuOptions
# /CompilationOptions call in the tree against the pinned headers found exactly
# three absent setters:
#   * litert::GpuOptions::SetKernelBatchSize        (~88%, llm_executor_settings_utils.cc)
#   * litert::RuntimeOptions::SetDisableDelegateClustering (~88%, same file)
#   * litert::GpuOptions::SetWeightCacheFd          (~94%, litert_compiled_model_executor_utils.cc)
# All three are optional tuning hints with no effect on default inference:
# SetKernelBatchSize is GPU-only and gated on an unset-by-default hint;
# SetDisableDelegateClustering forwards a default-valued flag on the CPU path;
# SetWeightCacheFd only feeds a GPU weight-cache fd (we keep the fd local valid
# via a (void) cast to avoid an unused-variable error). Drop the calls so the
# source matches the pinned LiteRT API. (Bumping the LiteRT pin instead would risk
# the fb16353-specific fixes already in place — cc_options stubs, kleidiai, etc.)
for _f in runtime/executor/llm_executor_settings_utils.cc \
          runtime/executor/litert_compiled_model_executor_utils.cc; do
    _path="$SRC_DIR/$_f"
    [ -f "$_path" ] || continue
    python3 - "$_path" <<'PY' && info "Patched $(basename "$_path") for setters absent in pinned LiteRT."
import re, sys
p = sys.argv[1]
s = open(p).read()
marker = "gemma-server: setter absent in pinned LiteRT"
if marker not in s:
    drop = "; /* %s */" % marker
    # Pure-side-effect setters whose arguments are member expressions: drop entirely.
    s = re.sub(r'gpu_compilation_options\.SetKernelBatchSize\([^;]*;', drop, s)
    s = re.sub(r'runtime_options\.SetDisableDelegateClustering\([^;]*;', drop, s)
    # SetWeightCacheFd takes a bare local fd: keep the local "used" via (void).
    s = re.sub(r'gpu_options\.SetWeightCacheFd\(\s*([A-Za-z0-9_]+)\s*\)\s*;',
               r'(void)\1; /* %s */' % marker, s)
    open(p, 'w').write(s)
PY
done

# --- LiteRT NPU / GoogleTensor drift fix (CPU/GPU-only build) -----------------
# The pin drift also reaches the NPU (Google Tensor) and audio executors, which
# call LiteRT APIs absent at fb16353 (~95%):
#   * litert::google_tensor::GoogleTensorOptions::SetPerformanceMode / ::PerformanceMode
#   * litert::SimpleTensor::HasQuantization / ::PerTensorQuantization
# These only run on the NPU backend, which Gemma-on-Termux never uses (CPU/GPU
# only). LiteRT-LM already supports a CPU/GPU-only build via the LITERT_DISABLE_NPU
# macro: it #if-guards every NPU/GoogleTensor reference in the factory, audio,
# vision and util sources, so the factory's lone NPU call site (and all the
# drifted GoogleTensorOptions calls) compile out. Define it for the inner build —
# far more robust than chasing each individually drifted NPU symbol.
if [ -f "$LM_CML" ] && ! grep -q 'LITERT_DISABLE_NPU' "$LM_CML"; then
    # Append the macro to the existing global add_compile_definitions() block so
    # it applies to the runtime executor targets defined afterwards. (CMake allows
    # a trailing `#` line-comment inside a command's argument list.)
    sed -i.bak \
        's/^\([[:space:]]*\)absl_nonnull=$/\1absl_nonnull=\n\1LITERT_DISABLE_NPU  # [gemma-server] CPU\/GPU-only: drop NPU\/GoogleTensor paths/' \
        "$LM_CML" \
        && rm -f "$LM_CML.bak" \
        && info "Defined LITERT_DISABLE_NPU for the inner build (CPU/GPU-only)."
fi

# The NPU executor translation unit is itself NOT #if-guarded — it is always
# compiled into its own static lib — so LITERT_DISABLE_NPU alone still leaves it
# using the absent SimpleTensor/GoogleTensorOptions APIs. With the macro defined,
# nothing references its symbols (the factory's only call site is compiled out),
# so wrap the whole file in the same guard: it then compiles to an empty object.
_npu="$SRC_DIR/runtime/executor/llm_litert_npu_compiled_model_executor.cc"
if [ -f "$_npu" ] && ! grep -q 'gemma-server: NPU TU guarded' "$_npu"; then
    python3 - "$_npu" <<'PY' && info "Guarded NPU executor TU under LITERT_DISABLE_NPU."
import sys
p = sys.argv[1]
s = open(p).read()
head = "#if !defined(LITERT_DISABLE_NPU)  // gemma-server: NPU TU guarded\n"
tail = "\n#endif  // !defined(LITERT_DISABLE_NPU)  gemma-server: NPU TU guarded\n"
open(p, 'w').write(head + s + tail)
PY
fi

# --- Stale CMake source references (Bazel refactor drift) ---------------------
# LiteRT-LM's CMake files lag a Bazel refactor: several runtime/*/CMakeLists.txt
# list .cc sources that were renamed or removed, so the build fails late with
# "No rule to make target '…/<file>.cc'". A scan of every runtime CMakeLists for
# referenced-but-absent .cc files found these, all confirmed against the Bazel
# BUILD files:
#   * session_basic.cc      -> renamed session_advanced.cc (SessionBasic→SessionAdvanced)
#   * engine_impl.cc (x2)   -> renamed engine_advanced_impl.cc (engine_impl is now a Bazel alias)
#   * session_factory.cc    -> removed entirely (SessionFactory concept dropped)
#   * gemma_model_constraint_provider.cc -> never a source; it is a prebuilt .so
# Realign runtime/core/CMakeLists.txt to the renamed sources, and turn the now
# source-less session_factory target into an INTERFACE forwarder to session_basic
# (which builds session_advanced.cc) so its existing dependents still resolve.
CORE_CML="$SRC_DIR/runtime/core/CMakeLists.txt"
if [ -f "$CORE_CML" ] && ! grep -q 'gemma-server: core targets realigned' "$CORE_CML"; then
    python3 - "$CORE_CML" <<'PY' && info "Realigned runtime/core CMake targets to renamed sources."
import re, sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('session_basic.cc', 'session_advanced.cc')
s = s.replace('engine_impl.cc', 'engine_advanced_impl.cc')
# Replace the source-less STATIC session_factory target with an INTERFACE forwarder.
s = re.sub(
    r'add_litertlm_library\(runtime_core_session_factory STATIC.*?LITERTLM_DEPS\s*\n\)',
    'add_library(runtime_core_session_factory INTERFACE)\n'
    'add_library(LiteRTLM::Runtime::Core::SessionFactory ALIAS runtime_core_session_factory)\n'
    'target_link_libraries(runtime_core_session_factory INTERFACE\n'
    '  runtime_core_session_basic\n'
    ')',
    s, flags=re.S)
s += '\n# gemma-server: core targets realigned to renamed sources\n'
open(p, 'w').write(s)
PY
fi

# The Gemma constraint provider is a prebuilt, closed-source shared library (the
# tree carries only its header); the stale CMake tries to compile a non-existent
# gemma_model_constraint_provider.cc. The Gemma data processors call its C API,
# and litert_lm_main links them, so import the prebuilt .so instead of compiling.
CD_CML="$SRC_DIR/runtime/components/constrained_decoding/CMakeLists.txt"
if [ -f "$CD_CML" ] && ! grep -q 'gemma-server: import prebuilt provider' "$CD_CML"; then
    python3 - "$CD_CML" <<'PY' && info "Switched Gemma constraint provider to the prebuilt .so."
import re, sys
p = sys.argv[1]
s = open(p).read()
repl = (
'# gemma-server: import prebuilt provider (no source .cc upstream)\n'
'add_library(runtime_components_constrained_decoding_gemma_model_constraint_provider SHARED IMPORTED GLOBAL)\n'
'set_target_properties(runtime_components_constrained_decoding_gemma_model_constraint_provider PROPERTIES\n'
'  IMPORTED_LOCATION "${LITERTLM_PROJECT_ROOT}/prebuilt/android_arm64/libGemmaModelConstraintProvider.so"\n'
'  INTERFACE_INCLUDE_DIRECTORIES "${LITERTLM_INCLUDE_PATHS};${LITERT_INCLUDE_PATHS}"\n'
'  INTERFACE_LINK_LIBRARIES "LiteRTLM::Runtime::Components::ConstrainedDecoding::Constraint;LiteRTLM::Runtime::Util::ConvertTensorBuffer;LiteRTLM::Runtime::Util::LiteRtStatusUtil"\n'
')\n'
'add_library(LiteRTLM::Runtime::Components::ConstrainedDecoding::GemmaModelConstraintProvider ALIAS runtime_components_constrained_decoding_gemma_model_constraint_provider)'
)
s = re.sub(
    r'add_litertlm_library\(runtime_components_constrained_decoding_gemma_model_constraint_provider STATIC.*?LITERTLM_DEPS\s*\n\)',
    repl, s, flags=re.S)
open(p, 'w').write(s)
PY
fi

# Materialize the prebuilt provider .so: a plain clone leaves it as a ~133-byte
# git-LFS pointer, but the final link needs the real ~19 MB ELF. Fetch it from
# the GitHub media endpoint (the raw URL 302-redirects to the LFS object).
_gso="$SRC_DIR/$GEMMA_PREBUILT_REL"
if [ -f "$_gso" ] && head -c 64 "$_gso" 2>/dev/null | grep -q 'git-lfs.github.com'; then
    info "Fetching prebuilt $GEMMA_PREBUILT_SO (git-LFS object)…"
    if curl -fL "$GEMMA_PREBUILT_URL" -o "$_gso.tmp" \
        && [ "$(stat -c%s "$_gso.tmp" 2>/dev/null || echo 0)" -gt 100000 ]; then
        mv -f "$_gso.tmp" "$_gso"
        info "Prebuilt $GEMMA_PREBUILT_SO ready ($(du -h "$_gso" | cut -f1))."
    else
        rm -f "$_gso.tmp"
        warn "Could not fetch a real $GEMMA_PREBUILT_SO — the final link may fail."
    fi
fi

# --- Stale LiteRT target-map entry (pinned-LiteRT drift) ---------------------
# The litert aggregate links *every* static-lib path in litert_target_map.cmake
# directly into litert_lm_main. The map's most recent entry,
#   "litert::cc_options=${LITERT_BUILD_DIR}/cc/options/liblitert_cc_options.a"
# expects a standalone archive, but at the pinned LiteRT commit cc/options is an
# INTERFACE compatibility target whose sources (litert_compiler_options.cc) are
# compiled straight into liblitert_cc_api.a — so no liblitert_cc_options.a is
# ever produced and the final link dies with
#   "No rule to make target '…/cc/options/liblitert_cc_options.a'".
# Those symbols already live in liblitert_cc_api.a (also in the map), and nothing
# references litert::cc_options by name, so drop the stale entry.
LM_TARGET_MAP="$SRC_DIR/cmake/packages/litert/litert_target_map.cmake"
if [ -f "$LM_TARGET_MAP" ] && ! grep -q 'gemma-server: dropped stale cc_options' "$LM_TARGET_MAP"; then
    python3 - "$LM_TARGET_MAP" <<'PY' && info "Dropped stale litert::cc_options target-map entry."
import re, sys
p = sys.argv[1]
s = open(p).read()
# Remove the whole "litert::cc_options=...liblitert_cc_options.a" list element line.
s = re.sub(r'\n[ \t]*"litert::cc_options=[^"]*"', '', s)
s += '\n# gemma-server: dropped stale cc_options entry (folded into litert_cc_api)\n'
open(p, 'w').write(s)
PY
fi

# --- Missing CMake sources (Bazel refactor drift → undefined symbols at link) -
# Several sources exist in the tree and are compiled by Bazel but are absent from
# the CMake target lists, so the final link of litert_lm_main fails with
# "undefined symbol". The super-build auto-links EVERY add_litertlm_library
# STATIC archive into litert_lm_main (via LiteRTLM::Local::Aggregate), so simply
# compiling each orphaned source into its own STATIC target pulls the symbols in
# — no need to touch the factories/facades that consume them. Missing sources:
#   * runtime/engine/cpu_affinity_utils.cc            (IsPixelTensorDevice, …)
#   * runtime/conversation/channel_util.cc            (GetOpenChannelName, …)
#   * runtime/components/preprocessor/image_preprocessor_utils.cc (GetAspectRatioPreservingSize)
#   * runtime/conversation/model_data_processor/gemma4_data_processor.cc  (Gemma4DataProcessor::Create)
#   * runtime/conversation/model_data_processor/fastvlm_data_processor.cc (FastVlmDataProcessor::Create)
if ! grep -rq 'gemma-server: compile orphaned source' "$SRC_DIR/runtime" 2>/dev/null; then
    python3 - "$SRC_DIR" <<'PY' && info "Added orphaned CMake sources needed by litert_lm_main."
import os, sys
root = sys.argv[1]
MARK = '# gemma-server: compile orphaned source'

def add_static(rel_cml, target, src, deps):
    p = os.path.join(root, rel_cml)
    if not os.path.isfile(p):
        return
    s = open(p).read()
    if f'add_litertlm_library({target}' in s or f'add_library({target}' in s:
        return  # already defined (by us on a prior run, or upstream caught up)
    block = (
        f'\n{MARK} ({src})\n'
        f'add_litertlm_library({target} STATIC\n  {src}\n)\n'
        f'target_include_directories({target}\n'
        f'  PUBLIC\n    ${{GENERATED_SRC_DIR}}\n    ${{LITERTLM_INCLUDE_PATHS}}\n)\n'
        f'target_link_libraries({target}\n  PUBLIC\n{deps}\n)\n'
    )
    open(p, 'a').write(block)

# Data processors mirror the (working) gemma3 processor's dependency set.
PROC_DEPS = """    runtime_conversation_io_types
    runtime_engine_io_types
    LiteRTLM::Runtime::Conversation::Processor::Gemma3Config
    LiteRTLM::Runtime::Components::Tokenizer::Interface
    LiteRTLM::Runtime::Components::ConstrainedDecoding::Constraint
    LiteRTLM::Runtime::Components::ConstrainedDecoding::ConstraintProvider
    LiteRTLM::Runtime::Components::Preprocessor::Audio
    LiteRTLM::Runtime::Components::Preprocessor::AudioMiniAudio
    LiteRTLM::Runtime::Components::Preprocessor::Image
    LiteRTLM::Runtime::Components::Preprocessor::StbImage
    LiteRTLM::Runtime::Components::ToolUse::ParserUtils
    LiteRTLM::Runtime::Components::ToolUse::PythonFormatUtils
    runtime_util_litert_status_util
    runtime_util_memory_mapped_file
    LiteRTLM::Runtime::Conversation::Processor::DataUtils
    LiteRTLM::Runtime::Conversation::Processor::Interface
    LITERTLM_DEPS"""

add_static('runtime/engine/CMakeLists.txt',
           'runtime_engine_cpu_affinity_utils', 'cpu_affinity_utils.cc',
           '    runtime_util_litert_status_util\n    LITERTLM_DEPS')
add_static('runtime/conversation/CMakeLists.txt',
           'runtime_conversation_channel_util', 'channel_util.cc',
           '    runtime_conversation_io_types\n    runtime_engine_io_types\n    LITERTLM_DEPS')
add_static('runtime/components/preprocessor/CMakeLists.txt',
           'runtime_components_preprocessor_image_preprocessor_utils', 'image_preprocessor_utils.cc',
           '    runtime_components_preprocessor_image_preprocessor\n    LITERTLM_DEPS')
add_static('runtime/conversation/model_data_processor/CMakeLists.txt',
           'runtime_conversation_model_data_processor_gemma4_data_processor', 'gemma4_data_processor.cc',
           PROC_DEPS)
add_static('runtime/conversation/model_data_processor/CMakeLists.txt',
           'runtime_conversation_model_data_processor_fastvlm_data_processor', 'fastvlm_data_processor.cc',
           PROC_DEPS)
PY
fi

# The prebuilt Gemma constraint-provider .so is imported as a CMake target, but
# litert_lm_main links the *flattened list of archive paths* in the local
# aggregate, which does not follow that target's transitive interface — so the
# .so never reaches the link line and LiteRtLmGemmaModelConstraintProvider_*
# stay undefined. Add the .so explicitly to litert_lm_main's link (inside the
# --start-group/--end-group, so the static processors that call it resolve).
LM_PKG_CML="$SRC_DIR/cmake/packages/litert_lm/CMakeLists.txt"
if [ -f "$LM_PKG_CML" ] && ! grep -q 'gemma-server: link prebuilt provider' "$LM_PKG_CML"; then
    python3 - "$LM_PKG_CML" "$GEMMA_PREBUILT_REL" <<'PY' && info "Linked prebuilt provider .so into litert_lm_main."
import sys
p, rel = sys.argv[1], sys.argv[2]
s = open(p).read()
needle = '        ${_LITERTLM_SYSLIBS}'
ins = ('        # gemma-server: link prebuilt provider\n'
       f'        "${{LITERTLM_PROJECT_ROOT}}/{rel}"\n')
if needle in s:
    s = s.replace(needle, ins + needle, 1)
    open(p, 'w').write(s)
PY
fi

# --- Force engine registration TU inclusion via explicit symbol reference -----
# On Android without --whole-archive, the linker drops any object file that
# defines no externally-referenced symbol. engine_advanced_impl.cc contains ONLY
# a static-storage EngineRegisterer (LITERT_LM_REGISTER_ENGINE macro), so the
# linker silently discards the TU and EngineFactory's registry stays empty.
# Fix: add a no-op extern "C" function to engine_advanced_impl.cc, then
# reference it from litert_lm_main.cc to force the TU into the link.
ENGINE_IMPL_CC="$SRC_DIR/runtime/core/engine_advanced_impl.cc"
if [ -f "$ENGINE_IMPL_CC" ] && ! grep -q 'gemma-server.*force-engine-reg' "$ENGINE_IMPL_CC"; then
    python3 - "$ENGINE_IMPL_CC" <<'PY' && info "Added engine-reg anchor to engine_advanced_impl.cc."
import sys
p = sys.argv[1]
s = open(p).read()
stub = (
    '\n// [gemma-server force-engine-reg] Stub with external linkage so that\n'
    '// litert_lm_main.cc can reference this TU, preventing the Android linker\n'
    '// from discarding engine_advanced_impl.cc.o (and its static EngineRegisterer).\n'
    'extern "C" void LiteRtLmForceAdvancedEngineRegistration() {}\n'
)
closing = '}  // namespace litert::lm'
if closing in s and stub not in s:
    s = s.replace(closing, stub + closing, 1)
    open(p, 'w').write(s)
PY
fi

# --- Enable --whole-archive on Android for engine static initializers --------
# Belt-and-suspenders: also patch the CMakeLists.txt Android linker-flag block
# to use --whole-archive (matching the Linux branch). This forces all TUs from
# the ODML payload into the final link, including any other files with only
# static initializers. The explicit symbol reference above is the primary fix;
# --whole-archive is the secondary guarantee.
# NOTE: this CMakeLists.txt change requires a binary rebuild to take effect.
# The bypass-absl-flags patch version bump below (v1 → v2) ensures the binary
# is rebuilt unconditionally whenever the engine-reg or whole-archive fix is
# applied for the first time on this device.
if [ -f "$LM_PKG_CML" ] && ! grep -q 'gemma-server: android whole-archive' "$LM_PKG_CML"; then
    python3 - "$LM_PKG_CML" <<'PY' && info "Enabled --whole-archive for Android engine registration."
import sys
p = sys.argv[1]
s = open(p).read()
# Find the Android branch (no _LITERTLM_LINK_WHOLE_START/_END set) and add them.
old = (
    '    elseif(ANDROID)\n'
    '        # Android / Bionic (NO standalone rt or pthread)\n'
    '        set(_LITERTLM_LINK_MULTIDEF "-Wl,--allow-multiple-definition")\n'
    '        set(_LITERTLM_LINK_GROUP_START "-Wl,--start-group")\n'
    '        set(_LITERTLM_LINK_GROUP_END "-Wl,--end-group")\n'
    '        set(_LITERTLM_SYSLIBS "-lz -ldl -llog")'
)
new = (
    '    elseif(ANDROID)\n'
    '        # Android / Bionic (NO standalone rt or pthread)\n'
    '        set(_LITERTLM_LINK_MULTIDEF "-Wl,--allow-multiple-definition")\n'
    '        set(_LITERTLM_LINK_GROUP_START "-Wl,--start-group")\n'
    '        set(_LITERTLM_LINK_GROUP_END "-Wl,--end-group")\n'
    '        # gemma-server: android whole-archive (force static initializers to run)\n'
    '        set(_LITERTLM_LINK_WHOLE_START "-Wl,--whole-archive")\n'
    '        set(_LITERTLM_LINK_WHOLE_END "-Wl,--no-whole-archive")\n'
    '        set(_LITERTLM_SYSLIBS "-lz -ldl -llog")'
)
if old in s:
    open(p, 'w').write(s.replace(old, new, 1))
else:
    print(f'WARNING: Android branch not found verbatim in {p}; skipping patch')
PY
fi

# --- Bypass Abseil flag parsing in litert_lm_main.cc -------------------------
# litert_lm_main uses ABSL_FLAG + absl::ParseCommandLine. At runtime,
# libGemmaModelConstraintProvider.so (a direct link dependency) embeds its own
# statically-compiled Abseil. This creates two separate FlagRegistry instances:
# the binary's ABSL_FLAG registrations go to one; absl::ParseCommandLine reads
# from the other → every flag is "Unknown". The fix is to replace Abseil flag
# parsing with a simple manual argv parser for the 4 flags litert_lm_main needs.
# A marker file ($BYPASS_MARKER) tracks whether the current binary in the build
# dir was compiled with the patch, so subsequent re-runs only rebuild if needed.
MAIN_CC="$SRC_DIR/runtime/engine/litert_lm_main.cc"
BYPASS_MARKER="$GEMMA_HOME/.litert_lm_main_patched_v2"
# If only the old v1 marker exists (no engine-reg fix), delete it so the v2
# patch is treated as new → forces a rebuild with the engine reference added.
[ -f "$GEMMA_HOME/.litert_lm_main_patched_v1" ] && \
    ! [ -f "$BYPASS_MARKER" ] && \
    rm -f "$GEMMA_HOME/.litert_lm_main_patched_v1" && \
    info "Removed stale v1 bypass marker — v2 rebuild required."
NEED_REBUILD_MAIN=0
if [ -f "$MAIN_CC" ] && ! grep -q 'gemma-server.*bypass-absl-flags' "$MAIN_CC"; then
    python3 - "$MAIN_CC" <<'BYPASS_PY'
import sys
path = sys.argv[1]
with open(path) as f:
    src = f.read()
# 1. Remove absl/flags includes (keep absl/log/* for SetMinLogLevel etc.)
src = src.replace(
    '#include "absl/flags/flag.h"  // from @com_google_absl\n', '')
src = src.replace(
    '#include "absl/flags/parse.h"  // from @com_google_absl\n', '')
# 2. Replace the 4 ABSL_FLAG definitions with static globals + manual parser.
old_flags = (
    'ABSL_FLAG(std::string, backend, "gpu",\n'
    '          "Executor backend to use for LLM execution (cpu, gpu, etc.)");\n'
    'ABSL_FLAG(std::string, model_path, "", "Model path to use for LLM execution.");\n'
    'ABSL_FLAG(std::string, input_prompt, "",\n'
    '          "Input prompt to use for testing LLM execution.");\n'
    'ABSL_FLAG(std::string, input_prompt_file, "", "File path to the input prompt.");\n'
)
new_flags = (
    '// [gemma-server bypass-absl-flags] Manual argv parsing replaces ABSL_FLAG\n'
    '// to avoid Abseil FlagRegistry conflicts when libGemmaModelConstraintProvider.so\n'
    '// (which embeds its own statically-linked Abseil) is a direct runtime dep.\n'
    'static std::string gs_main_model_path;\n'
    'static std::string gs_main_backend = "cpu";\n'
    'static std::string gs_main_input_prompt;\n'
    'static std::string gs_main_input_prompt_file;\n'
    '\n'
    '// [gemma-server force-engine-reg] Reference the stub in engine_advanced_impl.cc\n'
    '// so the Android linker cannot drop that TU (and its EngineRegisterer initializer).\n'
    'extern "C" void LiteRtLmForceAdvancedEngineRegistration();\n'
    'static void (* const _litert_engine_reg_anchor)() __attribute__((used))\n'
    '    = LiteRtLmForceAdvancedEngineRegistration;\n'
    '\n'
    'static void ParseMainArgs(int argc, char** argv) {\n'
    '  for (int i = 1; i < argc; ++i) {\n'
    '    std::string a(argv[i]);\n'
    '    if (a.rfind("--model_path=", 0) == 0)\n'
    '      gs_main_model_path = a.substr(13);\n'
    '    else if (a.rfind("--backend=", 0) == 0)\n'
    '      gs_main_backend = a.substr(10);\n'
    '    else if (a.rfind("--input_prompt=", 0) == 0)\n'
    '      gs_main_input_prompt = a.substr(15);\n'
    '    else if (a.rfind("--input_prompt_file=", 0) == 0)\n'
    '      gs_main_input_prompt_file = a.substr(20);\n'
    '  }\n'
    '}\n'
)
if old_flags not in src:
    print("ERROR: ABSL_FLAG block not found in " + path, file=sys.stderr)
    sys.exit(1)
src = src.replace(old_flags, new_flags, 1)
# 3. Patch GetInputPrompt() to use globals.
src = src.replace(
    '  const std::string input_prompt = absl::GetFlag(FLAGS_input_prompt);\n'
    '  const std::string input_prompt_file = absl::GetFlag(FLAGS_input_prompt_file);\n',
    '  const std::string input_prompt = gs_main_input_prompt;\n'
    '  const std::string input_prompt_file = gs_main_input_prompt_file;\n')
# 4. Patch MainHelper() to use ParseMainArgs and globals.
src = src.replace(
    '  absl::ParseCommandLine(argc, argv);\n',
    '  ParseMainArgs(argc, argv);\n')
src = src.replace(
    '  const std::string model_path = absl::GetFlag(FLAGS_model_path);\n',
    '  const std::string model_path = gs_main_model_path;\n')
src = src.replace(
    '  auto backend_str = absl::GetFlag(FLAGS_backend);\n',
    '  auto backend_str = gs_main_backend;\n')
with open(path, 'w') as f:
    f.write(src)
print("Patched litert_lm_main.cc: Abseil flag parsing replaced with ParseMainArgs.")
BYPASS_PY
    if [ ! -f "$BYPASS_MARKER" ]; then
        NEED_REBUILD_MAIN=1
        # Binary in build dir (if any) was compiled without the patch — remove it
        # so find_built_binary returns empty and the build runs below.
        find "$BUILD_DIR" -name 'litert_lm_main' -type f -delete 2>/dev/null || true
        find "$BUILD_DIR" -name 'litert_lm_main.cc.o' -delete 2>/dev/null || true
        info "bypass-absl-flags patch applied for first time — binary rebuild required."
    else
        info "bypass-absl-flags patch re-applied after git reset (binary already correct)."
    fi
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
if [ -n "$EXISTING_BIN" ] && [ "$REBUILD" != "1" ] && [ "$NEED_REBUILD_MAIN" != "1" ]; then
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
touch "$BYPASS_MARKER"  # Record that this binary was built with bypass-absl-flags patch.

# Install the prebuilt provider .so beside the binary so it loads at runtime
# (the binary links it; without it on the loader path the server won't start).
mkdir -p "$LIB_DIR"
if [ -f "$SRC_DIR/$GEMMA_PREBUILT_REL" ]; then
    cp -f "$SRC_DIR/$GEMMA_PREBUILT_REL" "$LIB_DIR/" \
        && info "Runtime lib installed: $LIB_DIR/$GEMMA_PREBUILT_SO"
fi

# Sanity-check: the binary must accept --model_path without complaining about
# unknown flags (the bypass-absl-flags patch should make this always pass).
if command -v timeout >/dev/null 2>&1; then
    _st_out="$(LD_LIBRARY_PATH="$LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        timeout 15 "$SERVER_BIN" --model_path=/dev/null --backend=cpu 2>&1 || true)"
    if echo "$_st_out" | grep -q 'Unknown command line flag'; then
        error "Binary still rejects --model_path after bypass patch. Check build log at $GEMMA_HOME/build.log."
    fi
    info "Binary sanity check passed (flags accepted)."
else
    info "Binary sanity check skipped (timeout not available — install util-linux if needed)."
fi

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
# Where prebuilt shared libs the binary links (e.g. libGemmaModelConstraintProvider.so)
# were installed. Prepended to LD_LIBRARY_PATH so inference can dlopen them.
LIB_DIR = os.environ.get("GEMMA_LIB_DIR", os.path.join(GEMMA_HOME, "lib"))
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
            child_env = dict(os.environ)
            child_env["LD_LIBRARY_PATH"] = os.pathsep.join(
                p for p in (LIB_DIR, child_env.get("LD_LIBRARY_PATH", "")) if p
            )
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
                env=child_env,
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
export GEMMA_LIB_DIR="\${GEMMA_LIB_DIR:-$LIB_DIR}"
export LD_LIBRARY_PATH="$LIB_DIR\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
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
