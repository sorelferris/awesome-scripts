#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# install-deskflow.sh — install Deskflow (KVM-style keyboard/mouse sharing)
# via Flatpak, set up autostart, and optionally launch it once.
#
# Idempotent: re-running skips already-installed steps.
# =============================================================================

FLATHUB_URL="https://dl.flathub.org/repo/flathub.flatpakrepo"
APP_ID="org.deskflow.deskflow"
DESKTOP_BASENAME="org.deskflow.deskflow.desktop"
DESKTOP_SRC="/var/lib/flatpak/exports/share/applications/$DESKTOP_BASENAME"
AUTOSTART_DIR="$HOME/.config/autostart"
AUTOSTART_FILE="$AUTOSTART_DIR/$DESKTOP_BASENAME"
DO_RUN=0

usage() {
    cat <<'EOF'
Usage: install-deskflow.sh [options]

Options:
  -h, --help       Show this help message and exit
      --run        Launch deskflow once after install (default: don't)
      --no-color   Disable colored output

Notes:
  • Requires sudo for apt; flatpak installs go to the current user's remotes.
  • Re-runs are safe — already-installed steps are skipped.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)   usage; exit 0 ;;
        --run)       DO_RUN=1 ;;
        --no-color)  NO_COLOR=1 ;;
        *) echo "error: unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    _c_green=$'\033[0;32m'; _c_yellow=$'\033[1;33m'; _c_red=$'\033[0;31m'
    _c_blue=$'\033[0;34m'; _c_bold=$'\033[1m'; _c_reset=$'\033[0m'
else
    _c_green=""; _c_yellow=""; _c_red=""; _c_blue=""; _c_bold=""; _c_reset=""
fi

ok()   { printf '%s[✓]%s %s\n' "$_c_green" "$_c_reset" "$*"; }
warn() { printf '%s[!]%s %s\n' "$_c_yellow" "$_c_reset" "$*"; }
err()  { printf '%s[✗]%s %s\n' "$_c_red" "$_c_reset" "$*" >&2; }
info() { printf '%s[ℹ]%s %s\n' "$_c_blue" "$_c_reset" "$*"; }
hdr()  { printf '\n%s==>%s %s%s%s\n' "$_c_bold" "$_c_reset" "$_c_bold" "$*" "$_c_reset"; }

command_exists() { command -v "$1" >/dev/null 2>&1; }
run_sudo() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

# -----------------------------------------------------------------------------
# Steps
# -----------------------------------------------------------------------------
install_flatpak() {
    if command_exists flatpak; then
        ok "flatpak already installed"
    else
        hdr "Installing flatpak + GNOME Software plugin"
        run_sudo apt-get update
        run_sudo apt-get install -y --no-install-recommends \
            flatpak gnome-software-plugin-flatpak
    fi
}

ensure_flathub() {
    if flatpak remotes --user 2>/dev/null | grep -q '^flathub'; then
        ok "flathub remote already configured"
    else
        hdr "Adding flathub remote (user)"
        flatpak remote-add --user --if-not-exists flathub "$FLATHUB_URL"
    fi
}

install_deskflow_app() {
    if flatpak list --app --user 2>/dev/null | grep -q "$APP_ID"; then
        ok "$APP_ID already installed"
    else
        hdr "Installing $APP_ID"
        flatpak install --user --noninteractive flathub "$APP_ID"
    fi
}

setup_autostart() {
    # Resolve the actual desktop file name from the installed app — deskflow
    # has changed app IDs before, so don't hardcode it on disk.
    local src
    src=$(find /var/lib/flatpak/exports/share/applications \
              /home/*/.local/share/flatpak/exports/share/applications \
              ~/.local/share/flatpak/exports/share/applications \
              -maxdepth 1 -name "org.deskflow*.desktop" 2>/dev/null \
              | head -n1 || true)
    src=${src:-$DESKTOP_SRC}

    if [ ! -f "$src" ]; then
        warn "desktop file not found at $src — autostart not configured"
        warn "this is expected on first run before the user session registers the app"
        return 0
    fi

    mkdir -p "$AUTOSTART_DIR"
    install -m 0644 "$src" "$AUTOSTART_DIR/$(basename "$src")"
    ok "autostart entry: $AUTOSTART_DIR/$(basename "$src")"
}

launch_once() {
    if [ "$DO_RUN" -eq 1 ]; then
        hdr "Launching $APP_ID"
        exec flatpak run "$APP_ID"
    else
        info "skipping launch (pass --run to start it now)"
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
printf '%s\n' "${_c_bold}=============================================${_c_reset}"
printf '%s\n' "${_c_bold}           Deskflow installer${_c_reset}"
printf '%s\n' "${_c_bold}=============================================${_c_reset}"

for c in apt-get find install; do
    command_exists "$c" || { err "required command missing: $c"; exit 1; }
done

install_flatpak
ensure_flathub
install_deskflow_app
setup_autostart

printf '\n%s[✓]%s Done. Deskflow will autostart on next session.%s\n' \
    "$_c_green" "$_c_bold" "$_c_reset"
info "Run now with: flatpak run $APP_ID  (or rerun this script with --run)"

launch_once