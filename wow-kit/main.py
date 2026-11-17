#!/usr/bin/env python3
"""Catalog, review and unattended execution for wow-kit."""

import argparse
import fcntl
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import threading
from dataclasses import dataclass


HERE = Path(__file__).resolve().parent
CATALOG = {
    "system-tools": ("System tools", "curl, wget, Git and Zsh"),
    "omz": ("Oh My Zsh", "steeef theme, suggestions and syntax highlighting"),
    "zsh-shell": ("Zsh login shell", "Use Zsh for new login sessions"),
    "node": ("nvm + Node.js", "Node.js and npm with nvm"),
    "conda": ("Miniforge3", "Conda with Bash and Zsh initialization"),
    "uv": ("uv", "Python package and project manager"),
    "pixi": ("Pixi", "Package and environment manager"),
    "rust": ("Rust", "Rustup, Rust and Cargo"),
    "advcpmv": ("advcpmv", "cpg and mvg with progress, plus Zsh aliases"),
    "wowtype": ("WowType", "WowType Pinyin input method"),
}
ESSENTIALS = ("omz", "node", "conda", "uv")


@dataclass(frozen=True)
class Action:
    key: str
    verb: str
    root: bool
    prerequisites: tuple

    def label(self):
        label = "Install" if self.verb == "install" else "Uninstall"
        line = f"{label}  {CATALOG[self.key][0]}"
        if self.prerequisites:
            line += "  (needs " + ", ".join(self.prerequisites) + ")"
        return line


class Kit:
    def __init__(self, options):
        self.options = options
        state_home = Path(os.environ.get("XDG_STATE_HOME", ""))
        if not state_home.is_absolute():
            state_home = Path.home() / ".local/state"
        self.state = state_home / "wow-kit"
        self.env = os.environ.copy()
        self.env.update(
            WOW_KIT_STATE_DIR=str(self.state),
            WOW_KIT_NODE_VERSION=options.node_version,
            GIT_TERMINAL_PROMPT="0",
            GIT_ASKPASS="/usr/bin/false",
            SSH_ASKPASS="/usr/bin/false",
            CI="1",
        )

    def command(self, op, key, *args):
        backend = "wowtype.sh" if key == "wowtype" else "actions.sh"
        return ["bash", str(HERE / backend), op, key, *args]

    def probe(self, op, key, *args):
        return subprocess.run(
            self.command(op, key, *args),
            env=self.env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    def items(self):
        items = []
        for key, (label, description) in CATALOG.items():
            status = self.probe("status", key)
            if status.returncode not in (0, 1, 2):
                raise ValueError(f"Could not detect {label}: {status.stderr.strip()}")
            installed = status.returncode == 0
            managed = self.probe("managed", key).returncode == 0
            items.append(dict(key=key, label=label, description=description,
                              installed=installed, managed=managed,
                              incomplete=managed and not installed,
                              available=status.returncode != 2))
        return items

    def plan(self, items, keys, verb=None):
        entries = {item["key"]: item for item in items}
        operations = {}
        for key in keys:
            entry = entries[key]
            name = entry["label"]
            if not entry["available"]:
                raise ValueError(f"{name} is unavailable on this system.")
            operation = verb or ("remove" if entry["installed"] or entry["incomplete"] else "install")
            if operation == "remove":
                if not entry["installed"] and not entry["incomplete"]:
                    continue
                if not entry["managed"]:
                    raise ValueError(f"{name} is installed outside wow-kit. Use its original installer to remove it.")
            elif entry["installed"]:
                continue
            elif entry["incomplete"]:
                raise ValueError(f"Remove the incomplete {name} installation before reinstalling.")
            operations[key] = operation

        if operations.get("system-tools") == "remove" and "install" in operations.values():
            raise ValueError("Keep system tools installed while installing other items.")
        if operations.get("wowtype") == "install" and not shutil.which("curl"):
            if not entries["system-tools"]["available"] or entries["system-tools"]["installed"]:
                raise ValueError("Install curl before installing WowType.")
            operations["system-tools"] = "install"

        order = [key for key in reversed(CATALOG) if operations.get(key) == "remove"]
        order += [key for key in CATALOG if operations.get(key) == "install"]
        actions = []
        for key in order:
            operation = operations[key]
            check = self.probe("needs-root", key, operation)
            if check.returncode not in (0, 1):
                raise ValueError(check.stderr.strip() or f"Could not prepare {CATALOG[key][0]}.")
            prerequisites = ()
            if operation == "install" and key != "wowtype":
                missing = self.probe("prerequisites", key)
                if missing.returncode:
                    raise ValueError(missing.stderr.strip() or f"Could not check prerequisites for {CATALOG[key][0]}.")
                prerequisites = tuple(missing.stdout.split())
            actions.append(Action(key, operation, check.returncode == 0, prerequisites))
        return actions

    def apply(self, reviewed, keys, verb=None):
        if not reviewed:
            print("Nothing to do.")
            return 0
        if os.geteuid() == 0:
            raise ValueError("Run wow-kit as the account receiving the software.")
        self.state.mkdir(mode=0o700, parents=True, exist_ok=True)
        with (self.state / "lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ValueError("Another wow-kit batch is running.") from None
            if self.plan(self.items(), keys, verb) != reviewed:
                raise ValueError("The installed items changed since review. Run wow-kit to review the new plan.")

            for action in reviewed:
                print(action.label(), flush=True)
            needs_root = any(action.root for action in reviewed)
            stop = threading.Event()
            worker = None
            if needs_root:
                sudo = authenticate(self.options.no_prompt)
                worker = threading.Thread(target=refresh_sudo, args=(sudo, stop), daemon=True)
                worker.start()

            completed = []
            try:
                for action in reviewed:
                    print(f"\n==> {action.label()}", flush=True)
                    result = subprocess.run(self.command(action.verb, action.key),
                                            env=self.env, stdin=subprocess.DEVNULL)
                    if result.returncode:
                        raise ValueError(f"{action.label()} failed (exit {result.returncode}). "
                                         f"Completed: {', '.join(completed) or 'none'}.")
                    completed.append(CATALOG[action.key][0])
            finally:
                stop.set()
                if worker:
                    worker.join()
            print("\nCompleted all selected actions.")
            return 0


def authenticate(no_prompt):
    sudo = next((path for path in ("/usr/bin/sudo", "/bin/sudo") if os.access(path, os.X_OK)), None)
    if sudo is None:
        raise ValueError("This plan requires administrator access and sudo is unavailable.")
    if subprocess.run([sudo, "-n", "-v"], stdin=subprocess.DEVNULL,
                      capture_output=True).returncode:
        if no_prompt or not sys.stdin.isatty():
            raise ValueError("This plan needs sudo authorization. Run sudo -v in the same terminal first.")
        print("Authorize administrator access once before this batch starts.", flush=True)
        if subprocess.run([sudo, "-v"]).returncode:
            raise ValueError("Administrator authorization failed.")
    # A per-parent sudo timestamp validated here may be unusable in a backend.
    if subprocess.run(["/bin/bash", "-c", '"$1" -n -v; exit $?', "wow-kit", sudo],
                      stdin=subprocess.DEVNULL, capture_output=True).returncode:
        raise ValueError("The sudo policy does not allow authorization to be reused for a batch.")
    return sudo


def refresh_sudo(sudo, stop):
    while not stop.wait(15):
        try:
            result = subprocess.run([sudo, "-n", "-v"], stdin=subprocess.DEVNULL,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        except subprocess.TimeoutExpired:
            return
        if result.returncode:
            return


def list_items(items):
    for item in items:
        status = "unavailable"
        if item["available"]:
            status = "available"
        if item["installed"]:
            status = "installed" if item["managed"] else "installed externally"
        elif item["incomplete"] and item["available"]:
            status = "incomplete"
        print(f'{item["key"]:14} {status:21} {item["label"]}')


def main():
    parser = argparse.ArgumentParser(prog="wow-kit", description="Install and remove everyday tools.")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--list", action="store_true", help="list tools and their installed status")
    modes.add_argument("--install", nargs="+", metavar="ITEM",
                       choices=(*CATALOG, "essentials", "all"), help="install items, essentials, or all supported items")
    modes.add_argument("--remove", nargs="+", metavar="ITEM", choices=tuple(CATALOG), help="remove wow-kit managed items")
    parser.add_argument("--node-version", default="24", help="Node.js version for nvm (default: 24)")
    parser.add_argument("--no-prompt", action="store_true", help="require pre-authorized sudo instead of prompting")
    options = parser.parse_args()
    if not re.fullmatch(r"v?[0-9]+(?:\.[0-9]+){0,2}|lts/(?:[a-z]+|\*)", options.node_version):
        parser.error("--node-version expects a version like 24 or 24.1.0, or lts/*")

    kit = Kit(options)
    items = kit.items()
    if options.install:
        keys = set(options.install)
        if "essentials" in keys:
            keys.remove("essentials")
            keys.update(ESSENTIALS)
        if "all" in keys:
            keys.remove("all")
            keys.update(item["key"] for item in items if item["available"])
        return kit.apply(kit.plan(items, keys, "install"), keys, "install")
    if options.remove:
        return kit.apply(kit.plan(items, options.remove, "remove"), options.remove, "remove")
    if options.list or not (sys.stdin.isatty() and sys.stdout.isatty()):
        list_items(items)
        return 0

    import ui

    reviewed = []

    def describe_plan(keys):
        reviewed[:] = kit.plan(items, keys)
        labels = [action.label() for action in reviewed]
        if any(action.root for action in reviewed):
            labels.append("Administrator access is required before starting.")
        return labels

    try:
        keys = ui.select(items, describe_plan=describe_plan)
    except ui.SelectionError as exc:
        raise ValueError(f"{exc} Use --list or --install in this terminal.") from None
    return kit.apply(reviewed, keys) if keys else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError) as exc:
        print(f"wow-kit: {exc}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nwow-kit: cancelled", file=sys.stderr)
        sys.exit(130)
