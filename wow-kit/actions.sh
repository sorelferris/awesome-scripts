#!/usr/bin/env bash
# Individual catalog actions. The CLI authenticates sudo before running them.
set -euo pipefail
umask 077

action=${1:-}
key=${2:-}
operation=${3:-}
state_dir=${WOW_KIT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/wow-kit}
item_dir="$state_dir/tools/$key"
receipt="$item_dir/installed"
os=$(uname -s)
arch=$(uname -m)
node_version=${WOW_KIT_NODE_VERSION:-24}

case "$key" in
    system-tools|zsh-shell|omz|node|conda|uv|pixi|rust|advcpmv) ;;
    *) printf 'Unknown item: %s\n' "$key" >&2; exit 2 ;;
esac

has() {
    local executable
    executable=$(command -v "$1") || return 1
    # The Apple Git stub offers to install Command Line Tools in a GUI.
    if [[ $os == Darwin && $1 == git && $executable == /usr/bin/git ]]; then
        /usr/bin/xcode-select -p >/dev/null 2>&1
    fi
}
fail() { printf '%s\n' "$*" >&2; return 1; }
managed() { [[ -f "$receipt" && ! -L "$receipt" ]]; }
apt_available() { [[ $os == Linux && -x /usr/bin/apt-get && -x /usr/bin/dpkg-query ]]; }
brew_available() { [[ $os == Darwin ]] && has brew; }

missing() {
    local executable
    for executable in "$@"; do
        if ! has "$executable"; then printf '%s\n' "$executable"; fi
    done
}

prerequisites() {
    case "$key" in
        system-tools) missing curl wget git zsh ;;
        zsh-shell) missing zsh ;;
        omz) missing git zsh ;;
        node|conda|uv|pixi|rust) missing curl ;;
        advcpmv) missing curl cc make patch xz autoconf automake ;;
    esac
}

login_shell() {
    case "$os" in
        Linux) getent passwd "$(id -un)" | cut -d: -f7 ;;
        Darwin) /usr/bin/dscl . -read "/Users/$(id -un)" UserShell | sed 's/^UserShell: //' ;;
        *) return 1 ;;
    esac
}

find_zsh() {
    [[ -f /etc/shells ]] || return 1
    local shell
    shell=$(command -v zsh) || return 1
    if [[ $shell == /* && -x $shell ]] && grep -Fxq "$shell" /etc/shells; then
        printf '%s\n' "$shell"
        return
    fi
    while IFS= read -r shell; do
        if [[ $shell == /*/zsh && -x $shell ]]; then
            printf '%s\n' "$shell"
            return
        fi
    done < /etc/shells
    return 1
}

payload_present() {
    case "$key" in
        system-tools) [[ -z $(prerequisites) ]] ;;
        zsh-shell) [[ -f "$item_dir/new-shell" && $(login_shell) == "$(< "$item_dir/new-shell")" ]] ;;
        omz) [[ -f "$item_dir/tree/oh-my-zsh.sh" ]] ;;
        node) [[ -s "$item_dir/nvm/nvm.sh" && -s "$item_dir/nvm/alias/default" ]] &&
            compgen -G "$item_dir/nvm/versions/node/*/bin/node" >/dev/null ;;
        conda) [[ -x "$item_dir/miniforge/bin/conda" ]] ;;
        uv) [[ -x "$item_dir/bin/uv" ]] ;;
        pixi) [[ -x "$item_dir/bin/pixi" ]] ;;
        rust) [[ -x "$item_dir/cargo/bin/rustc" && -x "$item_dir/cargo/bin/cargo" ]] ;;
        advcpmv) [[ -x "$item_dir/bin/cpg" && -x "$item_dir/bin/mvg" ]] ;;
    esac
}

installed() {
    if managed && payload_present; then return 0; fi
    local zdot=${ZDOTDIR:-$HOME}
    local omz_default="$HOME/.oh-my-zsh"
    if [[ $zdot != "$HOME" ]]; then omz_default="$zdot/ohmyzsh"; fi
    case "$key" in
        system-tools) [[ -z $(prerequisites) ]] ;;
        zsh-shell) [[ $(login_shell 2>/dev/null || true) == */zsh ]] ;;
        omz) [[ -f "${ZSH:-$omz_default}/oh-my-zsh.sh" || -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]] ;;
        node) [[ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]] &&
            compgen -G "${NVM_DIR:-$HOME/.nvm}/versions/node/*/bin/node" >/dev/null ;;
        conda) [[ -x "${CONDA_PREFIX:-$HOME/miniforge3}/bin/conda" ]] || has conda ;;
        uv) [[ -x "$HOME/.local/bin/uv" ]] || has uv ;;
        pixi) [[ -x "${PIXI_HOME:-$HOME/.pixi}/bin/pixi" ]] || has pixi ;;
        rust) { [[ -x "${CARGO_HOME:-$HOME/.cargo}/bin/rustc" && -x "${CARGO_HOME:-$HOME/.cargo}/bin/cargo" ]]; } ||
            { has rustc && has cargo; } ;;
        advcpmv) has cpg && has mvg ;;
    esac
}

supported() {
    case "$os" in Linux|Darwin) ;; *) return 1 ;; esac
    case "$key" in
        system-tools) apt_available || brew_available ;;
        zsh-shell) [[ -x /usr/bin/chsh ]] && { find_zsh >/dev/null || apt_available || brew_available; } ;;
        advcpmv) [[ $os == Linux ]] && { [[ -z $(prerequisites) ]] || apt_available; } ;;
        conda)
            case "$arch" in x86_64|amd64|aarch64|arm64) ;; *) return 1 ;; esac
            [[ -z $(prerequisites) ]] || apt_available || brew_available ;;
        *) [[ -z $(prerequisites) ]] || apt_available || brew_available ;;
    esac
}

needs_root() {
    case "$operation" in
        install)
            if ! supported; then
                printf '%s is unavailable on this system.\n' "$key" >&2
                return 2
            fi
            if [[ $key == zsh-shell ]]; then return 0; fi
            if apt_available && [[ -n $(prerequisites) ]]; then return 0; fi ;;
        remove)
            if ! managed; then return 1; fi
            case "$key" in
                zsh-shell) return 0 ;;
                system-tools) if [[ -s "$item_dir/apt-packages" ]]; then return 0; fi ;;
            esac ;;
        *) printf 'Expected install or remove.\n' >&2; return 2 ;;
    esac
    return 1
}

as_root() {
    if [[ $(id -u) == 0 ]]; then
        "$@" </dev/null
    else
        /usr/bin/sudo -n -- "$@" </dev/null
    fi
}

apt_get() {
    as_root /usr/bin/env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
        /usr/bin/apt-get -o DPkg::Lock::Timeout=30 \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

brew_run() {
    NONINTERACTIVE=1 HOMEBREW_NO_AUTO_UPDATE=1 brew "$@" </dev/null
}

# Only explicitly requested packages absent before the system-tools action
# are eligible for removal. Other items share their prerequisite packages.
install_system_packages() {
    local executable package status
    local -a packages
    packages=()
    if apt_available; then
        for executable in "$@"; do
            case "$executable" in
                cc|make) package=build-essential ;;
                xz) package=xz-utils ;;
                curl|wget|git|zsh|patch|autoconf|automake) package=$executable ;;
                *) fail "Unhandled system dependency: $executable"; return 1 ;;
            esac
            status=$(/usr/bin/dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)
            if [[ $status == installed ]]; then continue; fi
            case " ${packages[*]:-} " in
                *" $package "*) ;;
                *) packages+=("$package") ;;
            esac
        done
        if [[ -z ${packages[*]:-} ]]; then return 0; fi
        apt_get update
        apt_get -y --no-remove install "${packages[@]}"
        if [[ $key == system-tools ]]; then printf '%s\n' "${packages[@]}" > "$item_dir/apt-packages"; fi
    elif brew_available; then
        for executable in "$@"; do
            if ! brew_run list --versions "$executable" >/dev/null 2>&1; then packages+=("$executable"); fi
        done
        if [[ -z ${packages[*]:-} ]]; then return 0; fi
        brew_run install "${packages[@]}"
        if [[ $key == system-tools ]]; then printf '%s\n' "${packages[@]}" > "$item_dir/brew-packages"; fi
    else
        fail "System dependencies missing: $*"
    fi
}

ensure_dependencies() {
    local executable wanted
    wanted=$(prerequisites)
    if [[ -z $wanted ]]; then return 0; fi
    local -a dependencies
    dependencies=()
    while IFS= read -r executable; do dependencies+=("$executable"); done <<< "$wanted"
    install_system_packages "${dependencies[@]}"
    wanted=$(prerequisites)
    if [[ -n $wanted ]]; then fail "These tools are still unavailable on PATH: $wanted"; fi
}

download() {
    curl -q --fail --silent --show-error --location --retry 2 --connect-timeout 20 --max-time 600 \
        --proto '=https' --proto-redir '=https' --output "$2" "$1"
}

edit_shell_profiles() {
    python3 - "$1" "$key" "$item_dir" <<'PY'
import json
import os
from pathlib import Path
import re
import shlex
import stat
import sys
import tempfile

operation, key, directory = sys.argv[1:]
directory = Path(directory)
record = directory / "profiles.json"
home = Path.home()
zdot = Path(os.environ.get("ZDOTDIR") or home)
marker = f"# >>> wow-kit / {key} >>>"
end_marker = f"# <<< wow-kit / {key} <<<"
block_pattern = re.compile(
    r"^" + re.escape(marker) + r"\r?\n.*?^" + re.escape(end_marker) + r"\r?\n?",
    re.MULTILINE | re.DOTALL,
)

if record.exists():
    paths = [Path(path) for path in json.loads(record.read_text())]
elif operation == "remove":
    sys.exit(0)
else:
    paths = [zdot / ".zshrc"]
    if key != "omz":
        bash_login = next(
            (home / name for name in (".bash_profile", ".bash_login", ".profile")
             if (home / name).exists()),
            home / ".profile",
        )
        paths.extend([home / ".bashrc", bash_login])
    paths = list(dict.fromkeys(path.resolve() for path in paths))
    record.write_text(json.dumps([str(path) for path in paths]))

activate = shlex.quote(str(directory / "activate.sh"))
block = (
    f"{marker}\n"
    'if [ -n "${BASH_VERSION:-}${ZSH_VERSION:-}" ] && '
    f"[ -r {activate} ]; then\n"
    f"    . {activate}\n"
    "fi\n"
    f"{end_marker}\n"
).encode()

for path in paths:
    existing = path.exists()
    if not existing and operation == "remove":
        continue
    if existing and not path.is_file():
        raise OSError(f"Shell configuration is not a regular file: {path}")
    contents = path.read_bytes() if existing else b""
    decoded = contents.decode("utf-8", errors="surrogateescape")
    replacement = block_pattern.sub("", decoded).encode("utf-8", errors="surrogateescape")
    if operation == "add":
        if replacement and not replacement.endswith(b"\n"):
            replacement += b"\n"
        replacement += block
    if replacement == contents:
        continue
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".wow-kit-")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(replacement)
        if existing:
            os.chmod(temporary, stat.S_IMODE(path.stat().st_mode))
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
PY
}

add_bin_path() {
    printf 'case ":$PATH:" in *:%q:*) ;; *) export PATH=%q:"$PATH" ;; esac\n' "$1" "$1"
}

install_omz() {
    local installer
    installer="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/install-omz.sh"
    if [[ ! -f $installer ]]; then installer="$(dirname -- "$installer")/../scripts/install-omz.sh"; fi
    mkdir -p "$work/ohmyzsh"
    touch "$work/ohmyzsh/.zshrc"
    ZDOTDIR="$work/ohmyzsh" ZSH="$item_dir/tree" ZSH_CUSTOM="$item_dir/tree/custom" \
        REPO=ohmyzsh/ohmyzsh REMOTE=https://github.com/ohmyzsh/ohmyzsh.git BRANCH=master \
        sh "$installer" --unattended --keep-zshrc </dev/null
    {
        printf 'export ZSH=%q\n' "$item_dir/tree"
        printf 'export ZSH_CUSTOM=%q\n' "$item_dir/tree/custom"
        printf '%s\n' 'ZSH_THEME="steeef"' \
            'plugins=(git zsh-autosuggestions zsh-syntax-highlighting)' \
            '. "$ZSH/oh-my-zsh.sh"'
    } > "$item_dir/activate.sh"
}

install_node() {
    if [[ ! $node_version =~ ^v?[0-9]+(\.[0-9]+){0,2}$ && ! $node_version =~ ^lts/([a-z]+|\*)$ ]]; then
        fail "Invalid Node.js version: $node_version"
        return 1
    fi
    export NVM_DIR="$item_dir/nvm"
    mkdir -p "$NVM_DIR"
    local file
    for file in nvm.sh nvm-exec bash_completion; do
        download "https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/$file" "$NVM_DIR/$file"
    done
    chmod +x "$NVM_DIR/nvm-exec"
    (
        # nvm uses ordinary POSIX shell options.
        set +eu
        . "$NVM_DIR/nvm.sh" --no-use || exit 1
        nvm install "$node_version" && nvm alias default "$node_version"
    )
    {
        printf 'export NVM_DIR=%q\n. "$NVM_DIR/nvm.sh"\n' "$NVM_DIR"
        printf '%s\n' '[ -z "${BASH_VERSION:-}" ] || . "$NVM_DIR/bash_completion"'
    } > "$item_dir/activate.sh"
}

install_conda() {
    local target_os=$os target_arch filename
    if [[ $os == Darwin ]]; then target_os=MacOSX; fi
    case "$arch" in
        x86_64|amd64) target_arch=x86_64 ;;
        aarch64|arm64) target_arch=arm64
            if [[ $os == Linux ]]; then target_arch=aarch64; fi ;;
    esac
    filename="Miniforge3-$target_os-$target_arch.sh"
    download "https://github.com/conda-forge/miniforge/releases/latest/download/$filename" "$work/$filename"
    bash "$work/$filename" -b -p "$item_dir/miniforge" </dev/null
    local conda="$item_dir/miniforge/bin/conda"
    {
        printf 'if [ -n "${ZSH_VERSION:-}" ]; then\n'
        printf '    eval "$(%q shell.zsh hook)"\n' "$conda"
        printf 'elif [ -n "${BASH_VERSION:-}" ]; then\n'
        printf '    eval "$(%q shell.bash hook)"\n' "$conda"
        printf 'fi\n'
    } > "$item_dir/activate.sh"
}

install_uv() {
    download https://astral.sh/uv/install.sh "$work/uv.sh"
    UV_UNMANAGED_INSTALL="$item_dir/bin" UV_NO_MODIFY_PATH=1 sh "$work/uv.sh" </dev/null
    add_bin_path "$item_dir/bin" > "$item_dir/activate.sh"
}

install_pixi() {
    download https://pixi.sh/install.sh "$work/pixi.sh"
    PIXI_BIN_DIR="$item_dir/bin" PIXI_NO_PATH_UPDATE=1 PIXI_NO_TELEMETRY=1 sh "$work/pixi.sh" </dev/null
    add_bin_path "$item_dir/bin" > "$item_dir/activate.sh"
}

install_rust() {
    download https://sh.rustup.rs "$work/rustup.sh"
    CARGO_HOME="$item_dir/cargo" RUSTUP_HOME="$item_dir/rustup" \
        sh "$work/rustup.sh" -y --no-modify-path </dev/null
    {
        printf 'export CARGO_HOME=%q RUSTUP_HOME=%q\n' "$item_dir/cargo" "$item_dir/rustup"
        add_bin_path "$item_dir/cargo/bin"
    } > "$item_dir/activate.sh"
}

install_advcpmv() {
    download https://raw.githubusercontent.com/jarun/advcpmv/master/install.sh "$work/advcpmv.sh"
    (cd -- "$work" && FORCE_UNSAFE_CONFIGURE=1 sh ./advcpmv.sh </dev/null)
    mkdir -p "$item_dir/bin"
    install -m 755 "$work/advcp" "$item_dir/bin/cpg"
    install -m 755 "$work/advmv" "$item_dir/bin/mvg"
    {
        add_bin_path "$item_dir/bin"
        printf '%s\n' 'if [ -n "${ZSH_VERSION:-}" ]; then' \
            "    alias cp='cpg -g'" "    alias mv='mvg -g'" 'fi'
    } > "$item_dir/activate.sh"
}

set_login_shell() {
    local previous shell
    previous=$(login_shell)
    shell=$(find_zsh) || { fail "Install zsh and register it in /etc/shells first."; return 1; }
    [[ -n $previous && -x $previous ]] || { fail "Could not determine your current login shell."; return 1; }
    printf '%s\n' "$previous" > "$item_dir/previous-shell"
    printf '%s\n' "$shell" > "$item_dir/new-shell"
    as_root /usr/bin/chsh -s "$shell" "$(id -un)"
}

restore_login_shell() {
    local previous current
    previous=$(< "$item_dir/previous-shell")
    current=$(login_shell)
    if [[ $current == "$(< "$item_dir/new-shell")" ]]; then
        [[ $previous == /* && -x $previous ]] || { fail "Previous login shell is unavailable: $previous"; return 1; }
        as_root /usr/bin/chsh -s "$previous" "$(id -un)"
    fi
}

validate_system_removal() {
    local package current_shell
    current_shell=$(login_shell 2>/dev/null || true)
    current_shell=${current_shell:-${SHELL:-}}
    for package in "$@"; do
        case "$package" in
            zsh)
                if [[ $current_shell == */zsh ]]; then
                    fail 'Switch away from zsh before removing the zsh package.'
                    return 1
                fi ;;
            curl|wget|git) ;;
            *) fail "Refusing unexpected package in the system tools receipt: $package"; return 1 ;;
        esac
        if [[ $package == zsh || $package == git ]] && [[ -f "$state_dir/tools/omz/installed" ]]; then
            fail "Remove the managed Oh My Zsh before removing $package."
            return 1
        fi
    done
}

remove_system_tools() {
    local plan line action package unused
    local -a packages
    packages=()
    if [[ -s "$item_dir/apt-packages" ]]; then
        while IFS= read -r line; do packages+=("$line"); done < "$item_dir/apt-packages"
        validate_system_removal "${packages[@]}"
        plan=$(LC_ALL=C /usr/bin/apt-get -o APT::Get::AutomaticRemove=false -s remove "${packages[@]}")
        while read -r action package unused; do
            case "$action" in
                Remv|Purg)
                    package=${package%%:*}
                    case " ${packages[*]} " in
                        *" $package "*) ;;
                        *) fail "Removing this item would also remove $package."; return 1 ;;
                    esac ;;
                Inst) fail "Removing this item would install or upgrade $package."; return 1 ;;
            esac
        done <<< "$plan"
        apt_get -o APT::Get::AutomaticRemove=false -y remove "${packages[@]}"
    fi
    if [[ -s "$item_dir/brew-packages" ]]; then
        packages=()
        while IFS= read -r line; do packages+=("$line"); done < "$item_dir/brew-packages"
        validate_system_removal "${packages[@]}"
        brew_run uninstall "${packages[@]}"
    fi
}

archive_item() {
    local archive
    mkdir -p "$state_dir/removed"
    archive=$(mktemp -d "$state_dir/removed/$key.XXXXXXXX")
    mv -- "$item_dir" "$archive/"
    printf 'Previous %s files saved in %s/%s.\n' "$key" "$archive" "$key"
}

install_item() {
    if installed; then
        printf '%s is already installed.\n' "$key"
        return
    fi
    supported || { fail "$key is unavailable on this system."; return 1; }
    if [[ -e "$item_dir" || -L "$item_dir" ]]; then
        if [[ -f "$item_dir/pending" && ! -L "$item_dir" && ! -e "$receipt" ]]; then
            edit_shell_profiles remove
            archive_item
        else
            fail "Existing wow-kit files for $key need to be removed or moved first: $item_dir"
            return 1
        fi
    fi
    install_directory_created=0
    work=$(mktemp -d)
    cleanup_install() {
        local result=$?
        trap - EXIT
        rm -rf -- "$work"
        if (( result != 0 && install_directory_created )) && ! managed; then
            if [[ -s "$item_dir/apt-packages" || -s "$item_dir/brew-packages" || -s "$item_dir/new-shell" ]]; then
                # Retain a receipt so the system change can be rolled back.
                touch "$receipt"
            else
                edit_shell_profiles remove || return "$result"
                rm -rf -- "$item_dir"
            fi
        fi
        exit "$result"
    }
    trap cleanup_install EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mkdir -p -- "$(dirname -- "$item_dir")"
    mkdir -- "$item_dir"
    install_directory_created=1
    touch "$item_dir/pending"

    ensure_dependencies
    case "$key" in
        system-tools) ;;
        zsh-shell) set_login_shell ;;
        omz|node|conda|uv|pixi|rust|advcpmv) "install_$key" ;;
    esac
    payload_present || { fail "Could not verify $key installation."; return 1; }
    if [[ -f "$item_dir/activate.sh" ]]; then edit_shell_profiles add; fi
    touch "$receipt"
    rm -f -- "$item_dir/pending"
}

remove_item() {
    if ! managed; then
        fail "$key is not managed by wow-kit."
        return 1
    fi
    case "$key" in
        system-tools)
            remove_system_tools
            rm -rf -- "$item_dir" ;;
        zsh-shell)
            restore_login_shell
            rm -rf -- "$item_dir" ;;
        omz|node|conda|rust)
            edit_shell_profiles remove
            archive_item ;;
        uv|pixi|advcpmv)
            edit_shell_profiles remove
            rm -rf -- "$item_dir" ;;
    esac
}

export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false GCM_INTERACTIVE=never
export GIT_SSH_COMMAND='ssh -oBatchMode=yes -oStrictHostKeyChecking=yes'
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
case "$action" in
    status)
        if installed; then exit 0; fi
        if supported; then exit 1; fi
        exit 2 ;;
    managed) managed ;;
    prerequisites) prerequisites ;;
    needs-root) needs_root ;;
    install) install_item ;;
    remove) remove_item ;;
    *) printf 'Usage: %s status|managed|prerequisites|install|remove KEY or needs-root KEY install|remove\n' "$0" >&2; exit 2 ;;
esac
