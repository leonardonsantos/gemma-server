# gemma-server — Gemma4-E2B OpenAI-compatible API for Termux

Runs Google's **Gemma4-E2B** model on Android via Termux using LiteRT-LM, exposing an
OpenAI-compatible HTTP API on port **8080**.  GPU acceleration is attempted automatically,
with CPU fallback.

## Prerequisites

| Requirement | Notes |
|---|---|
| Android device | ARM64, ≥ 6 GB RAM recommended |
| [Termux](https://github.com/termux/termux-app) | Install from F-Droid (not Play Store) |
| Java 21 | `pkg install openjdk-21` |
| [kscript](https://github.com/kscripting/kscript) | Installed by `setup-termux.sh` |
| Model file | `gemma-4-E2B-it.litertlm` (~2.58 GB) |

---

## Quick Start

### 1. Bootstrap Termux environment

```bash
bash setup-termux.sh
```

This installs Java 21, kscript (via sdkman), creates `~/models/`, and makes the script executable.

### 2. Download the model

Download from [HuggingFace](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm):

```bash
# Install the HuggingFace CLI
pip install huggingface_hub

# Download the model (~2.58 GB)
huggingface-cli download litert-community/gemma-4-E2B-it-litert-lm \
    --include '*.litertlm' --local-dir ~/models
```

Or copy from your computer:

```bash
# On your computer
adb push gemma-4-E2B-it.litertlm /sdcard/models/

# In Termux
cp /sdcard/models/gemma-4-E2B-it.litertlm ~/models/
```

### 3. Start the server

```bash
./gemma-server.kts
# or
./gemma-server.kts ~/models/gemma-4-E2B-it.litertlm
```

**First run** will take a few minutes while kscript downloads dependencies (~200 MB).
Subsequent runs start in seconds thanks to kscript's cache.

### 4. Test

Open a second Termux session:

```bash
curl http://localhost:8080/health
```

---

## API Reference

### `GET /health`

Returns server status.

```bash
curl http://localhost:8080/health
```

```json
{
  "status": "ok",
  "model": "gemma-4-E2B",
  "backend": "GPU",
  "model_path": "/data/data/com.termux/files/home/models/gemma-4-E2B-it.litertlm"
}
```

---

### `GET /v1/models`

Lists available models (OpenAI-compatible).

```bash
curl http://localhost:8080/v1/models
```

```json
{
  "object": "list",
  "data": [{ "id": "gemma-4-E2B", "object": "model", "owned_by": "google" }]
}
```

---

### `POST /v1/chat/completions`

Chat completions — OpenAI-compatible.

#### Non-streaming

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

#### Streaming (SSE)

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-4-E2B",
    "messages": [{"role": "user", "content": "Tell me a short story."}],
    "stream": true
  }'
```

Each streamed chunk:
```
data: {"id":"chatcmpl-...","object":"chat.completion.chunk","model":"gemma-4-E2B","choices":[{"index":0,"delta":{"content":"Once"},"finish_reason":null}]}

data: [DONE]
```

#### Optional parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `temperature` | float | 1.0 | Sampling temperature (0–2) |
| `top_p` | float | 0.95 | Nucleus sampling |
| `top_k` | int | 40 | Top-K sampling |
| `max_tokens` | int | — | Max output tokens (informational) |
| `stream` | bool | false | Enable SSE streaming |

---

## Configuration

| Environment variable | Default | Description |
|---|---|---|
| `LITERT_MODEL_PATH` | `~/models/gemma-4-E2B-it.litertlm` | Path to `.litertlm` model file |
| `LITERT_CACHE_DIR` | `~/.cache/litert-lm` | Directory for LiteRT compiled artifacts |

---

## Using with OpenAI-compatible clients

### Open WebUI / Ollama proxy

Point the client at `http://<android-ip>:8080/v1`.

### Continue (VS Code/JetBrains)

```json
{
  "models": [{
    "title": "Gemma4-E2B (local)",
    "provider": "openai",
    "model": "gemma-4-E2B",
    "apiBase": "http://localhost:8080/v1",
    "apiKey": "none"
  }]
}
```

### Python `openai` library

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8080/v1", api_key="none")
response = client.chat.completions.create(
    model="gemma-4-E2B",
    messages=[{"role": "user", "content": "Hello!"}],
)
print(response.choices[0].message.content)
```

---

## GPU Acceleration Notes

### On Termux (direct, without proot-distro)

> ⚠️ **Compatibility caveat:** `litertlm-jvm` ships native libraries compiled for
> **Linux + glibc** (ARM64). Termux runs on Android's **Bionic** libc, which is not
> fully glibc-compatible. The native library may fail to load, and the engine will
> **fall back to CPU automatically**.

The server will print one of:
```
[INFO] GPU backend initialised successfully.
[WARN] GPU backend unavailable (...) — falling back to CPU.
```

### Recommended: proot-distro (full Linux/glibc environment)

For reliable GPU acceleration, run inside a Linux distribution via `proot-distro`:

```bash
# Install proot-distro
pkg install proot-distro

# Install Ubuntu
proot-distro install ubuntu

# Log into Ubuntu
proot-distro login ubuntu

# Inside Ubuntu: install Java and kscript, then run the server
apt update && apt install -y openjdk-21-jdk curl unzip
# ... follow setup-termux.sh steps for kscript installation
./gemma-server.kts
```

Inside proot-distro, the glibc environment is native and GPU via OpenCL should work
if your device's OpenCL driver is accessible (typically at `/vendor/lib64/libOpenCL.so`).

---

## Running as `.main.kts` (without kscript)

If you prefer using the plain `kotlin` command:

1. Copy `gemma-server.kts` to `gemma-server.main.kts`
2. Replace the `@file:MavenRepository(...)` lines with:
   ```kotlin
   @file:Repository("https://dl.google.com/android/maven2")
   ```
3. Run with:
   ```bash
   kotlin gemma-server.main.kts
   ```

The `kotlin` command ships with `kotlinc` (`pkg install kotlin` in Termux).

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Model file not found` | Check `LITERT_MODEL_PATH` or pass path as argument |
| `Failed to initialise engine on CPU` | Try inside proot-distro (Ubuntu) |
| `Address already in use` | `pkill -f kscript` or change `PORT` in the script |
| Port not reachable from other devices | Allow traffic: `termux-wake-lock` is not required; check Android Wi-Fi AP |
| Very slow first inference | Normal on CPU — GPU decode is 52 tok/s vs CPU 47 tok/s on S26 Ultra |
| kscript hangs on first run | Downloading ~200 MB of Maven dependencies — wait or check network |
