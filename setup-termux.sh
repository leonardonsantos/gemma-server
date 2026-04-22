#!/data/data/com.termux/files/usr/bin/bash
# Termux bootstrap for gemma-server.kts
# Run once to set up the environment.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── 1. System packages ─────────────────────────────────────────────────────────

info "Updating package index..."
pkg update -y

info "Installing Java 21, curl, unzip, zip..."
pkg install -y openjdk-21 curl unzip zip

info "Java version: $(java -version 2>&1 | head -1)"

# ── 2. kscript via sdkman ──────────────────────────────────────────────────────

if command -v kscript &>/dev/null; then
    info "kscript already installed: $(kscript --version)"
else
    info "Installing sdkman..."
    # sdkman needs bash and curl, both available in Termux
    export SDKMAN_DIR="$HOME/.sdkman"
    curl -s "https://get.sdkman.io" | bash || error "sdkman installation failed."

    # shellcheck source=/dev/null
    source "$SDKMAN_DIR/bin/sdkman-init.sh"

    info "Installing kscript via sdkman..."
    sdk install kscript || error "kscript installation failed."

    # Make kscript available in current session and future ones
    if ! grep -q "sdkman-init.sh" "$HOME/.bashrc" 2>/dev/null; then
        echo 'source "$HOME/.sdkman/bin/sdkman-init.sh"' >> "$HOME/.bashrc"
    fi
    info "kscript installed: $(kscript --version)"
fi

# ── 3. Model directory ─────────────────────────────────────────────────────────

MODEL_DIR="$HOME/models"
MODEL_FILE="$MODEL_DIR/gemma-4-E2B-it.litertlm"

mkdir -p "$MODEL_DIR"
info "Model directory: $MODEL_DIR"

if [[ -f "$MODEL_FILE" ]]; then
    info "Model file already present: $MODEL_FILE"
else
    warn "Model file not found at $MODEL_FILE"
    echo ""
    echo "  Download the Gemma4-E2B-IT model (~2.58 GB) from HuggingFace:"
    echo ""
    echo "    https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm"
    echo ""
    echo "  Using the HuggingFace CLI (recommended):"
    echo "    pip install huggingface_hub"
    echo "    huggingface-cli download litert-community/gemma-4-E2B-it-litert-lm \\"
    echo "        --include '*.litertlm' --local-dir ~/models"
    echo ""
    echo "  Or copy from your computer via adb:"
    echo "    adb push gemma-4-E2B-it.litertlm /sdcard/models/"
    echo "    cp /sdcard/models/gemma-4-E2B-it.litertlm ~/models/"
    echo ""
fi

# ── 4. Make the script executable ─────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/gemma-server.kts" ]]; then
    chmod +x "$SCRIPT_DIR/gemma-server.kts"
    info "gemma-server.kts is now executable."
fi

# ── 5. Cache directory ─────────────────────────────────────────────────────────

mkdir -p "$HOME/.cache/litert-lm"
info "LiteRT cache directory: $HOME/.cache/litert-lm"

# ── Done ───────────────────────────────────────────────────────────────────────

echo ""
info "Setup complete!"
echo ""
echo "  Start the server:"
echo "    ./gemma-server.kts"
echo ""
echo "  Or with a custom model path:"
echo "    ./gemma-server.kts /path/to/model.litertlm"
echo ""
echo "  Or via environment variable:"
echo "    export LITERT_MODEL_PATH=~/models/gemma-4-E2B-it.litertlm"
echo "    ./gemma-server.kts"
echo ""
echo "  Test the server (from another Termux session):"
echo "    curl http://localhost:8080/health"
echo ""
echo "  NOTE: On Termux without proot-distro, litertlm-jvm native libs (glibc)"
echo "  may not load. See README.md for proot-distro (Ubuntu) workaround."
