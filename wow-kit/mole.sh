#!/usr/bin/env bash
# Platform-specific, per-user Mole installation. Maintenance runs separately via mo.
set -euo pipefail
umask 077

action=${1:-}
operation=${3:-}
system=$(uname -s)
state_root=${WOW_KIT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/wow-kit}
item_dir="$state_root/tools/mole"
receipt="$item_dir/installed"
bin_dir="$HOME/.local/bin"
command_path="$bin_dir/mo"
launcher="$item_dir/launcher"
repository=
case "$system" in
    Darwin) repository=tw93/Mole ;;
    Linux) repository=ccyisafool/mole-for-ubuntu-and-friends ;;
esac

fail() { printf 'Mole: %s\n' "$*" >&2; exit 2; }
managed() {
    [[ -n $repository && -f $receipt && ! -L $receipt && ! -L $item_dir ]] &&
        [[ $(head -n 1 "$receipt") == "$repository" ]]
}
own_link() {
    [[ -L $command_path && $(readlink "$command_path") == "$launcher" ]]
}
payload_present() {
    [[ -x $launcher && -x "$item_dir/bin/mo" ]] && own_link
}

is_mole_script() {
    python3 - "$1" <<'PY'
from pathlib import Path
import sys

try:
    with Path(sys.argv[1]).resolve().open("rb") as source:
        text = source.read(16384)
    known = (b"MOLE_HOME=" in text and b"lib/core.sh" in text) or any(
        marker in text for marker in (b"Mole - Main CLI", b"Lightweight alias to run Mole")
    )
except (OSError, RuntimeError):
    known = False
sys.exit(0 if known else 1)
PY
}

installed() {
    if managed && payload_present; then return 0; fi
    local name candidate
    for name in mo mole; do
        candidate=$(command -v "$name" 2>/dev/null || true)
        if [[ -n $candidate ]] && is_mole_script "$candidate"; then return 0; fi
    done
    [[ -x $command_path ]] && is_mole_script "$command_path"
}

prerequisites() {
    if [[ $system == Darwin ]] && ! command -v curl >/dev/null 2>&1; then
        printf 'curl\n'
    fi
}

supported() {
    case "$system" in
        Darwin)
            local version
            version=$(/usr/bin/sw_vers -productVersion) || return 1
            [[ ${version%%.*} =~ ^[0-9]+$ && ${version%%.*} -ge 12 ]] || return 1
            case "$(uname -m)" in arm64|x86_64) ;; *) return 1 ;; esac
            [[ -z $(prerequisites) ]] || return 1
            ;;
        Linux)
            [[ ${BASH_VERSINFO[0]} -ge 4 ]] || return 1
            readlink -f / >/dev/null 2>&1 || return 1
            ;;
        *) return 1 ;;
    esac
    local candidate
    candidate=$(command -v mo 2>/dev/null || true)
    if [[ -n $candidate && $candidate != "$command_path" ]]; then return 1; fi
    if [[ -e $command_path || -L $command_path ]] && ! own_link; then return 1; fi
}

download() {
    if command -v curl >/dev/null 2>&1; then
        curl -q -fsSL --proto '=https' --proto-redir '=https' --retry 2 \
            --connect-timeout 15 --max-time 180 "$1" --output "$2"
    else
        python3 - "$1" "$2" <<'PY'
from pathlib import Path
import shutil
import sys
import urllib.request

request = urllib.request.Request(sys.argv[1], headers={"User-Agent": "wow-kit"})
try:
    with urllib.request.urlopen(request, timeout=45) as response, Path(sys.argv[2]).open("wb") as output:
        if not response.url.startswith("https://"):
            sys.exit("Mole: download redirected away from HTTPS")
        shutil.copyfileobj(response, output)
except OSError as error:
    sys.exit(f"Mole: download failed: {error}")
PY
    fi
}

checkout() {
    download "https://api.github.com/repos/$repository/git/ref/heads/main" "$work/ref.json"
    revision=$(python3 - "$work/ref.json" <<'PY'
import json
from pathlib import Path
import re
import sys

try:
    ref = json.loads(Path(sys.argv[1]).read_text())
    value = ref["object"]
    if (ref["ref"] != "refs/heads/main" or value["type"] != "commit"
            or not re.fullmatch("[a-f0-9]{40}", value["sha"])):
        raise ValueError("Unexpected GitHub reference")
except (KeyError, TypeError, ValueError):
    sys.exit("Mole: GitHub did not return a valid upstream commit")
print(value["sha"])
PY
    )
    download "https://codeload.github.com/$repository/tar.gz/$revision" "$work/source.tar.gz"
    python3 - "$work/source.tar.gz" "$work/source" "${repository##*/}-$revision" <<'PY'
from pathlib import Path, PurePosixPath
import shutil
import sys
import tarfile

archive, destination, prefix = sys.argv[1:]
root = Path(destination)
try:
    with tarfile.open(archive, "r:gz") as source:
        for member in source:
            parts = PurePosixPath(member.name).parts
            if not parts or parts[0].lower() != prefix.lower() or ".." in parts:
                sys.exit("Mole: unexpected archive path")
            if len(parts) < 2 or member.isdir():
                continue
            if not member.isfile():
                continue
            path = root.joinpath(*parts[1:])
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with source.extractfile(member) as contents, path.open("xb") as output:
                shutil.copyfileobj(contents, output)
            path.chmod(0o700 if member.mode & 0o111 else 0o600)
except (tarfile.TarError, EOFError, OSError) as error:
    sys.exit(f"Mole: cannot extract upstream source: {error}")
PY
    [[ -f "$work/source/install.sh" && -f "$work/source/mo" ]] || fail 'Upstream source is incomplete.'
}

install_mole() {
    if installed; then printf 'Mole is already installed.\n'; return; fi
    supported || fail 'Mole is unavailable here, or an existing mo command occupies its path.'
    [[ $EUID -ne 0 ]] || fail 'Run the installer as your normal account.'
    [[ $state_root == /* ]] || fail 'The wow-kit state directory must be absolute.'
    [[ ! -e $item_dir && ! -L $item_dir ]] || fail "Existing installation files need removal first: $item_dir"
    work=$(mktemp -d "${TMPDIR:-/tmp}/wow-kit-mole.XXXXXXXX")
    created=0
    cleanup() {
        local result=$?
        trap - EXIT
        rm -rf -- "$work"
        if (( result != 0 && created )) && ! managed; then
            if own_link; then rm -f -- "$command_path"; fi
            rm -rf -- "$item_dir"
        fi
        exit "$result"
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    printf 'Downloading Mole from %s…\n' "$repository"
    checkout
    mkdir -p -- "$(dirname -- "$item_dir")" "$bin_dir"
    mkdir -- "$item_dir"
    created=1
    mkdir "$item_dir/bin"
    if [[ $system == Darwin ]]; then
        MOLE_ASSUME_SUDO_AUTH=1 PATH="$item_dir/bin:$PATH" \
            bash "$work/source/install.sh" --prefix "$item_dir/bin" --config "$item_dir/runtime" </dev/null
    else
        if ! MOLE_INSTALL_DIR="$item_dir/runtime" MOLE_BIN_DIR="$item_dir/bin" \
            bash "$work/source/install.sh" </dev/null >"$work/install.log" 2>&1; then
            cat "$work/install.log" >&2
            fail 'The upstream Mole installer failed.'
        fi
        # The upstream local installer links its checkout; keep it after staging is removed.
        mv -- "$work/source" "$item_dir/runtime"
        rm -- "$item_dir/bin/mo"
        ln -s "$item_dir/runtime/mo" "$item_dir/bin/mo"
    fi
    [[ -x "$item_dir/bin/mo" ]] || fail 'Upstream installer did not produce mo.'
    {
        printf '#!/usr/bin/env bash\n# wow-kit Mole launcher\n'
        printf 'exec %q "$@"\n' "$item_dir/bin/mo"
    } > "$launcher"
    chmod 700 "$launcher"
    python3 - "$launcher" <<'PY'
import subprocess
import sys

try:
    subprocess.run([sys.argv[1], "--help"], stdin=subprocess.DEVNULL,
                   stdout=subprocess.DEVNULL, check=True, timeout=15)
except (subprocess.SubprocessError, OSError) as error:
    sys.exit(f"Mole: installed executable could not be verified: {error}")
PY
    ln -s "$launcher" "$command_path"
    payload_present || fail 'Mole entry point could not be verified.'
    printf '%s\n%s\n' "$repository" "$revision" > "$receipt"
    printf 'Installed Mole from %s. Run mo to open it.\n' "$repository"
}

remove_mole() {
    managed || fail 'Only Mole installed by wow-kit can be removed here.'
    local archive
    mkdir -p -- "$state_root/removed"
    archive=$(mktemp -d "$state_root/removed/mole.XXXXXXXX")
    mv -- "$item_dir" "$archive/"
    if own_link; then rm -f -- "$command_path"; fi
    printf 'Removed Mole. Previous files saved in %s/mole.\n' "$archive"
}

[[ ${2:-} == mole ]] || fail 'Expected mole as the item.'
case "$action" in
    status)
        if installed; then exit 0; fi
        if managed; then exit 1; fi
        if supported; then exit 1; fi
        exit 2 ;;
    managed) managed ;;
    prerequisites) prerequisites ;;
    needs-root)
        case "$operation" in
            install) supported || fail 'Mole is unavailable here, or an existing mo command occupies its path.' ;;
            remove) ;;
            *) fail 'Expected install or remove.' ;;
        esac
        exit 1 ;;
    install) install_mole ;;
    remove) remove_mole ;;
    *) fail 'Usage: mole.sh status|managed|prerequisites|needs-root|install|remove mole' ;;
esac
