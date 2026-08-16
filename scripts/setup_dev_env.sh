#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# setup_dev_env.sh — one-shot development environment setup
#
# Default installs (the four essentials):
#   1. oh-my-zsh (via the repo's install-omz.sh)
#   2. nvm + Node.js (default: latest 24.x)
#   3. Miniforge3 (conda)
#   4. uv
#
# Optional (off by default, enable with flags or --all):
#   pixi, Rust (rustup), advcpmv
#
# Idempotent: already-installed tools are detected and skipped.
# =============================================================================

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
NODE_VERSION="24"                     # Node.js major version to install
NVM_VERSION="v0.40.4"                 # nvm release tag
OMZ_SCRIPT_URL="https://raw.githubusercontent.com/sorelferris/awesome-scripts/refs/heads/main/scripts/install-omz.sh"
CONDA_PREFIX="${CONDA_PREFIX:-$HOME/miniforge3}"

# Step toggles (defaults: the four essentials)
DO_OMZ=1
DO_NODE=1
DO_CONDA=1
DO_UV=1
DO_PIXI=0
DO_RUST=0
DO_ADVCPMV=0
NO_COLOR="${NO_COLOR:-}"
OPT_DECIDED=0   # set when optional tools are chosen via flags (skip interactive prompt)

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
usage() {
    cat <<'EOF'
Usage: setup_dev_env.sh [options]

Default installs: oh-my-zsh, nvm + Node.js, Miniforge3 (conda), uv.

Run interactively with no optional-tool flags to pick the optional tools
interactively (space = toggle, enter = confirm).

Options:
  -h, --help            Show this help message and exit
      --all             Install everything, including optional tools
      --with-pixi       Also install pixi
      --with-rust       Also install Rust (rustup)
      --with-advcpmv    Also install advcpmv (cp/mv with progress bar)
      --no-interactive  Skip the interactive optional-tool selection
      --skip-omz        Skip oh-my-zsh
      --skip-node       Skip nvm + Node.js
      --skip-conda      Skip Miniforge3
      --skip-uv         Skip uv
      --node-version V  Node.js version to install (default: 24)
      --no-color        Disable colored output

Environment:
  CONDA_PREFIX          Where to install Miniforge3 (default: ~/miniforge3)
  NO_COLOR=1            Disable colored output
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)         usage; exit 0 ;;
        --all)             DO_PIXI=1; DO_RUST=1; DO_ADVCPMV=1; OPT_DECIDED=1 ;;
        --with-pixi)       DO_PIXI=1; OPT_DECIDED=1 ;;
        --with-rust)       DO_RUST=1; OPT_DECIDED=1 ;;
        --with-advcpmv)    DO_ADVCPMV=1; OPT_DECIDED=1 ;;
        --no-interactive)  OPT_DECIDED=1 ;;
        --skip-omz)        DO_OMZ=0 ;;
        --skip-node)       DO_NODE=0 ;;
        --skip-conda)      DO_CONDA=0 ;;
        --skip-uv)         DO_UV=0 ;;
        --node-version)    NODE_VERSION="$2"; shift ;;
        --no-color)        NO_COLOR=1 ;;
        *) echo "error: unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

# -----------------------------------------------------------------------------
# Output helpers (colors resolved after --no-color is parsed)
# -----------------------------------------------------------------------------
if [[ -t 1 && -z "$NO_COLOR" ]]; then
    _c_green=$'\033[0;32m'
    _c_yellow=$'\033[1;33m'
    _c_red=$'\033[0;31m'
    _c_blue=$'\033[0;34m'
    _c_bold=$'\033[1m'
    _c_reset=$'\033[0m'
else
    _c_green=""; _c_yellow=""; _c_red=""; _c_blue=""; _c_bold=""; _c_reset=""
fi

ok()   { printf '%s[✓]%s %s\n' "$_c_green" "$_c_reset" "$*"; }
warn() { printf '%s[!]%s %s\n' "$_c_yellow" "$_c_reset" "$*"; }
err()  { printf '%s[✗]%s %s\n' "$_c_red" "$_c_reset" "$*" >&2; }
info() { printf '%s[ℹ]%s %s\n' "$_c_blue" "$_c_reset" "$*"; }
hdr()  { printf '\n%s==>%s %s%s%s\n' "$_c_bold" "$_c_reset" "$_c_bold" "$*" "$_c_reset"; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

# download <url> <dest>  — prefers curl, falls back to wget
download() {
    local url="$1" dest="$2"
    if command_exists curl; then
        curl -fsSL "$url" -o "$dest"
    elif command_exists wget; then
        wget -q "$url" -O "$dest"
    else
        err "neither curl nor wget is available"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Interactive multi-select menu
#   space = toggle · ↑/↓ or j/k = move · Enter = confirm · q/Ctrl-C = cancel
# Sets the global array _SEL_IDX to the 0-based indices of selected items.
# Returns: 0 = confirmed, 1 = cancelled, 2 = no usable tty.
# -----------------------------------------------------------------------------
multiselect() {
    _SEL_IDX=()
    local opts=("$@")
    local n=${#opts[@]}
    local -a sel
    local i cur=0 total
    for ((i=0; i<n; i++)); do sel[$i]=0; done

    [ -t 0 ] && [ -t 1 ] || return 2
    [ -e /dev/tty ] || return 2

    local stty_orig
    stty_orig=$(stty -g < /dev/tty 2>/dev/null) || return 2

    total=$((n + 2))   # title + items + hint lines

    _tty_restore() {
        stty "$stty_orig" < /dev/tty 2>/dev/null
        printf '\033[?25h'   # restore cursor
        printf '\033[0m'     # reset attributes
    }

    _render() {
        local j mark
        if [ "${_MULTI_FIRST:-1}" -eq 1 ]; then
            _MULTI_FIRST=0
        else
            printf '\033[%dA\033[J' "$total"   # rewind & clear
        fi
        printf '%sSelect optional tools  (space=toggle, enter=confirm, q=cancel)%s\n' "$_c_bold" "$_c_reset"
        for ((j=0; j<n; j++)); do
            if [ "${sel[$j]}" -eq 1 ]; then mark="x"; else mark=" "; fi
            if [ "$j" -eq "$cur" ]; then
                printf '  %s>[%s]%s %s%s%s\n' "$_c_bold" "$mark" "$_c_reset" "$_c_bold" "${opts[$j]}" "$_c_reset"
            else
                printf '    [%s] %s\n' "$mark" "${opts[$j]}"
            fi
        done
        printf '  %s↑/↓ or j/k move · space toggle · enter confirm · q cancel%s\n' "$_c_blue" "$_c_reset"
    }

    stty -echo -icanon -isig min 1 time 0 < /dev/tty
    printf '\033[?25l'   # hide cursor

    local key seq
    _MULTI_FIRST=1
    while true; do
        _render
        IFS= read -rsn1 key < /dev/tty || key=$'\n'
        case "$key" in
            $'\x1b')
                seq=""
                IFS= read -rsn2 -t 0.1 seq < /dev/tty 2>/dev/null || true
                case "$seq" in
                    '[A') [ "$cur" -gt 0 ] && cur=$((cur-1)) ;;
                    '[B') [ "$cur" -lt $((n-1)) ] && cur=$((cur+1)) ;;
                esac
                ;;
            ' ')        sel[$cur]=$((1 - sel[$cur])) ;;
            ''|$'\n')   break ;;
            q|Q|$'\x03') _tty_restore; echo; return 1 ;;
            j) [ "$cur" -lt $((n-1)) ] && cur=$((cur+1)) ;;
            k) [ "$cur" -gt 0 ] && cur=$((cur-1)) ;;
        esac
    done

    _tty_restore
    echo

    for ((i=0; i<n; i++)); do
        [ "${sel[$i]}" -eq 1 ] && _SEL_IDX+=("$i")
    done
    return 0
}

# -----------------------------------------------------------------------------
# Installation steps
# -----------------------------------------------------------------------------

ensure_system_deps() {
    local missing=""
    for c in curl wget git; do
        command_exists "$c" || missing="$missing $c"
    done
    [ -n "$missing" ] || return 0
    info "Installing missing system packages:$missing"
    if [ "$(id -u)" -eq 0 ]; then
        apt-get update && apt-get install -y $missing
    else
        sudo apt-get update && sudo apt-get install -y $missing
    fi
}

install_omz() {
    if command_exists zsh && [ -d "$HOME/.oh-my-zsh" ]; then
        warn "oh-my-zsh already installed, skipping"
        return 0
    fi
    local script="$WORKDIR/install-omz.sh"
    download "$OMZ_SCRIPT_URL" "$script" || return 1
    chmod +x "$script"
    sh "$script"
}

install_node() {
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    if [ ! -s "$NVM_DIR/nvm.sh" ]; then
        local installer="$WORKDIR/nvm-install.sh"
        download "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" "$installer" || return 1
        bash "$installer" || return 1
    else
        warn "nvm already installed, skipping"
    fi

    # shellcheck disable=SC1090
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    nvm install "$NODE_VERSION"
    nvm alias default "$NODE_VERSION"
    nvm use default
}

install_conda() {
    if [ -x "$CONDA_PREFIX/bin/conda" ]; then
        warn "Miniforge3 already installed at $CONDA_PREFIX, skipping"
        return 0
    fi

    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *) err "unsupported architecture for Miniforge3: $arch"; return 1 ;;
    esac

    local fname="Miniforge3-$(uname)-$arch.sh"
    local installer="$WORKDIR/$fname"
    download "https://github.com/conda-forge/miniforge/releases/latest/download/$fname" "$installer" || return 1

    # -b: batch mode (accept license), -p: install prefix
    bash "$installer" -b -p "$CONDA_PREFIX" || return 1

    # Initialize conda for the detected shell(s)
    local conda_bin="$CONDA_PREFIX/bin/conda"
    "$conda_bin" init bash >/dev/null 2>&1 || true
    command_exists zsh && "$conda_bin" init zsh >/dev/null 2>&1 || true
    ok "Miniforge3 installed to $CONDA_PREFIX"
}

install_uv() {
    if command_exists uv || [ -x "$HOME/.local/bin/uv" ]; then
        warn "uv already installed, skipping"
        return 0
    fi
    curl -LsSf https://astral.sh/uv/install.sh | sh
}

install_pixi() {
    if command_exists pixi || [ -x "$HOME/.pixi/bin/pixi" ]; then
        warn "pixi already installed, skipping"
        return 0
    fi
    curl -fsSL https://pixi.sh/install.sh | bash
}

install_rust() {
    if command_exists rustc && command_exists cargo; then
        warn "Rust already installed, running rustup update"
        # shellcheck disable=SC1090
        [ -s "$HOME/.cargo/env" ] && \. "$HOME/.cargo/env" 2>/dev/null || true
        rustup update || true
        return 0
    fi
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    # shellcheck disable=SC1090
    [ -s "$HOME/.cargo/env" ] && \. "$HOME/.cargo/env"
}

install_advcpmv() {
    if command_exists cpg && command_exists mvg; then
        warn "advcpmv already installed, skipping"
        return 0
    fi
    info "Installing build dependencies for advcpmv"
    if [ "$(id -u)" -eq 0 ]; then
        apt-get install -y build-essential autoconf automake
    else
        sudo apt-get install -y build-essential autoconf automake
    fi

    local dir="$WORKDIR/advcpmv"
    mkdir -p "$dir"
    download "https://raw.githubusercontent.com/jarun/advcpmv/master/install.sh" "$dir/install.sh" || return 1
    (
        cd "$dir"
        export FORCE_UNSAFE_CONFIGURE=1
        sh install.sh
    ) || { warn "advcpmv build failed"; return 1; }

    sudo mv "$dir/advcp" /usr/local/bin/cpg || return 1
    sudo mv "$dir/advmv" /usr/local/bin/mvg || return 1

    # Register aliases only if not already present
    local rc="$HOME/.zshrc"
    grep -q "alias cp='cpg -g'" "$rc" 2>/dev/null || echo "alias cp='cpg -g'" >> "$rc"
    grep -q "alias mv='mvg -g'" "$rc" 2>/dev/null || echo "alias mv='mvg -g'" >> "$rc"
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
print_summary() {
    # Make installed tools resolvable for version reporting
    export PATH="$HOME/.local/bin:$HOME/.pixi/bin:$HOME/.cargo/bin:$PATH"
    # shellcheck disable=SC1090
    [ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ] && \. "${NVM_DIR:-$HOME/.nvm}/nvm.sh" 2>/dev/null || true
    # shellcheck disable=SC1090
    [ -s "$CONDA_PREFIX/etc/profile.d/conda.sh" ] && \. "$CONDA_PREFIX/etc/profile.d/conda.sh" 2>/dev/null || true

    # qv <cmd> [args...] — first line of output, or "—"
    qv() {
        local c="$1"; shift
        if command_exists "$c"; then
            "$c" "$@" 2>/dev/null | head -n1
        else
            echo "—"
        fi
    }

    local zsh_v node_v npm_v conda_v uv_v pixi_v rustc_v cpg_v
    zsh_v=$(qv zsh --version)
    node_v=$(qv node --version)
    npm_v=$(qv npm --version)
    conda_v=$(qv conda --version)
    uv_v=$(qv uv --version)
    pixi_v=$(qv pixi --version)
    rustc_v=$(qv rustc --version)
    cpg_v=$(qv cpg --version)

    printf '\n%s\n' "$_c_bold=============================================$_c_reset"
    printf '%s%s  Tool Version Summary%s\n' "$_c_bold" "$_c_green" "$_c_reset"
    printf '%s\n' "$_c_bold=============================================$_c_reset"
    printf '%-16s %s\n' "zsh" "$zsh_v"
    printf '%-16s %s\n' "node" "$node_v"
    printf '%-16s %s\n' "npm" "$npm_v"
    printf '%-16s %s\n' "conda (miniforge3)" "$conda_v"
    printf '%-16s %s\n' "uv" "$uv_v"
    printf '%-16s %s\n' "pixi" "$pixi_v"
    printf '%-16s %s\n' "rustc" "$rustc_v"
    printf '%-16s %s\n' "cpg (advcpmv)" "${cpg_v:-—}"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
printf '%s\n' "${_c_bold}=============================================${_c_reset}"
printf '%s\n' "${_c_bold}     Development Environment Setup${_c_reset}"
printf '%s\n' "${_c_bold}=============================================${_c_reset}"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

if [ "$(id -u)" -eq 0 ]; then
    warn "running as root is not recommended; some installers may misbehave"
fi

# Interactive selection of optional tools (skipped if flags already decided, or no tty)
if [ "$OPT_DECIDED" -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then
    echo
    multiselect "pixi" "Rust (rustup)" "advcpmv (cp/mv progress)" || warn "selection cancelled — installing essentials only"
    for idx in "${_SEL_IDX[@]}"; do
        case "$idx" in
            0) DO_PIXI=1 ;;
            1) DO_RUST=1 ;;
            2) DO_ADVCPMV=1 ;;
        esac
    done
fi

# Show the plan
info "Installing:"
[ "$DO_OMZ" -eq 1 ] && echo "   • oh-my-zsh"
[ "$DO_NODE" -eq 1 ] && echo "   • nvm + Node.js ${NODE_VERSION}.x"
[ "$DO_CONDA" -eq 1 ] && echo "   • Miniforge3 (conda)"
[ "$DO_UV" -eq 1 ] && echo "   • uv"
[ "$DO_PIXI" -eq 1 ] && echo "   • pixi (optional)"
[ "$DO_RUST" -eq 1 ] && echo "   • Rust (optional)"
[ "$DO_ADVCPMV" -eq 1 ] && echo "   • advcpmv (optional)"

ensure_system_deps || { err "failed to install system dependencies"; exit 1; }

[ "$DO_OMZ" -eq 1 ] && { hdr "oh-my-zsh"; install_omz || warn "oh-my-zsh reported errors (continuing)"; }
[ "$DO_NODE" -eq 1 ] && { hdr "nvm + Node.js ${NODE_VERSION}.x"; install_node || warn "node setup failed (continuing)"; }
[ "$DO_CONDA" -eq 1 ] && { hdr "Miniforge3 (conda)"; install_conda || warn "conda setup failed (continuing)"; }
[ "$DO_UV" -eq 1 ] && { hdr "uv"; install_uv || warn "uv setup failed (continuing)"; }
[ "$DO_PIXI" -eq 1 ] && { hdr "pixi (optional)"; install_pixi || warn "pixi setup failed (continuing)"; }
[ "$DO_RUST" -eq 1 ] && { hdr "Rust (optional)"; install_rust || warn "rust setup failed (continuing)"; }
[ "$DO_ADVCPMV" -eq 1 ] && { hdr "advcpmv (optional)"; install_advcpmv || warn "advcpmv setup failed (continuing)"; }

print_summary

printf '\n%s[✓]%s Setup complete.%s\n' "$_c_green" "$_c_bold" "$_c_reset"
info "Restart your terminal, or run: source ~/.zshrc"
