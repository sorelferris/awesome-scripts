#!/usr/bin/env bash
set -Eeuo pipefail

readonly UPSTREAM_COMMIT="f69b2756908608eef03a4bc6d1550b0a07c5a9d9"
readonly ARCHIVE_SHA256="c382214a29f5df22619a6fdeafe5038ce2dbc823d49f967baf66f6f7713ce940"
readonly ARCHIVE_URL="https://codeload.github.com/KillenMr/gnome-three-finger-drag/tar.gz/${UPSTREAM_COMMIT}"
readonly SOURCE_NAME="gnome-three-finger-drag-${UPSTREAM_COMMIT}"
readonly INSTALL_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/three-finger-drag-installer"
readonly SOURCE_DIR="$INSTALL_ROOT/$SOURCE_NAME"

usage() {
  cat <<'EOF'
Install native three-finger drag for GNOME Wayland.

Usage:
  install-three-finger-drag.sh [--dry-run]

Supported configuration: Ubuntu 26.04, GNOME Shell 50, Wayland.
EOF
}

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nError: %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  usage
  exit 0
fi
dry_run=0
if [[ "${1:-}" == --dry-run ]]; then
  dry_run=1
  shift
fi
[[ $# -eq 0 ]] || { usage >&2; exit 2; }

[[ "${XDG_SESSION_TYPE:-}" == wayland ]] || die "需要 Wayland 会话。请从 GNOME 登录界面选择 Ubuntu（Wayland）。"
[[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* ]] || die "此安装器只支持 GNOME 桌面。"
[[ -r /etc/os-release ]] || die "无法识别当前 Linux 发行版。"
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 26.04 ]] || \
  die "只验证过 Ubuntu 26.04，当前检测到 ${PRETTY_NAME:-未知系统}。"

shell_version="$(gnome-shell --version 2>/dev/null || true)"
[[ "$shell_version" =~ GNOME[[:space:]]Shell[[:space:]]50([.]|$) ]] || \
  die "只验证过 GNOME Shell 50，当前检测到 ${shell_version:-未知版本}。"

for command_name in curl tar sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || die "缺少命令：$command_name"
done

if (( dry_run )); then
  printf '环境检查通过：%s / %s / %s\n' "$PRETTY_NAME" "$shell_version" "$XDG_SESSION_TYPE"
  printf '上游提交：%s\n' "$UPSTREAM_COMMIT"
  printf 'SHA-256：%s\n' "$ARCHIVE_SHA256"
  printf '计划安装目录：%s\n' "$SOURCE_DIR"
  exit 0
fi

cat <<'EOF'
注意：此方案修改 GNOME Shell 的启动环境。完整手势目前只在 Apple Magic
Trackpad 上验证过；其他触控板即使是三指触控，也可能不支持 libinput 三指拖动。
如果图形登录失败，可按 Ctrl+Alt+F3 切换到 TTY，登录后运行：

  ~/.local/share/three-finger-drag-installer/gnome-three-finger-drag-f69b2756908608eef03a4bc6d1550b0a07c5a9d9/uninstall.sh

EOF
if [[ -t 0 || ( -t 1 && -r /dev/tty ) ]]; then
  read -r -p "输入 yes 继续安装：" answer </dev/tty
  [[ "$answer" == yes ]] || die "用户取消安装。"
elif command -v zenity >/dev/null 2>&1; then
  zenity --question --title="安装 GNOME 三指拖动" --width=540 \
    --text="此方案修改 GNOME Shell 启动环境。手势目前只在 Apple Magic Trackpad 上验证；其他触控板可能不兼容。\n\n如果桌面登录失败，可按 Ctrl+Alt+F3 登录 TTY，再运行安装目录中的 uninstall.sh。\n\n确认继续？" || die "用户取消安装。"
else
  die "非交互环境没有图形确认工具。请在终端交互运行，或安装 zenity 后重试。"
fi

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/three-finger-drag.XXXXXX")"
cleanup() { rm -rf -- "$temp_dir"; }
trap cleanup EXIT
archive="$temp_dir/source.tar.gz"

say "下载固定版本的安装源码"
curl --fail --location --retry 2 --connect-timeout 15 --output "$archive" "$ARCHIVE_URL"
printf '%s  %s\n' "$ARCHIVE_SHA256" "$archive" | sha256sum --check --status || \
  die "源码包 SHA-256 校验失败，拒绝继续。"

mkdir -p "$temp_dir/unpacked"
tar -xzf "$archive" -C "$temp_dir/unpacked" --strip-components=1
[[ -x "$temp_dir/unpacked/install.sh" && -x "$temp_dir/unpacked/build-private-libinput.sh" ]] || \
  die "下载包缺少安装所需文件。"

missing=()
for command_name in gcc make git meson ninja pkg-config readelf; do
  command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
done
for dependency in libinput libudev libevdev mtdev libwacom; do
  pkg-config --exists "$dependency" || missing+=("$dependency-dev")
done
dpkg-query -W -f='${db:Status-Status}' check 2>/dev/null | grep -qx installed || missing+=(check)
command -v getcap >/dev/null 2>&1 || missing+=(libcap2-bin)

if (( ${#missing[@]} )); then
  say "安装构建依赖：${missing[*]}"
  if [[ -t 1 ]] && command -v sudo >/dev/null 2>&1; then
    sudo -v
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends \
      build-essential git meson ninja-build pkg-config binutils \
      libinput-dev libudev-dev libevdev-dev libmtdev-dev libwacom-dev \
      check libcap2-bin
  elif command -v pkexec >/dev/null 2>&1; then
    pkexec /bin/sh -c 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends build-essential git meson ninja-build pkg-config binutils libinput-dev libudev-dev libevdev-dev libmtdev-dev libwacom-dev check libcap2-bin'
  else
    die "缺少构建依赖。请安装依赖后重新运行，或在终端中执行本脚本以使用 sudo。"
  fi
fi

mkdir -p "$INSTALL_ROOT"
if [[ -e "$SOURCE_DIR" ]]; then
  if ! diff -qr --no-dereference --exclude=.build --exclude=libenable-3fg-drag.so \
    "$temp_dir/unpacked" "$SOURCE_DIR" >/dev/null; then
    die "已存在的安装源码与校验过的固定版本不一致：$SOURCE_DIR。为避免执行被修改的代码，已停止；请检查并手动移走该目录后重试。"
  fi
else
  mv -- "$temp_dir/unpacked" "$SOURCE_DIR"
fi

say "编译并安装 GNOME 用户级三指拖动"
"$SOURCE_DIR/install.sh" --method gnome

say "检查安装状态"
"$SOURCE_DIR/status.sh"

cat <<EOF

安装完成。保存工作后注销并重新登录，GNOME Shell 才会加载新配置。

如果图形登录失败，按 Ctrl+Alt+F3 切换到 TTY，登录后运行：
  "$SOURCE_DIR/uninstall.sh"

之后检查状态：
  "$SOURCE_DIR/status.sh"

卸载：
  "$SOURCE_DIR/uninstall.sh"
  （仅适用于本工具的 GNOME 用户级安装；完成后再注销并重新登录。）
EOF
