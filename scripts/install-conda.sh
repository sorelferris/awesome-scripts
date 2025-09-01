#!/usr/bin/env bash
set -e  # Exit immediately if a command exits with a non-zero status

# ========================
# Configurations
# ========================
CONDA_DIR="$HOME/miniconda3"
CONDA_INSTALLER="Miniconda3-latest-Linux-x86_64.sh"
CONDA_URL="https://repo.anaconda.com/miniconda/$CONDA_INSTALLER"

# ========================
# Functions
# ========================

download_miniconda() {
    echo "[INFO] Downloading Miniconda installer..."
    if command -v wget >/dev/null 2>&1; then
        wget -O "$CONDA_INSTALLER" "$CONDA_URL"
    elif command -v curl >/dev/null 2>&1; then
        curl -L "$CONDA_URL" -o "$CONDA_INSTALLER"
    else
        echo "[ERROR] Neither wget nor curl found. Please install one of them." >&2
        exit 1
    fi
}

install_miniconda() {
    echo "[INFO] Installing Miniconda into $CONDA_DIR ..."
    bash "$CONDA_INSTALLER" -b -p "$CONDA_DIR"
}

init_conda() {
    echo "[INFO] Initializing conda..."

    # Detect current shell
    CURRENT_SHELL=$(basename "$SHELL")

    # Always init bash (safe)
    "$CONDA_DIR/bin/conda" init bash

    case "$CURRENT_SHELL" in
        zsh)
            "$CONDA_DIR/bin/conda" init zsh
            ;;
        fish)
            "$CONDA_DIR/bin/conda" init fish
            ;;
        *)
            echo "[WARN] Unknown shell: $CURRENT_SHELL. Only bash was initialized."
            ;;
    esac
}

cleanup() {
    echo "[INFO] Cleaning up installer..."
    rm -f "$CONDA_INSTALLER"
}

# ========================
# Main script
# ========================

if [ -d "$CONDA_DIR" ]; then
    echo "[WARN] $CONDA_DIR already exists. Skipping installation."
else
    download_miniconda
    install_miniconda
    cleanup
fi

init_conda

echo "[INFO] Miniconda installation complete."
echo "[INFO] Please restart your shell (e.g., 'exec $SHELL') to activate conda."
