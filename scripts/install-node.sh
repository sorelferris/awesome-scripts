#!/usr/bin/env bash
set -e  # Exit immediately if a command exits with a non-zero status.

# Function: print message
log() {
    echo -e "\033[1;32m[INFO]\033[0m $1"
}

# Check if nvm is already installed
if [ -d "$HOME/.nvm" ]; then
    log "nvm already installed."
else
    log "Installing nvm..."
    # Install nvm from official repo
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
fi

# Load nvm into current shell
export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1090
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

log "Using nvm version: $(nvm --version)"

# Install Node.js 22.18.0
log "Installing Node.js v22.18.0..."
nvm install 22.18.0

# Set default Node version
nvm alias default 22.18.0
nvm use default

log "Node.js version: $(node -v)"
log "npm version: $(npm -v)"
log "Setup complete."
