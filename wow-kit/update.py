"""Update an installed wow-kit using a single published GitHub commit."""

import fcntl
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import tempfile


REPOSITORY = "sorelferris/awesome-scripts"
REF = "refs/heads/main"
REF_URL = f"https://api.github.com/repos/{REPOSITORY}/git/ref/heads/main"
ARCHIVE_URL = f"https://codeload.github.com/{REPOSITORY}/tar.gz"


def download(url, destination):
    curl = shutil.which("curl")
    wget = shutil.which("wget")
    headers = ("Accept: application/vnd.github+json", "Cache-Control: no-cache") if url == REF_URL else ()
    if curl:
        command = [curl, "-q", "-fsSL", "--proto", "=https", "--proto-redir", "=https",
                   "--retry", "2", "--connect-timeout", "15", "--max-time", "90"]
        for header in headers:
            command.extend(("--header", header))
        command.extend(("--output", str(destination), url))
    elif wget:
        command = [wget, "-q", "--https-only", "--timeout=30", "--tries=3"]
        command.extend(f"--header={header}" for header in headers)
        command.extend(("-O", str(destination), url))
    else:
        raise ValueError("Install curl or wget before updating wow-kit.")

    if subprocess.run(command, stdin=subprocess.DEVNULL).returncode:
        raise ValueError("Could not download the wow-kit update from GitHub.")


def latest_revision(metadata):
    download(REF_URL, metadata)
    try:
        reference = json.loads(metadata.read_text(encoding="utf-8"))
        commit = reference["object"]
        revision = commit["sha"]
        if reference["ref"] == REF and commit["type"] == "commit" and re.fullmatch("[a-f0-9]{40}", revision):
            return revision
    except (KeyError, TypeError, ValueError):
        pass
    raise ValueError("GitHub did not return a valid commit for main.")


def unpack_checkout(archive, destination, revision):
    tree_name = f"awesome-scripts-{revision}"
    try:
        with tarfile.open(archive, "r:gz") as source:
            for member in source:
                parts = PurePosixPath(member.name).parts
                if not parts or parts[0] != tree_name or ".." in parts:
                    raise ValueError("Unexpected path in the GitHub archive.")
                if len(parts) < 3 or parts[1] not in ("wow-kit", "scripts") or not member.isfile():
                    continue
                target = destination.joinpath(*parts[1:])
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(member) as contents, target.open("xb") as output:
                    shutil.copyfileobj(contents, output)
    except (tarfile.TarError, EOFError) as exc:
        raise ValueError("The GitHub archive could not be read.") from exc

    installer = destination / "scripts/install-wow-kit.sh"
    if not installer.is_file():
        raise ValueError("The latest commit does not include the wow-kit installer.")
    return installer


def active_bundle(installation):
    current = installation / "current"
    if current.is_symlink():
        bundle = current.resolve()
        if bundle.parent == installation / "versions" and bundle.is_dir():
            return bundle
    raise ValueError("Could not find the active wow-kit installation.")


def update_installed(bundle):
    if os.geteuid() == 0:
        raise ValueError("Run wo update as the account that installed wow-kit.")
    installation = bundle.parent.parent
    if bundle.parent.name != "versions" or installation.name != "wow-kit":
        raise ValueError("Install wow-kit first, then run wo update from your terminal.")

    with (installation / ".update.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("Another wow-kit update is already running.") from None

        current = active_bundle(installation)
        with tempfile.TemporaryDirectory(prefix="wow-kit-update-") as directory:
            work = Path(directory)
            print("Checking GitHub main for wow-kit updates…", flush=True)
            revision = latest_revision(work / "main.json")
            marker = current / "revision"
            if marker.is_file() and marker.read_text(encoding="utf-8").strip() == revision:
                print(f"wow-kit is already up to date ({revision[:12]}).")
                return 0

            print(f"Downloading wow-kit {revision[:12]}…", flush=True)
            archive = work / "source.tar.gz"
            download(f"{ARCHIVE_URL}/{revision}", archive)
            installer = unpack_checkout(archive, work / "checkout", revision)
            # The new revision's installer selects its own bundle files.
            command = ["/bin/bash", str(installer), "--update", str(installation), revision]
            if subprocess.run(command, stdin=subprocess.DEVNULL).returncode:
                raise ValueError("Could not prepare the new wow-kit version.")
    return 0
