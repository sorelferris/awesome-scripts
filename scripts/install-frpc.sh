#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# install-frpc.sh — install the frp client (frpc) from the latest GitHub release
#
#   1. Downloads the latest frp release for the current architecture
#   2. Installs binaries to /opt/frp (preserves an existing frpc.toml on upgrade)
#   3. Installs and enables a systemd service (frpc.service)
#
# Requires root. Run with: sudo install-frpc.sh
# =============================================================================

INSTALL_DIR="/opt/frp"
REPO="fatedier/frp"
SERVICE_NAME="frpc"
DO_START=0

usage() {
    cat <<'EOF'
Usage: install-frpc.sh [options]

Downloads the latest frp release, installs it to /opt/frp, and sets up the
frpc systemd service.

Options:
  -h, --help       Show this help message and exit
      --start      Enable AND start the service (default: enable only)
      --no-color   Disable colored output

Note: requires root. Run with: sudo install-frpc.sh
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)   usage; exit 0 ;;
        --start)     DO_START=1 ;;
        --no-color)  NO_COLOR=1 ;;
        --version)
            echo "install-frpc.sh (local script)"
            exit 0
            ;;
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

# Detect a proxy from common env vars. Returns the proxy URL or "" if none set.
# Honours both upper- and lower-case names; empty strings are ignored.
detect_proxy() {
    local var
    for var in HTTPS_PROXY https_proxy ALL_PROXY all_proxy; do
        if [ -n "${!var}" ]; then
            printf '%s' "${!var}"
            return 0
        fi
    done
    return 1
}

# Build a curl --proxy flag (with argument), or empty string if no proxy set.
# Caches the detected proxy in _PROXY_URL on first call.
curl_proxy_args() {
    if [ -z "${_PROXY_URL+x}" ]; then
        _PROXY_URL=$(detect_proxy || true)
    fi
    if [ -n "$_PROXY_URL" ]; then
        printf -- '--proxy %s ' "$_PROXY_URL"
    fi
}

# download <url> <dest>  — follows redirects, retries transient failures,
# uses HTTPS_PROXY/ALL_PROXY if set, and never hangs forever
download() {
    local url="$1" dest="$2"
    # shellcheck disable=SC2046
    curl -fsSL --connect-timeout 10 --max-time 300 --retry 3 --retry-delay 2 \
        $(curl_proxy_args) "$url" -o "$dest"
}

# Map `uname -m` to the architecture suffix used in frp release assets
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo amd64 ;;
        aarch64|arm64)  echo arm64 ;;
        armv7l|armv6l)  echo arm ;;
        riscv64)        echo riscv64 ;;
        *) return 1 ;;
    esac
}

# Resolve the latest release tag (e.g. v0.61.1) via the GitHub Releases API.
# This endpoint returns JSON directly and is more reliable in restricted networks
# than following the /releases/latest redirect, which often hangs or is blocked.
#
# If the API call fails, fall back to a HEAD on the redirect and parse the
# final URL (with a hard timeout so we never hang the script).
latest_version() {
    local proxy_args json url
    # shellcheck disable=SC2046
    proxy_args=$(curl_proxy_args)

    # Primary: GitHub Releases API (returns JSON, no redirect chasing needed)
    if json=$(curl -fsSL --connect-timeout 10 --max-time 30 \
                -H 'Accept: application/vnd.github+json' \
                $proxy_args \
                "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null) \
        && command_exists python3 \
        && version=$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])' 2>/dev/null) \
        && [ -n "$version" ]; then
        printf '%s' "$version"
        return 0
    fi

    # Fallback: follow /releases/latest with a strict timeout
    if url=$(curl -fsSL --connect-timeout 10 --max-time 30 -o /dev/null \
                -w '%{url_effective}' $proxy_args \
                "https://github.com/$REPO/releases/latest" 2>/dev/null) \
        && [ -n "$url" ]; then
        basename "$url"
        return 0
    fi

    cat >&2 <<EOF
failed to reach github.com / api.github.com.

  • If you are behind a firewall, set a proxy before running this script:
      export HTTPS_PROXY=http://127.0.0.1:7890
      # or
      export ALL_PROXY=socks5://127.0.0.1:1080

  • Current detected proxy: ${_PROXY_URL:-<none>}
EOF
    return 1
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    err "this script must run as root (try: sudo install-frpc.sh)"
    exit 1
fi

for c in curl tar; do
    command_exists "$c" || { err "required command missing: $c"; exit 1; }
done

printf '%s\n' "${_c_bold}=============================================${_c_reset}"
printf '%s\n' "${_c_bold}       frp client (frpc) installer${_c_reset}"
printf '%s\n' "${_c_bold}=============================================${_c_reset}"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

hdr "Resolving latest frp release"
if _proxy=$(detect_proxy 2>/dev/null) && [ -n "$_proxy" ]; then
    info "using proxy: $_proxy"
fi
printf '[info] %s …\n' "querying api.github.com/repos/$REPO/releases/latest"
version=$(latest_version) || exit 1
ver="${version#v}"
[ -n "$ver" ] || { err "could not determine a version from tag: $version"; exit 1; }
info "latest version: $version"

hdr "Detecting architecture"
arch=$(detect_arch) || { err "unsupported architecture: $(uname -m)"; exit 1; }
info "architecture: $arch"

asset="frp_${ver}_linux_${arch}.tar.gz"
url="https://github.com/$REPO/releases/download/${version}/${asset}"
tarball="$WORKDIR/$asset"

hdr "Downloading $asset"
download "$url" "$tarball" || {
    err "download failed: $url"
    [ -n "${_PROXY_URL:-}" ] || cat >&2 <<'EOF'

Hint: github.com is not reachable from this network. Re-run with a proxy:
  HTTPS_PROXY=http://127.0.0.1:7890 sudo -E install-frpc.sh
EOF
    exit 1
}

hdr "Installing to $INSTALL_DIR"
tar -xzf "$tarball" -C "$WORKDIR"
srcdir="$WORKDIR/frp_${ver}_linux_${arch}"
[ -f "$srcdir/frpc" ] || { err "frpc binary not found in archive"; exit 1; }

mkdir -p "$INSTALL_DIR"
install -m 0755 "$srcdir/frpc" "$INSTALL_DIR/frpc"
if [ -f "$srcdir/frps" ]; then
    install -m 0755 "$srcdir/frps" "$INSTALL_DIR/frps"
else
    warn "frps not present in this release, skipping"
fi

# Seed config on first install; preserve it on upgrade
if [ -s "$INSTALL_DIR/frpc.toml" ]; then
    info "existing $INSTALL_DIR/frpc.toml preserved"
else
    if [ -f "$srcdir/frpc.toml" ]; then
        install -m 0644 "$srcdir/frpc.toml" "$INSTALL_DIR/frpc.toml"
    else
        : > "$INSTALL_DIR/frpc.toml"
    fi
    warn "$INSTALL_DIR/frpc.toml is a sample — edit it before starting the service"
fi
ok "frpc $ver installed to $INSTALL_DIR"

if command_exists systemctl; then
    hdr "Setting up systemd service"
    cat > "/etc/systemd/system/$SERVICE_NAME.service" <<'EOF'
[Unit]
Description = frp client
After = network-online.target syslog.target
Wants = network-online.target

[Service]
Type = simple
ExecStart = /opt/frp/frpc -c /opt/frp/frpc.toml
Restart=always
RestartSec=5s
User=root

[Install]
WantedBy = multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME.service" >/dev/null 2>&1 || warn "failed to enable $SERVICE_NAME.service"
    if [ "$DO_START" -eq 1 ]; then
        systemctl start "$SERVICE_NAME.service" || warn "failed to start service — check $INSTALL_DIR/frpc.toml"
        ok "service started"
    else
        info "service enabled (not started) — edit $INSTALL_DIR/frpc.toml, then: systemctl start $SERVICE_NAME"
    fi
else
    warn "systemctl not found — skipping service setup (installed binaries only)"
fi

printf '\n%s[✓]%s Done. frpc %s installed to %s.%s\n' "$_c_green" "$_c_bold" "$ver" "$INSTALL_DIR" "$_c_reset"
