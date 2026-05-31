# gemma-server — native Gemma on Termux via LiteRT-LM (CMake)

Run Google's **Gemma** model natively on Android/Termux and expose an
**OpenAI-compatible HTTP API** on port **8080**.

Unlike the previous JVM/`kscript` approach, this version compiles the
**native `litert_lm_main` binary on-device** using the official
[LiteRT-LM **CMake Super-Build**](https://github.com/google-ai-edge/LiteRT-LM/blob/main/docs/getting-started/cmake.md).
This avoids the glibc/Bionic incompatibility that forced CPU-only JVM fallbacks.

> Background: the CMake build is the recommended path for Termux power users —
> see [google-ai-edge/LiteRT-LM#2413](https://github.com/google-ai-edge/LiteRT-LM/issues/2413).
> It is non-hermetic, probes the system, and links against Termux-native tools
> (Clang 21, zlib, …) to produce a real `aarch64-linux-android` binary.

---

## Quick start

One command. It installs the toolchain, compiles LiteRT-LM, downloads the model,
and writes the HTTP server + launcher:

```bash
curl -fsSL https://raw.githubusercontent.com/leonardonsantos/gemma-server/main/install.sh | bash
```

Then start the server:

```bash
gemma-server
```

Test it from a second Termux session:

```bash
curl http://localhost:8080/health
```

> ⏳ **The build takes several hours on-device** and needs **~5.5 GB RAM + swap**
> and **~8 GB free storage**. The installer is fully **idempotent and resumable** —
> if anything fails (network, OOM), just run it again and it skips completed steps.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Android device | ARM64 (`aarch64`), **Android 11+ (API 30)**, ≥ 8 GB RAM recommended |
| [Termux](https://github.com/termux/termux-app) | Install from **F-Droid** (not Play Store) |
| Storage | ~8 GB free (model ≈ 2.6 GB + build tree) |
| RAM + swap | ≥ 5.5 GB combined for the compile ([add swap](#adding-swap) if needed) |
| Time | The native compile can take several hours |

The installer `pkg install`s the rest automatically:
`clang cmake make ninja git rust python openjdk-17 zlib openssl libcurl`.

---

## What the installer does

`install.sh` runs these steps (each is skipped if already done):

1. **Preflight** — checks architecture, free disk, RAM/swap, and picks a safe
   `-j` value (`(RAM+swap)/8`, capped at CPU count) to avoid OOM-kills.
2. **Toolchain** — `pkg install` of the build dependencies above.
3. **Source** — clones `google-ai-edge/LiteRT-LM` into `~/.gemma-server/LiteRT-LM`.
4. **Build** — the CMake Super-Build (an orchestrator that wraps the real build
   in an `ExternalProject`):
   ```bash
   cmake -B cmake/build -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release
   cmake --build cmake/build -j<N>          # builds the litert_lm ExternalProject
   ```
   The resulting `litert_lm_main` is found under `cmake/build/` and copied to
   `~/.gemma-server/litert_lm_main`.
5. **Model** — downloads `gemma-4-E2B-it.litertlm` (~2.6 GB, **resumable**) from
   HuggingFace to `~/models/`.
6. **Server** — writes `~/.gemma-server/gemma_server.py` (the HTTP API) and a
   `~/.local/bin/gemma-server` launcher.

### Configuration (environment variables)

Pass these before the install command, e.g. `REBUILD=1 bash install.sh`:

| Variable | Default | Description |
|---|---|---|
| `LITERTLM_REF` | `main` | LiteRT-LM git ref to build |
| `BUILD_JOBS` | `auto` | Override parallel build jobs |
| `GEMMA_ANDROID_API` | `30` | Android API level the native build targets (≥ 30 required) |
| `REBUILD` | `0` | `1` forces a clean rebuild of the binary |
| `SKIP_MODEL` | `0` | `1` skips the model download |
| `GEMMA_MODEL_URL` | HuggingFace URL | Source URL for the model |
| `GEMMA_MODEL_FILE` | `~/models/gemma-4-E2B-it.litertlm` | Where to store the model |
| `GEMMA_HOME` | `~/.gemma-server` | Install location for binary + server |

---

## Running the server

```bash
gemma-server
# or directly:
python3 ~/.gemma-server/gemma_server.py
```

### Server configuration (environment variables)

| Variable | Default | Description |
|---|---|---|
| `GEMMA_HOST` | `127.0.0.1` | Bind address. Set `0.0.0.0` to expose on the LAN |
| `GEMMA_PORT` | `8080` | Listen port |
| `GEMMA_BACKEND` | `cpu` | `cpu` or `gpu` (GPU may fall back to CPU) |
| `GEMMA_MODEL_FILE` | `~/models/gemma-4-E2B-it.litertlm` | Model path |
| `GEMMA_MODEL_ID` | `gemma-4-E2B` | Model id reported by the API |
| `GEMMA_TIMEOUT` | `600` | Per-request inference timeout (seconds) |

> 🔒 The server binds to **localhost by default**. Only set `GEMMA_HOST=0.0.0.0`
> on a trusted network — the API is unauthenticated.

---

## ⚠️ Important: how this "server" works

`litert_lm_main` is a **one-shot CLI** — it has no built-in server or session
mode. The HTTP layer is therefore a **compatibility wrapper**: for each request
it invokes the binary, which **reloads the whole model every time**.

Consequences:

- **Latency:** every request pays the full model-load + prefill cost (seconds to
  minutes depending on device). There is no warm residency.
- **Serialized:** only one inference runs at a time. Concurrent requests get
  `429 Busy` instead of triggering a second multi-GB load (which would OOM).
- `/health` reports `"mode": "one-shot-wrapper"`, `"persistent_model": false`.

This is the honest trade-off of building on the upstream CLI. A true persistent
native server would require linking against the LiteRT-LM C++ Engine API
directly — a possible future enhancement.

---

## API reference

### `GET /health`

```bash
curl http://localhost:8080/health
```
```json
{
  "status": "ok",
  "mode": "one-shot-wrapper",
  "persistent_model": false,
  "model": "gemma-4-E2B",
  "backend": "cpu",
  "model_path": "/data/data/com.termux/files/home/models/gemma-4-E2B-it.litertlm",
  "binary": "/data/data/com.termux/files/home/.gemma-server/litert_lm_main"
}
```

### `GET /v1/models`

```bash
curl http://localhost:8080/v1/models
```
```json
{ "object": "list", "data": [{ "id": "gemma-4-E2B", "object": "model", "owned_by": "google" }] }
```

### `POST /v1/chat/completions`

OpenAI-compatible. The wrapper flattens `messages` into a single prompt and lets
LiteRT-LM apply the Gemma chat template.

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-4-E2B",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "What is the capital of France?"}
    ]
  }'
```
```json
{
  "id": "chatcmpl-...",
  "object": "chat.completion",
  "model": "gemma-4-E2B",
  "choices": [{
    "index": 0,
    "message": { "role": "assistant", "content": "The capital of France is Paris." },
    "finish_reason": "stop"
  }],
  "usage": { "prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0 }
}
```

#### Streaming (`"stream": true`)

Supported for client compatibility, but **non-incremental** — because the binary
produces the full answer at once, the complete text arrives in a single SSE
chunk followed by `data: [DONE]`.

| Status | Meaning |
|---|---|
| `400` | Bad JSON / empty `messages` / prompt too long |
| `429` | Busy — another inference is already running |
| `503` | Engine error (binary/model missing, non-zero exit, timeout) |

---

## Using with OpenAI clients

```python
from openai import OpenAI
client = OpenAI(base_url="http://localhost:8080/v1", api_key="none")
print(client.chat.completions.create(
    model="gemma-4-E2B",
    messages=[{"role": "user", "content": "Hello!"}],
).choices[0].message.content)
```

For **Continue** / **Open WebUI** point the client's `apiBase` at
`http://<android-ip>:8080/v1` (set `GEMMA_HOST=0.0.0.0` first).

---

## GPU acceleration

The CMake build links against Termux-native libraries, so unlike the old
glibc JVM build the GPU path can work if your device exposes an OpenCL driver
(typically `/vendor/lib64/libOpenCL.so`). Try:

```bash
GEMMA_BACKEND=gpu gemma-server
```

If the GPU backend is unavailable, `litert_lm_main` falls back to CPU.

---

## Manual build (without the installer)

```bash
pkg install clang cmake make ninja git rust python openjdk-17 zlib openssl libcurl
git clone https://github.com/google-ai-edge/LiteRT-LM
cd LiteRT-LM
cmake -B cmake/build -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release
# Pin the Rust/cc-rs target to API 30 so cxx compiles (pthread_cond_clockwait):
export CFLAGS_aarch64_linux_android="--target=aarch64-linux-android30"
export CXXFLAGS_aarch64_linux_android="--target=aarch64-linux-android30"
cmake --build cmake/build -j2            # default target; keep -j low to avoid OOM
# The binary is produced inside the ExternalProject sub-build:
BIN=$(find cmake/build -type f -name litert_lm_main | head -n1)
"$BIN" \
  --model_path=~/models/gemma-4-E2B-it.litertlm \
  --backend=cpu \
  --input_prompt="What is the tallest building in the world?"
```

---

## Adding swap

The compile is memory-hungry. If you have < 5.5 GB RAM, add swap first:

```bash
mkdir -p ~/swap
dd if=/dev/zero of=~/swap/file bs=1M count=6144
mkswap ~/swap/file
sudo swapon ~/swap/file
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Build killed (`Signal 9` / SEGFAULT) | Out of memory — add swap and/or lower `BUILD_JOBS=1`, then re-run |
| `use of undeclared identifier 'pthread_cond_clockwait'` | A Rust crate (`cxx`) needs Android API 30 symbols. The installer pins the target to API 30; ensure your device is **Android 11+**, or set `GEMMA_ANDROID_API` to your device's level (≥ 30) |
| Build fails just after `protobuf_external` | The installer points the native build's host `protoc`/`flatc` at the in-tree binaries (the upstream orchestrator otherwise targets a skipped prebuild dir). If you build manually, pass `-DLITERTLM_HOST_PROTOC=…/litert_lm/build/external/protobuf/install/bin/protoc` (and the matching `FLATC`) |
| `ANDROID_LOG_LIB ... set to NOTFOUND` (TFLite `benchmark_model`) | Android's `liblog` lives in the read-only `/system/lib{,64}` and isn't linkable from `$PREFIX/lib`. The installer symlinks it into `$PREFIX/lib/liblog.so`; if building manually, run `ln -sf /system/lib64/liblog.so $PREFIX/lib/liblog.so` first |
| `ANDROID_EGL_LIB` / `ANDROID_GLESV2_LIB` / `ANDROID_GLESV3_LIB ... set to NOTFOUND` (LiteRT runtime) | Same root cause for the GPU libs. The installer also symlinks `libEGL`/`libGLESv2`/`libGLESv3` from `/system/lib{,64}` into `$PREFIX/lib`; if building manually, `ln -sf /system/lib64/lib{EGL,GLESv2,GLESv3}.so $PREFIX/lib/` |
| `fatal error: 'EGL/egl.h' file not found` (TFLite GPU GL delegate) | Termux ships no EGL/GLES headers but the GL delegate is compiled unconditionally. The installer adds the `libglvnd-dev` package (headers only); if building manually, run `pkg install -y libglvnd-dev` |
| `fatal error: 'vulkan/vulkan.h' file not found` (TFLite GPU delegate) | Same delegate also needs Vulkan headers. The installer adds `vulkan-headers` (headers only); if building manually, run `pkg install -y vulkan-headers` |
| `ld.lld: error: unable to find library -llitert_cc_options` | Upstream defines `litert_cc_options` as a header-only INTERFACE library, but the LiteRT shared libs list it as a plain link item (it produces no `.a`). The installer drops empty stub archives (`liblitert_cc_options.a`, `liblitert_runtime_c_api_static.a`) into `$PREFIX/lib`; the real option symbols live in `litert_cc_api`, which is linked normally |
| `ld.lld: error: undefined symbol: kai_*` (e.g. `kai_run_rhs_pack_*`) | On aarch64 XNNPACK is built with KleidiAI but LiteRT-LM only links `libkleidiai.a` for cross-compiles. The installer patches `cmake/packages/tflite/tflite_target_map.cmake` to also link it on native aarch64. If symbols persist after a resume, force a clean rebuild with `REBUILD=1` |
| `fatal error: 'schema/core/litertlm_header_schema_generated.h' file not found` (~66%) | A parallel-build race: the FlatBuffer schema header is generated by `flatc`, but the `generator_complete` gate every LiteRT-LM library waits on doesn't depend on the flatc step, so the schema `.cc` files compile too early. The installer patches `cmake/packages/litert_lm/CMakeLists.txt` (adds the dependency) and the flatbuffers fallback target (regenerates headers on resume). If it persists, retry with `BUILD_JOBS=1` or `REBUILD=1` |
| `no member named 'SetKernelBatchSize'` / `'SetDisableDelegateClustering'` (~88%) | LiteRT-LM `main` has drifted ahead of the LiteRT commit it pins and calls two option setters that don't exist there yet. Both are optional tuning hints, so the installer drops the calls from `runtime/executor/llm_executor_settings_utils.cc`; default CPU/GPU inference is unaffected |
| Build fails with a buried error | The full build output is saved to `~/.gemma-server/build.log`; the installer prints the key `error:` lines. For a single clear error, re-run with `BUILD_JOBS=1` |
| Build fails midway | Re-run the installer; completed steps are skipped |
| `Model not found` | Re-run to resume the download, or set `GEMMA_MODEL_FILE` |
| `429 Busy` | Expected — one inference at a time; retry shortly |
| Very slow responses | Expected — the model reloads every request (see note above) |
| `gemma-server: command not found` | `source ~/.bashrc` or open a new Termux session |
| GPU not used | `GEMMA_BACKEND=gpu`; falls back to CPU if no OpenCL driver |

---

## License

This project wraps [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM)
(Apache 2.0). The Gemma model is subject to Google's
[Gemma terms of use](https://ai.google.dev/gemma/terms).
