#!/usr/bin/env bash
# ============================================================================
# install-rime.sh
# One-click installer & configurator for the Rime Chinese input method
# (Fcitx5 + fcitx5-rime) on Ubuntu 24.04.
#
# What this script does:
#   1. Installs the Fcitx5 framework, the Rime engine, the config GUI and
#      CJK fonts (plus libime so the built-in pinyin also works as fallback).
#   2. Registers Fcitx5 as the system default input-method framework
#      (via im-config).
#   3. Writes the input-method environment variables for both Wayland and
#      X11 sessions (into ~/.xprofile).
#   4. Bootstraps a minimal Rime user config that defaults to Simplified-
#      Chinese Luna Pinyin (朙月拼音·简化字), which ships with fcitx5-rime.
#   5. (Optional) deploys the official Rime "plum" schema installer so you
#      can later add Wubi / Double Pinyin / custom schemes with one command.
#
# Usage:
#   sudo bash install-rime.sh             # interactive (asks before plum)
#   sudo SKIP_PLUM=1 bash install-rime.sh # skip the optional plum install
#
# Tested on: Ubuntu 24.04 LTS (x86_64), GNOME + Wayland.
# Run it from an interactive terminal; a GUI session is required afterwards.
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Global settings (edit these if you know what you are doing)
# ---------------------------------------------------------------------------
# When run via `sudo bash install-rime.sh`, $HOME points to /root. Detect the
# original invoking user so configs land in the right account.
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
if [[ -z "$REAL_HOME" ]]; then
    REAL_HOME="$HOME"
fi
RIME_USER_DIR="$REAL_HOME/.local/share/fcitx5/rime"
XPROFILE="$REAL_HOME/.xprofile"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
info()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
ok()    { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Sanity checks: must be a Debian/Ubuntu family system with a GUI session.
# ---------------------------------------------------------------------------
require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        err "Please run this script with sudo:  sudo bash install-rime.sh"
        exit 1
    fi
}

check_gui_session() {
    # A Wayland or X11 session must be present; otherwise fcitx5 has nowhere
    # to run and the later "restart framework" step would be pointless.
    if [[ -z "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" ]]; then
        warn "No graphical session detected. Input methods need a GUI login."
        warn "Run this script from within your desktop session, then re-login."
    fi
}

check_os() {
    if ! command -v apt-get >/dev/null 2>&1; then
        err "This script only supports Debian/Ubuntu-based systems (apt-get)."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# 1. Install packages
# ---------------------------------------------------------------------------
install_packages() {
    info "Updating package lists..."
    apt-get update

    info "Installing Fcitx5 + Rime + fonts..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        fcitx5 \
        fcitx5-rime \
        fcitx5-chinese-addons \
        fcitx5-config-qt \
        libime-data \
        fonts-noto-cjk \
        im-config
    ok "Packages installed."
}

# ---------------------------------------------------------------------------
# 2. Set Fcitx5 as the default input-method framework
# ---------------------------------------------------------------------------
set_fcitx_default() {
    info "Registering Fcitx5 as the default input-method framework..."
    # im-config -n fcitx5  selects fcitx5 non-interactively and writes the
    # /etc/X11/xinit/xinputrc choice. This must run as root.
    im-config -n fcitx5
    ok "Default framework set to fcitx5."
}

# ---------------------------------------------------------------------------
# 3. Write input-method environment variables for Wayland and X11
# ---------------------------------------------------------------------------
write_env_vars() {
    info "Writing IM environment variables to ${XPROFILE}..."

    # Guard against duplicate writes on re-runs.
    if grep -q "GTK_IM_MODULE=fcitx" "$XPROFILE" 2>/dev/null; then
        warn "Env vars already present in ${XPROFILE}, skipping."
        return
    fi

    cat >> "$XPROFILE" <<'EOF'

# --- Rime / Fcitx5 input method environment (added by install-rime.sh) ---
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
# Optional: let SDL apps use the input method as well
# export SDL_IM_MODULE=fcitx
# --- end of Rime section ---
EOF
    ok "Environment variables written."
}

# ---------------------------------------------------------------------------
# 4. Bootstrap a minimal Rime user config (default: 朙月拼音·简化字)
# ---------------------------------------------------------------------------
write_rime_config() {
    info "Bootstrapping Rime user config at ${RIME_USER_DIR}..."

    mkdir -p "$RIME_USER_DIR"

    # default.custom.yaml: force the schema list and enable Simplified output.
    # luna_pinyin_simp ships with fcitx5-rime and needs no extra download.
    if [[ ! -f "$RIME_USER_DIR/default.custom.yaml" ]]; then
        cat > "$RIME_USER_DIR/default.custom.yaml" <<'EOF'
# Rime configuration added by install-rime.sh.
# Switch schemas anytime by pressing Ctrl+` inside the input bar.
patch:
  schema_list:
    - schema: luna_pinyin_simp      # 朙月拼音·简化字
  menu/page_size: 9                 # number of candidates per page
EOF
    else
        warn "default.custom.yaml already exists, leaving it untouched."
    fi

    # An empty default.yaml prevents Rime from falling back to a non-Chinese
    # default; it is harmless and often expected by Rime deployments.
    if [[ ! -f "$RIME_USER_DIR/default.yaml" ]]; then
        touch "$RIME_USER_DIR/default.yaml"
    fi

    ok "Rime user config written."
}

# ---------------------------------------------------------------------------
# 5. (Optional) Install Rime's official "plum" schema installer
# ---------------------------------------------------------------------------
install_plum() {
    if [[ "${SKIP_PLUM:-0}" == "1" ]]; then
        info "SKIP_PLUM=1, skipping plum installation."
        return
    fi

    # Only ask when running interactively (a TTY); otherwise default to yes.
    if [[ -t 0 ]]; then
        read -r -p "Install Rime 'plum' for easy Wubi / Double Pinyin support? [Y/n] " ans
        if [[ "${ans:-y}" =~ ^[Nn]$ ]]; then
            info "Skipping plum installation."
            return
        fi
    fi

    info "Cloning and running Rime 'plum' installer..."
    if command -v git >/dev/null 2>&1; then
        PLUM_DIR="/tmp/rime-plum"
        rm -rf "$PLUM_DIR"
        git clone --depth 1 https://github.com/rime/plum.git "$PLUM_DIR"
        bash "$PLUM_DIR/plum" --user-dir "$RIME_USER_DIR" install \
            "luna-pinyin" "double-pinyin" || true
    else
        warn "git not found; install it with 'sudo apt install git' to use plum."
    fi
    ok "Plum deployment finished (if installed)."
}

# ---------------------------------------------------------------------------
# 6. Restart Fcitx5 so the new config takes effect
# ---------------------------------------------------------------------------
restart_fcitx() {
    info "Restarting Fcitx5 to load the new configuration..."
    # Everything here must run as the real logged-in user, never as root.
    if [[ "$(id -u)" -eq 0 ]]; then
        if command -v fcitx5-remote >/dev/null 2>&1; then
            sudo -u "$REAL_USER" fcitx5-remote -r >/dev/null 2>&1 || true
        fi
        # Kill any running fcitx5, then relaunch it under the user session.
        pkill -x fcitx5 2>/dev/null && sleep 1 || true
        if [[ -n "${WAYLAND_DISPLAY:-}" || -n "${DISPLAY:-}" ]]; then
            sudo -u "$REAL_USER" env DISPLAY="${DISPLAY:-}" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
                setsid nohup fcitx5 -d >/dev/null 2>&1 || true
        fi
    else
        fcitx5-remote -r >/dev/null 2>&1 || true
        pkill -x fcitx5 2>/dev/null && sleep 1 || true
        (setsid nohup fcitx5 -d >/dev/null 2>&1 &) || true
    fi
    ok "Fcitx5 restarted (or scheduled to start on next login)."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    info "Starting Rime (Fcitx5) installation for Ubuntu 24.04."
    check_os
    check_gui_session
    require_root

    install_packages
    set_fcitx_default
    write_env_vars
    write_rime_config
    install_plum
    restart_fcitx

    # If run with sudo, the files above were created by root; hand ownership
    # back to the real user so they can edit configs without root.
    if [[ "$(id -u)" -eq 0 ]]; then
        chown -R "$REAL_USER":"$REAL_USER" "$RIME_USER_DIR" "$XPROFILE" 2>/dev/null || true
    fi

    echo
    ok "Done. Please LOG OUT and back in (or reboot) to activate the input method."
    ok "Then add 'Rime' in Settings > Keyboard, and press Ctrl+\` to switch schemas."
}

main "$@"
