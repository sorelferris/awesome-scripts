#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} == --help ]]; then
    printf 'Usage: bash install-wow-kit.sh [--launch]\n'
    exit 0
fi
if [[ $# -gt 1 || ( $# -eq 1 && $1 != --launch ) ]]; then
    printf 'Usage: bash install-wow-kit.sh [--launch]\n' >&2
    exit 2
fi
if [[ $(id -u) == 0 ]]; then
    printf 'Run this installer as the account that will use wow-kit.\n' >&2
    exit 1
fi
if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then
    printf 'Install Python 3.8 or later, then rerun this installer.\n' >&2
    exit 1
fi
if ! python3 -c 'import curses, fcntl, termios' >/dev/null 2>&1; then
    printf 'The wow-kit menu requires a Python build with curses and Unix terminal support.\n' >&2
    exit 1
fi

umask 077
data_home=${XDG_DATA_HOME:-"$HOME/.local/share"}
case $data_home in /*) ;; *) data_home="$HOME/.local/share" ;; esac
data_home=$(python3 -c 'import os, sys; print(os.path.normpath(sys.argv[1]))' "$data_home")
kit_dir="$data_home/wow-kit"
bin_dir="$HOME/.local/bin"
launcher="$kit_dir/current/launcher"
mkdir -p "$kit_dir/versions" "$bin_dir"

for name in wo wow wow-kit; do
    target="$bin_dir/$name"
    if [[ -e $target || -L $target ]]; then
        if [[ ! -L $target || $(readlink "$target") != "$launcher" ]]; then
            printf 'The command path already exists: %s\n' "$target" >&2
            exit 1
        fi
    fi
    if existing=$(type -P "$name") && [[ $existing != "$target" ]]; then
        printf 'The command %s already resolves to %s\n' "$name" "$existing" >&2
        exit 1
    fi
done
if [[ -e $kit_dir/current && ! -L $kit_dir/current ]]; then
    printf 'The wow-kit active bundle path already exists: %s\n' "$kit_dir/current" >&2
    exit 1
fi

staging=$(mktemp -d "${TMPDIR:-/tmp}/wow-kit-bootstrap.XXXXXXXX")
trap 'rm -rf -- "$staging"' EXIT

source_dir=
if [[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]} ]]; then
    source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fi
bundle="$staging/bundle"
mkdir "$bundle"
files=(wow-kit/main.py wow-kit/ui.py wow-kit/actions.sh wow-kit/wowtype.sh scripts/install-omz.sh)

if [[ -z $source_dir || ! -f $source_dir/wow-kit/main.py ]]; then
    ref=${WOW_KIT_REF:-main}
    case $ref in
        ""|*[!a-zA-Z0-9._/-]*) printf 'Invalid WOW_KIT_REF.\n' >&2; exit 2 ;;
    esac
    url="https://raw.githubusercontent.com/sorelferris/awesome-scripts/$ref"
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        printf 'Install curl or wget to download wow-kit.\n' >&2
        exit 1
    fi
    for file in "${files[@]}"; do
        output="$bundle/${file##*/}"
        if command -v curl >/dev/null 2>&1; then
            curl -q -fsSL --proto '=https' --proto-redir '=https' --retry 2 \
                --connect-timeout 15 --max-time 60 "$url/$file" -o "$output"
        else
            wget -q --timeout=30 --tries=3 "$url/$file" -O "$output"
        fi
    done
else
    for file in "${files[@]}"; do
        install -m 600 "$source_dir/$file" "$bundle/${file##*/}"
    done
fi
cat > "$bundle/launcher" <<'LAUNCHER'
#!/usr/bin/env bash
set -e
entry=$(readlink "$0") || entry=$0
exec python3 "$(dirname "$entry")/main.py" "$@"
LAUNCHER
chmod 700 "$bundle/launcher"
python3 "$bundle/main.py" --help >/dev/null

version=$(mktemp -d "$kit_dir/versions/bundle.XXXXXXXX")
cp -p "$bundle/"* "$version/"
python3 - "$kit_dir" "$version" "$bin_dir" <<'PY'
import os
from pathlib import Path
import sys

kit, version, bin_dir = map(Path, sys.argv[1:])
current = kit / "current"
temporary = kit / (".activate-" + version.name)
temporary.symlink_to(version)
try:
    os.replace(temporary, current)
finally:
    if temporary.is_symlink():
        temporary.unlink()

for name in ("wo", "wow", "wow-kit"):
    path = bin_dir / name
    if not path.is_symlink():
        path.symlink_to(current / "launcher")
PY

add_path() {
    local file=$1
    mkdir -p "$(dirname -- "$file")"
    if [[ -e $file ]] && grep -Fqx '# >>> wow-kit PATH >>>' "$file"; then
        return
    fi
    cat >> "$file" <<'PROFILE'

# >>> wow-kit PATH >>>
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
# <<< wow-kit PATH <<<
PROFILE
}

login_profile="$HOME/.profile"
if [[ -f $HOME/.bash_profile ]]; then
    login_profile="$HOME/.bash_profile"
elif [[ -f $HOME/.bash_login ]]; then
    login_profile="$HOME/.bash_login"
fi
add_path "$login_profile"
add_path "$HOME/.bashrc"
add_path "${ZDOTDIR:-$HOME}/.zshenv"

printf 'Installed wo, wow and wow-kit in %s.\n' "$bin_dir"
if [[ ${1:-} == --launch && -t 1 ]] && { exec 3</dev/tty; } 2>/dev/null; then
    exec "$bin_dir/wo" <&3 3<&-
fi
printf 'Run %s/wo now, or open a new terminal and run wo.\n' "$bin_dir"
