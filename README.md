# awesome-scripts
Some useful scripts.

## wow-kit

在仓库根目录运行下面的命令。需要 Bash 和 Python 3.8 或更新版本。

```bash
bash scripts/install-wow-kit.sh --launch
```

安装后，新的 Bash 或 Zsh 终端可以用 `wo`、`wow` 或 `wow-kit` 进入同一个菜单。当前终端也可以直接运行 `~/.local/bin/wo`。用 ↑/↓ 移动，空格标记安装或卸载，回车预览，再按一次回车执行。用 Esc 返回或 Q 退出。

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

首版面向 Debian/Ubuntu 系 Linux 和 macOS。WowType 使用[上游发布的软件包](https://github.com/Gloridust/WowType/releases/tag/v0.4.0)，菜单会按系统版本和架构判断是否可用。无桌面会话时可以安装软件包，输入源配置需要在登录桌面后完成。

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
