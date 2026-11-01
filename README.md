# awesome-scripts
Some useful scripts.

## GNOME three-finger drag

Install native three-finger dragging for Ubuntu 26.04, GNOME Shell 50, and Wayland:

```bash
curl -fsSL https://raw.githubusercontent.com/sorelferris/awesome-scripts/main/scripts/install-gnome-three-finger-drag.sh | bash
```

The installer pins and verifies the upstream source archive before building it. It uses a GNOME Shell-scoped preload and does not replace the system libinput library. The desktop session must be logged out and back in after installation. The feature has only been verified with an Apple Magic Trackpad; other touchpads may not support libinput three-finger dragging. If GNOME fails to start, switch to a TTY with `Ctrl`+`Alt`+`F3` and run:

```bash
~/.local/share/three-finger-drag-installer/gnome-three-finger-drag-f69b2756908608eef03a4bc6d1550b0a07c5a9d9/uninstall.sh
```
