#!/usr/bin/env bash
set -euo pipefail

version=0.4.0
release_url="https://github.com/Gloridust/WowType/releases/download/v$version"
app="$HOME/Library/Input Methods/WowType.app"
state_dir="${WOW_KIT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/wow-kit}/wowtype"
system=$(uname -s)
baseline=
arch=
asset=
digest=

fail() { printf 'WowType: %s\n' "$*" >&2; exit 2; }
note() { printf 'WowType: %s\n' "$*"; }

platform() {
    case "$system" in
        Darwin)
            local mac_version
            mac_version=$(/usr/bin/sw_vers -productVersion) || return 2
            [[ ${mac_version%%.*} =~ ^[0-9]+$ && ${mac_version%%.*} -ge 12 ]] || return 2
            case "$(uname -m)" in arm64|x86_64) ;; *) return 2 ;; esac
            asset="WowType-$version-macos.pkg"
            digest=d9151e0be67e21f753a34779778c69c39a39b3cc54b65f6a1b7da02570e6126a
            ;;
        Linux)
            [[ -x /usr/bin/apt-get && -x /usr/bin/dpkg-query && -r /etc/os-release ]] || return 2
            local id release
            id=$(awk -F= '$1 == "ID" { print $2; exit }' /etc/os-release | tr -d '"')
            release=$(awk -F= '$1 == "VERSION_ID" { print $2; exit }' /etc/os-release | tr -d '"')
            case "$id:$release" in
                ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) baseline="ubuntu$release" ;;
                debian:13|debian:13.*) baseline=debian13 ;;
                deepin:23|deepin:23.*|Deepin:23|Deepin:23.*) baseline=deepin23 ;;
                deepin:25|deepin:25.*|Deepin:25|Deepin:25.*) baseline=deepin25 ;;
                *) return 2 ;;
            esac
            arch=$(/usr/bin/dpkg --print-architecture) || return 2
            asset="wowtype_${version}_${baseline}_${arch}.deb"
            # Digests from https://github.com/Gloridust/WowType/releases/expanded_assets/v0.4.0.
            case "$baseline:$arch" in
                ubuntu22.04:amd64) digest=e4f78b85443a78adea48cf72e432927d6c06d2106ee44e8457abd5c4114974f6 ;;
                ubuntu22.04:arm64) digest=749b029850adef677667716d34ed4cad7ed179c3097727a7b522225534319031 ;;
                ubuntu24.04:amd64) digest=3251f6d72143d54c893ee9937d282beddc2e4fb9944cb2336434770e63475587 ;;
                ubuntu24.04:arm64) digest=92c025601fca36a969828176c328c4f7b6c02f9bb4279a0a626e2a20e98c7cf1 ;;
                ubuntu26.04:amd64) digest=e2141d2072bebc03a00e9ddfb726ce8c01d698bc02e05c24b8ca561ae6cec1f6 ;;
                ubuntu26.04:arm64) digest=8d39a99e86fd8cc0c5c0afd284c7482f62607f308e95666a79d097140ff79b9f ;;
                debian13:amd64) digest=ba2b7f72de4fb82a8be2062b3f317133a40b4bc5f1ac220b23d516df1d9bb864 ;;
                debian13:arm64) digest=7db4c6727ce78d77560bf65f520b6b8912bb6be883a56de7987754daa1681b6b ;;
                deepin23:amd64) digest=9c769b86792ddf94c0c1e9fc5f5892ab30ea7ae5b1c1e416660bfbd3cf820cf7 ;;
                deepin25:amd64) digest=524b89097f2dbddeca4a9cd54b4973bfcf126b730bb3b657e6bed35c1ff6c1a0 ;;
                *) return 2 ;;
            esac
            ;;
        *) return 2 ;;
    esac
}

debian_installed() {
    [[ $(/usr/bin/dpkg-query -W -f='${db:Status-Status}' wowtype 2>/dev/null) == installed ]]
}

installed() {
    if [[ $system == Darwin ]]; then
        [[ -d "$app" || -d '/Library/Input Methods/WowType.app' ]]
    else
        debian_installed || [[ -f /usr/share/fcitx5/inputmethod/wowtype.conf ]] ||
            command -v wowtype-config >/dev/null
    fi
}

managed() {
    [[ -f "$state_dir/installed" && $(cat "$state_dir/installed") == "$system" ]]
}

root_run() {
    if [[ $EUID -eq 0 ]]; then "$@" </dev/null; else /usr/bin/sudo -n "$@" </dev/null; fi
}

in_desktop() {
    [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" && -n ${DBUS_SESSION_BUS_ADDRESS:-} ]]
}

configure_fcitx() {
    if ! in_desktop; then
        note '在桌面终端运行 wowtype-config --add-to-group --restart，将 WowType 加入 Fcitx 5。'
        return
    fi
    # Keep any explicit framework choice. When there is none, im-config can select Fcitx 5.
    local config="$HOME/.xinputrc"
    if [[ -x /usr/bin/im-config && $baseline != deepin* && ! -e $config && ! -L $config ]] &&
       /usr/bin/im-config -n fcitx5 </dev/null; then
        if [[ -f $config && ! -L $config ]]; then
            cp -p "$config" "$state_dir/xinputrc"
            note '已设置 Fcitx 5 输入法框架。桌面输入法框架的变更会在重新登录后生效。'
        fi
    elif [[ $baseline != deepin* && -e $config && ${XMODIFIERS:-} != '@im=fcitx' ]]; then
        note '已保留原有输入法框架设置。需要时可在桌面中启用 Fcitx 5。'
    fi
    if ! /usr/bin/wowtype-config --add-to-group --restart </dev/null; then
        note '安装包已就绪。请重新登录，再通过 Fcitx 5 配置添加 WowType。'
    fi
}

install_wowtype() {
    if installed; then
        note '输入法已安装。'
        return
    fi
    command -v curl >/dev/null || fail '需要 curl。'
    mkdir -p "$state_dir"
    local temp_dir package actual install_status=0
    temp_dir=$(mktemp -d /tmp/wow-kit-wowtype.XXXXXX)
    trap "rm -rf -- '$temp_dir'" EXIT
    package="$temp_dir/$asset"
    note "正在下载 $asset"
    curl -q --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --retry 2 --connect-timeout 15 --max-time 180 --output "$package" "$release_url/$asset"
    if [[ $system == Darwin ]]; then
        actual=$(/usr/bin/shasum -a 256 "$package")
    else
        actual=$(/usr/bin/sha256sum "$package")
    fi
    [[ ${actual%% *} == "$digest" ]] || fail '安装包 SHA-256 与官方发布记录不匹配。'

    if [[ $system == Darwin ]]; then
        [[ $EUID -ne 0 ]] || fail '请以当前桌面用户身份安装。'
        /usr/sbin/installer -pkg "$package" -target CurrentUserHomeDirectory </dev/null || install_status=$?
        [[ -x "$app/Contents/MacOS/WowType" ]] || fail '没有找到当前用户的 WowType 输入法。'
    else
        local -a extra
        case "$baseline" in
            ubuntu22.04) extra=(fcitx5-config-qt fcitx5-frontend-gtk3 fcitx5-frontend-gtk4 fcitx5-frontend-qt5 im-config) ;;
            deepin*) extra=(fcitx5-frontend-all) ;;
            *) extra=(fcitx5-config-qt fcitx5-frontend-all im-config) ;;
        esac
        chmod 755 "$temp_dir"
        chmod 644 "$package"
        root_run /usr/bin/apt-get -q update || note '更新软件源失败，使用现有软件包索引。'
        root_run /usr/bin/env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
            /usr/bin/apt-get -y --no-remove -o DPkg::Lock::Timeout=60 \
            -o Dpkg::Options::=--force-confold install "$package" \
            "${extra[@]}" python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 || install_status=$?
        debian_installed || fail '系统没有登记 WowType 软件包。'
    fi

    printf '%s\n' "$system" > "$state_dir/installed"
    if [[ $system == Linux ]]; then configure_fcitx; fi
    return "$install_status"
}

remove_wowtype() {
    managed || fail '只卸载由 wow-kit 安装的 WowType。'
    if [[ $system == Darwin ]]; then
        if [[ -d $app ]]; then
            [[ ! -L $app && -x "$app/Contents/MacOS/WowType" ]] || fail '当前用户的 WowType 安装不完整。'
            # The v0.4.0 macos/install.sh uses --disable and removes the per-user bundle.
            "$app/Contents/MacOS/WowType" --disable </dev/null || note '输入源会在重新登录后刷新。'
            /usr/bin/pkill -TERM -u "$EUID" -x WowType 2>/dev/null || true
            rm -rf -- "$app"
            [[ ! -e $app && ! -L $app ]] || fail '未能移除当前用户的 WowType。'
        fi
    else
        if debian_installed; then
            # Removing exactly one package avoids APT choosing additional packages to remove.
            root_run /usr/bin/env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l /usr/bin/dpkg --remove wowtype
            debian_installed && fail 'WowType 软件包仍然存在。'
        fi
        local config="$HOME/.xinputrc"
        if [[ -f "$state_dir/xinputrc" && -f $config && ! -L $config ]] &&
           cmp -s "$state_dir/xinputrc" "$config"; then
            rm -- "$config"
            note '恢复了原有的系统输入法框架选择，重新登录后生效。'
        fi
        # Fcitx filters missing input methods from its groups on start.
        if in_desktop && [[ ${XDG_CURRENT_DESKTOP:-} != *KDE* || ${XDG_SESSION_TYPE:-} != wayland ]] &&
           command -v busctl >/dev/null &&
           busctl --user --auto-start=no --timeout=3s call org.fcitx.Fcitx5 /controller \
               org.fcitx.Fcitx.Controller1 Restart >/dev/null 2>&1; then
            note '已通知 Fcitx 5 重启。'
        else
            note 'Fcitx 5 会在下次登录时更新输入法列表。'
        fi
    fi
    rm -f -- "$state_dir/installed" "$state_dir/xinputrc"
    rmdir -- "$state_dir" 2>/dev/null || true
}

[[ ${2:-} == wowtype ]] || fail '需要 wowtype 作为目标。'
case ${1:-} in
    status)
        if installed; then exit 0; fi
        platform
        exit 1
        ;;
    managed) managed ;;
    needs-root)
        [[ ${3:-} == install || ${3:-} == remove ]] || exit 2
        platform
        [[ $system == Linux && $EUID -ne 0 ]] || exit 1
        [[ -x /usr/bin/sudo ]] || fail '系统没有可用的 sudo。'
        ;;
    install) platform || fail '当前平台不在预编译包支持范围内。'; install_wowtype ;;
    remove) platform || fail '当前平台不在预编译包支持范围内。'; remove_wowtype ;;
    *) fail '用法：wowtype.sh status|managed|needs-root|install|remove wowtype' ;;
esac
