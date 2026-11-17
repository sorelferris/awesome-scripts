# awesome-scripts
Some useful scripts.

## wow-kit

在仓库根目录运行下面的命令。需要 Bash 和 Python 3.8 或更新版本。

```bash
bash scripts/install-wow-kit.sh --launch
```

安装后，新的 Bash 或 Zsh 终端可以用 `wo`、`wow` 或 `wow-kit` 进入同一个菜单。当前终端也可以直接运行 `~/.local/bin/wo`。在支持颜色的终端里，已安装项显示为绿色。用 ↑/↓ 移动，空格标记安装或卸载，回车预览，再按一次回车执行。用 Esc 返回或 Q 退出。

如果没有本地检出，可以直接运行下面的命令。

```bash
curl -fsSL https://raw.githubusercontent.com/sorelferris/awesome-scripts/main/scripts/install-wow-kit.sh | bash -s -- --launch
```

菜单包含 curl、wget、Git 和 Zsh，Oh My Zsh（steeef 主题、自动建议和语法高亮），Zsh 登录 Shell，nvm + Node.js 24，Miniforge3、uv、Pixi、Rust、advcpmv 和 WowType 拼音。菜单会标出当前平台不支持的项目，也会显示外部工具安装的已有软件。这些已有软件的卸载由原安装工具管理。

卸载由 wow-kit 管理的 Oh My Zsh、Node.js、Miniforge3 或 Rust 时，原安装目录会移到状态目录的 `removed/` 下，供找回自定义插件、全局包或环境。卸载 WowType 保留个人词库。

```bash
wo --list
wo --install essentials                # Oh My Zsh、Node.js、Miniforge3、uv
wo --install node --node-version 22
wo --install wowtype --no-prompt
wo --remove uv pixi
```

需要管理员权限的操作会在执行计划前统一认证一次。之后安装器禁用交互输入，系统软件包操作用 `sudo -n`。用于脚本或无人值守时可加 `--no-prompt`，先在同一终端运行 `sudo -v`，或由管理员事先授权。wow-kit 使用系统现有的 sudo 策略。

### wow-kit 本体

终端菜单需要 Bash 和 Python 3.8 或更新版本，并要求 Python 提供 `curses`、`fcntl` 和 `termios`。本体按这些运行条件判断兼容性，系统版本和架构还会影响各个工具的可用性。

| 平台 | 系统版本 | 架构与依赖 |
| --- | --- | --- |
| Ubuntu、Debian 及其他 APT 系 Linux | 满足上述运行条件的版本 | CLI 本体无固定架构限制，各工具按架构和依赖判断。系统依赖可通过 APT 补齐。 |
| macOS | 满足上述运行条件的版本 | Apple Silicon（arm64）与 Intel（x86_64）。如已安装 Homebrew，可用它补齐系统依赖。 |
| 其他 Linux 发行版 | 满足上述运行条件的版本 | CLI 本体无固定架构限制。可用工具取决于架构和已安装的依赖。 |

### WowType 拼音

下表列出通过 `wo` 自动安装 WowType v0.4.0 的范围。Linux 上没有桌面会话时也可以安装软件包，输入源配置在登录桌面后完成。[上游软件包](https://github.com/Gloridust/WowType/releases/tag/v0.4.0)

| 平台 | 系统版本 | 架构 |
| --- | --- | --- |
| macOS | 12 及以上 | Apple Silicon（arm64）、Intel（x86_64） |
| Ubuntu | 22.04、24.04、26.04 LTS | amd64、arm64 |
| Debian | 13 | amd64、arm64 |
| deepin | 23、25 | amd64 |

### 实测记录

| 平台 | 架构 | wow-kit 本体的实测范围 |
| --- | --- | --- |
| Ubuntu 24.04.4 LTS（`mola`） | amd64 | 从 GitHub 提交归档安装，打开终端菜单，并在新登录会话验证 `wo`、`wow`、`wow-kit`。 |
| macOS 27.2.1 | arm64 | 从本地检出安装和重复安装，验证三个入口及终端菜单。 |

WowType 的安装和卸载在模拟的 Ubuntu 24.04（amd64）和 macOS（arm64）环境中验证过，真实桌面上的自动安装和输入源配置尚待实测。

## Cheatsheets

- [Infrastructure and app naming cheatsheet](naming_cheatsheet.html) — browse themed names and copy hostname patterns.

## GNOME three-finger drag

Install native three-finger dragging for Ubuntu 26.04, GNOME Shell 50, and Wayland:

```bash
curl -fsSL https://raw.githubusercontent.com/sorelferris/awesome-scripts/main/scripts/install-gnome-three-finger-drag.sh | bash
```

The installer pins and verifies the upstream source archive before building it. It uses a GNOME Shell-scoped preload and does not replace the system libinput library. The desktop session must be logged out and back in after installation. The feature has only been verified with an Apple Magic Trackpad; other touchpads may not support libinput three-finger dragging. If GNOME fails to start, switch to a TTY with `Ctrl`+`Alt`+`F3` and run:

```bash
~/.local/share/three-finger-drag-installer/gnome-three-finger-drag-f69b2756908608eef03a4bc6d1550b0a07c5a9d9/uninstall.sh
```
