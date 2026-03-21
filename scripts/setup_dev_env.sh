#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Function to print colored status messages
print_status() {
    local color=$1
    local message=$2
    case $color in
        "green") echo -e "\033[0;32m[✓] $message\033[0m" ;;
        "yellow") echo -e "\033[1;33m[!] $message\033[0m" ;;
        "red") echo -e "\033[0;31m[✗] $message\033[0m" ;;
        "blue") echo -e "\033[0;34m[ℹ] $message\033[0m" ;;
    esac
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to get tool version (silent fail)
get_version() {
    local tool=$1
    local version_cmd=$2
    if command_exists "$tool"; then
        local version=$($version_cmd 2>/dev/null | head -n 1 | awk '{print $NF}' | sed 's/[^0-9\.]//g')
        echo "$version"
    else
        echo "Not installed"
    fi
}

# Check if the script is run as root (not recommended)
if [ "$(id -u)" -eq 0 ]; then
    print_status "yellow" "Running as root is not recommended. Some installations may fail."
    sleep 3
fi

# Install dependencies first
print_status "blue" "Installing required system dependencies..."
sudo apt update && sudo apt install -y wget curl git build-essential || {
    print_status "red" "Failed to install system dependencies"
    exit 1
}

# 1. Install oh-my-zsh (Check if zsh and oh-my-zsh are installed)
print_status "blue" "Checking for oh-my-zsh installation..."
if command_exists zsh && [ -d "$HOME/.oh-my-zsh" ]; then
    print_status "yellow" "oh-my-zsh is already installed, skipping..."
else
    wget -q https://raw.githubusercontent.com/sorelferris/awesome-scripts/refs/heads/main/scripts/install-omz.sh -O install-omz.sh || {
        print_status "red" "Failed to download oh-my-zsh install script"
        exit 1
    }
    chmod +x install-omz.sh
    sh install-omz.sh || print_status "yellow" "oh-my-zsh installation may have completed with warnings"
    rm -f install-omz.sh
    print_status "green" "oh-my-zsh installation completed"
fi

# 2. Install fnm (Fast Node Manager) (Check if fnm exists)
print_status "blue" "Checking for fnm installation..."
if command_exists fnm; then
    print_status "yellow" "fnm is already installed, skipping..."
else
    curl -fsSL https://fnm.vercel.app/install | bash || {
        print_status "red" "Failed to install fnm"
        exit 1
    }
    print_status "green" "fnm installation completed"
fi

# 3. Install Miniforge3 (Check if conda exists)
print_status "blue" "Checking for Miniforge3 installation..."
if command_exists conda && [[ "$(conda info --base)" == *"miniforge3"* ]]; then
    print_status "yellow" "Miniforge3 is already installed, skipping..."
else
    MINIFORGE_FILE="Miniforge3-$(uname)-$(uname -m).sh"
    wget -q "https://github.com/conda-forge/miniforge/releases/latest/download/$MINIFORGE_FILE" || {
        print_status "red" "Failed to download Miniforge3"
        exit 1
    }
    bash "$MINIFORGE_FILE" -b || {  # -b for batch mode (no interactive prompts)
        print_status "red" "Failed to install Miniforge3"
        exit 1
    }
    rm -f "$MINIFORGE_FILE"
    print_status "green" "Miniforge3 installation completed"
fi

# 4. Install uv package manager (Check if uv exists)
print_status "blue" "Checking for uv installation..."
if command_exists uv; then
    print_status "yellow" "uv is already installed, skipping..."
else
    curl -LsSf https://astral.sh/uv/install.sh | sh || {
        print_status "red" "Failed to install uv"
        exit 1
    }
    print_status "green" "uv installation completed"
fi

# 5. Install Rust (Check if rustc and cargo exist)
print_status "blue" "Checking for Rust installation..."
if command_exists rustc && command_exists cargo; then
    print_status "yellow" "Rust is already installed, skipping installation (updating instead)..."
    source $HOME/.cargo/env 2>/dev/null || true
    rustup update || print_status "yellow" "Rust update may have completed with warnings"
else
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y || {  # -y to auto-confirm
        print_status "red" "Failed to install Rust"
        exit 1
    }
    # Source rust environment to update current shell
    source $HOME/.cargo/env
    rustup update || print_status "yellow" "Rust update may have completed with warnings"
    print_status "green" "Rust installation completed"
fi

# 6. Install advcpmv (cp/mv with progress bar) (Check if cpg/mvg exist and aliases are set)
print_status "blue" "Checking for advcpmv installation..."
if command_exists cpg && command_exists mvg && grep -q "alias cp='/usr/local/bin/cpg -g'" ~/.zshrc 2>/dev/null; then
    print_status "yellow" "advcpmv is already installed and configured, skipping..."
else
    mkdir -p advcpmv
    curl -s https://raw.githubusercontent.com/jarun/advcpmv/master/install.sh -o ./advcpmv/install.sh || {
        print_status "red" "Failed to download advcpmv install script"
        exit 1
    }

    # Fix configure error by setting FORCE_UNSAFE_CONFIGURE
    cd advcpmv
    export FORCE_UNSAFE_CONFIGURE=1
    sh install.sh || {
        print_status "red" "Failed to compile advcpmv"
        cd .. && rm -rf advcpmv
        exit 1
    }
    cd ..

    # Move binaries to system path
    sudo mv ./advcpmv/advcp /usr/local/bin/cpg || {
        print_status "red" "Failed to move advcp binary"
        exit 1
    }
    sudo mv ./advcpmv/advmv /usr/local/bin/mvg || {
        print_status "red" "Failed to move advmv binary"
        exit 1
    }

    # Add aliases to zshrc (only if not already present)
    print_status "blue" "Configuring aliases for advcpmv..."
    if ! grep -q "alias cp='/usr/local/bin/cpg -g'" ~/.zshrc 2>/dev/null; then
        echo 'alias cp='/usr/local/bin/cpg -g'' >> ~/.zshrc
    fi
    if ! grep -q "alias mv='/usr/local/bin/mvg -g'" ~/.zshrc 2>/dev/null; then
        echo 'alias mv='/usr/local/bin/mvg -g'' >> ~/.zshrc
    fi

    # Cleanup
    rm -rf advcpmv
    print_status "green" "advcpmv installation and configuration completed"
fi

# Final setup
print_status "blue" "Applying zsh configuration..."
source ~/.zshrc || print_status "yellow" "Could not source .zshrc (please restart your shell)"

# ==========================
# Print version information
# ==========================
print_status "green" "============================================="
print_status "blue" "              Tool Version Summary            "
print_status "green" "============================================="

# Source environment to ensure all tools are in PATH
source $HOME/.zshrc 2>/dev/null || true
source $HOME/.cargo/env 2>/dev/null || true
source $HOME/miniforge3/etc/profile.d/conda.sh 2>/dev/null || true

# Get and print versions
ZSH_VERSION=$(get_version "zsh" "zsh --version")
OMZ_VERSION="[Installed]" # No direct version command for oh-my-zsh
FNM_VERSION=$(get_version "fnm" "fnm --version")
CONDA_VERSION=$(get_version "conda" "conda --version")
UV_VERSION=$(get_version "uv" "uv --version")
RUSTC_VERSION=$(get_version "rustc" "rustc --version")
CARGO_VERSION=$(get_version "cargo" "cargo --version")
ADVCPMV_VERSION="[Installed]" # No version command for advcpmv

# Print formatted version table
echo -e "\033[1mTool           Version\033[0m"
echo -e "-------------------------"
echo -e "zsh            $ZSH_VERSION"
echo -e "oh-my-zsh      $OMZ_VERSION"
echo -e "fnm            $FNM_VERSION"
echo -e "conda (miniforge3) $CONDA_VERSION"
echo -e "uv             $UV_VERSION"
echo -e "rustc          $RUSTC_VERSION"
echo -e "cargo          $CARGO_VERSION"
echo -e "advcpmv        $ADVCPMV_VERSION"

# Final completion message
print_status "green" "============================================="
print_status "green" "Development environment setup completed!"
print_status "blue" "Please restart your terminal or run: source ~/.zshrc"
print_status "blue" "To apply all changes"
print_status "green" "============================================="
