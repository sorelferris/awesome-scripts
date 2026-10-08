#!/usr/bin/env bash
# Ubuntu / Debian：选择官方版本，编译安装到当前用户目录，保留 APT 版。
set -Eeuo pipefail
REPO=https://github.com/aristocratos/btop.git
VERSION='' DRY_RUN=0 LIST_ONLY=0 JOBS=4
BUILD_DIR='' INSTALL_DIR='' TEMP_LINK='' ACTIVATED=0
PREFIX_ROOT="$HOME/.local/opt/btop"
ENTRY="$HOME/.local/bin/btop"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/btop-installer"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/btop"

usage() {
  cat <<'EOF'
用法：install-btop.sh [选项]
默认：↑↓ 选择版本，Enter 编译安装，q / Esc 取消。
  --list             仅列出官方稳定版本标签
  --version v1.4.7   直接安装指定版本（也接受 1.4.7）
  --dry-run          选择版本并显示计划，不执行安装
  --jobs N           编译并行数，默认 4
  -h, --help         显示帮助
请用普通用户运行；安装缺失的编译依赖时会提示输入 sudo 密码。
EOF
}
fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
cleanup() {
  local status=$?
  trap - EXIT
  [[ -z "$TEMP_LINK" ]] || rm -f -- "$TEMP_LINK"
  [[ -z "$BUILD_DIR" ]] || rm -rf -- "$BUILD_DIR"
  if [[ "$ACTIVATED" == 0 && -n "$INSTALL_DIR" ]]; then rm -rf -- "$INSTALL_DIR"; fi
  if (( status != 0 && status != 130 )); then
    printf '\n操作未完成；APT 版保留，可检查报错后重试。\n' >&2
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
while (( $# )); do
  case "$1" in
    --list) LIST_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --version) [[ $# -ge 2 ]] || fail '缺少版本号'; VERSION="$2"; shift 2 ;;
    --jobs) [[ $# -ge 2 ]] || fail '缺少并行数'; JOBS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "未知参数：$1" ;;
  esac
done
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || fail '--jobs 必须是正整数'
command -v git >/dev/null || fail '请先执行 sudo apt install git'
printf '正在读取 GitHub 官方版本标签……\n'
# 使用 Git 协议查询标签，避免 GitHub 匿名 API 的频率限制。
RAW_TAGS=$(git ls-remote --tags --refs "$REPO") || fail '无法获取版本列表，请检查网络'
mapfile -t VERSIONS < <(printf '%s\n' "$RAW_TAGS" | sed -nE 's@.*refs/tags/(v[0-9]+\.[0-9]+\.[0-9]+)$@\1@p' | sort -Vu -r)
(( ${#VERSIONS[@]} )) || fail '未找到正式版本标签'
if (( LIST_ONLY )); then printf '%s\n' "${VERSIONS[@]}"; exit 0; fi

menu() {
  local selected=0 count=${#VERSIONS[@]} key extra rows height top i
  [[ ${TERM:-dumb} != dumb ]] || fail '当前终端不支持菜单，请使用 --version'
  exec 3<>/dev/tty || fail '请在终端运行，或使用 --version'
  trap 'printf "\033[0m\033[?25h\033[?1049l" >&3; exit 130' INT TERM
  printf '\033[?1049h\033[?25l' >&3
  while :; do
    rows=$(tput lines 2>/dev/null) || rows=24
    height=$(( rows > 10 ? rows - 8 : 2 ))
    (( height <= 15 )) || height=15
    top=$(( selected / height * height ))
    printf '\033[H\033[2Jbtop 官方版本安装器\n\n↑↓ 选择 · Enter 安装 · q / Esc 取消\n启用 GPU 支持（需版本 ≥ 1.3.0 和相应驱动）\n\n' >&3
    for ((i=top; i<count && i<top+height; i++)); do
      if (( i == selected )); then printf '\033[7m > %-14s\033[0m\n' "${VERSIONS[i]}" >&3
      else printf '   %-14s\n' "${VERSIONS[i]}" >&3; fi
    done
    printf '\n%d / %d\n' "$((selected+1))" "$count" >&3
    key=''; IFS= read -rsn1 key <&3 || key=q
    if [[ "$key" == $'\e' ]]; then
      extra=''; IFS= read -rsn2 -t 0.15 extra <&3 || true
      key+="$extra"
    fi
    case "$key" in
      $'\e[A'|$'\eOA'|k) selected=$(( (selected + count - 1) % count )) ;;
      $'\e[B'|$'\eOB'|j) selected=$(( (selected + 1) % count )) ;;
      '') VERSION="${VERSIONS[selected]}"; break ;;
      q|Q|$'\e') printf '\033[0m\033[?25h\033[?1049l' >&3; printf '已取消。\n'; exit 130 ;;
    esac
  done
  printf '\033[0m\033[?25h\033[?1049l' >&3
  exec 3>&-
  trap 'exit 130' INT TERM
}
if [[ -z "$VERSION" ]]; then menu; fi
[[ "$VERSION" == v* ]] || VERSION="v$VERSION"
FOUND=0
for tag in "${VERSIONS[@]}"; do [[ "$tag" != "$VERSION" ]] || FOUND=1; done
(( FOUND )) || fail '版本不在官方标签列表中，请用 --list 查看'
printf '\n所选版本：%s\n安装目录：%s\n启动入口：%s\n' "$VERSION" "$PREFIX_ROOT" "$ENTRY"
if (( DRY_RUN )); then printf '演练完成，未安装依赖或修改配置。\n'; exit 0; fi
[[ $(uname -s) == Linux ]] || fail '本脚本针对 Linux'
(( EUID != 0 )) || fail '请用普通用户运行，不要 sudo 整个脚本'
mkdir -p -- "$STATE"
exec 9>"$STATE/install.lock"
flock -n 9 || fail '另一个安装任务正在运行'
CXX_BIN=''
find_compiler() {
  local name major
  for name in g++ g++-20 g++-19 g++-18 g++-17 g++-16 g++-15 g++-14; do
    if command -v "$name" >/dev/null; then
      major=$("$name" -dumpversion)
      if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 14 )); then CXX_BIN=$(command -v "$name"); return 0; fi
    fi
  done
  return 1
}
NEEDED=()
find_compiler || NEEDED+=(g++-14)
if ! command -v make >/dev/null || ! command -v cc >/dev/null || [[ ! -f /usr/include/stdio.h ]]; then NEEDED+=(build-essential); fi
command -v lowdown >/dev/null || NEEDED+=(lowdown)
if (( ${#NEEDED[@]} )); then
  command -v apt-get >/dev/null && command -v sudo >/dev/null || fail '自动安装依赖需要 apt-get 和 sudo'
  printf '\n需要安装编译依赖：%s\n如有提示，请输入 sudo 密码。\n' "${NEEDED[*]}"
  sudo apt-get update
  sudo apt-get install -y "${NEEDED[@]}"
fi
find_compiler || fail '未找到 GCC 14+，请先安装后重试'
STAMP=$(date +%Y%m%d-%H%M%S)-$$
BACKUP="$STATE/backups/$STAMP"
if [[ -e "$CONFIG" || -e "$ENTRY" || -L "$ENTRY" ]]; then
  mkdir -p -- "$BACKUP"
  [[ ! -e "$CONFIG" ]] || cp -a -- "$CONFIG" "$BACKUP/config"
  if [[ -e "$ENTRY" || -L "$ENTRY" ]]; then cp -a -- "$ENTRY" "$BACKUP/previous-btop"; fi
  printf '备份：%s\n' "$BACKUP"
fi
[[ ! -d "$ENTRY" ]] || fail '启动入口是一个目录，无法替换'
BUILD_DIR=$(mktemp -d -t btop-build.XXXXXXXX)
git clone --depth 1 --branch "$VERSION" "$REPO" "$BUILD_DIR/source"
make -C "$BUILD_DIR/source" -j"$JOBS" "CXX=$CXX_BIN" GPU_SUPPORT=true STATIC=false
OUTPUT=$("$BUILD_DIR/source/bin/btop" --version | sed -E $'s/\\x1B\\[[0-9;]*[[:alpha:]]//g')
printf '%s\n' "$OUTPUT"
ACTUAL=$(printf '%s\n' "$OUTPUT" | sed -nE 's/.*version:?[[:space:]]*v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n1)
[[ "$ACTUAL" == "${VERSION#v}" ]] || fail '编译产物版本验证失败'
mkdir -p -- "$PREFIX_ROOT"
INSTALL_DIR=$(mktemp -d "$PREFIX_ROOT/$VERSION.XXXXXXXX")
make -C "$BUILD_DIR/source" install "CXX=$CXX_BIN" "PREFIX=$INSTALL_DIR"
"$INSTALL_DIR/bin/btop" --version
mkdir -p -- "$(dirname "$ENTRY")"
TEMP_LINK="$(dirname "$ENTRY")/.btop-install-$STAMP"
ln -s -- "$INSTALL_DIR/bin/btop" "$TEMP_LINK"
mv -Tf -- "$TEMP_LINK" "$ENTRY"
ACTIVATED=1
printf '\n安装成功：%s\n执行 hash -r 后输入 btop，或用完整路径：%s\n' "$VERSION" "$ENTRY"
printf 'APT 版保留在 /usr/bin/btop；后续更新请再次运行本脚本。\n已运行的旧版不会被关闭，请自行退出后重新启动。\n'
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) printf '请将 ~/.local/bin 加入 PATH。\n' ;; esac
