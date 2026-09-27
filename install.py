#!/usr/bin/env python3
"""Install the Ukishima AI Usage extension into an existing writable checkout."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

SOURCE = Path(__file__).resolve().parent
STATE = ".ukishima-ai-usage"
ASSETS = {
    "AiUsageIsland.qml": "qml/AiUsageIsland.qml",
    "components/AiUsageRobotIcon.qml": "qml/AiUsageRobotIcon.qml",
    "surfaces/PluginsSurface.qml": "qml/PluginsSurface.qml",
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def regular_path(root, name):
    path = root / name
    for part in (path, *path.parents):
        if part == root:
            break
        if part.is_symlink():
            raise ValueError(f"Refusing symlink: {part}. Use a writable source checkout.")
    if path.exists() and not path.is_file():
        raise ValueError(f"Not a regular file: {path}")
    return path


def atomic_write(path, data, mode=None):
    fd, temporary = tempfile.mkstemp(prefix=".ai-usage-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
        os.chmod(temporary, mode if mode is not None else 0o644)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def quickshell_command():
    command = shutil.which("quickshell") or shutil.which("qs")
    if not command:
        raise ValueError("quickshell or qs was not found in PATH.")
    return command


def quickshell_instances(command, root):
    result = subprocess.run([command, "--no-color", "-p", str(root), "list", "--json"],
                            text=True, capture_output=True, check=False)
    output = result.stdout.strip()
    if result.returncode == 0 and output.startswith("["):
        return json.loads(output)
    if result.returncode == 0 and "No running instances" in output:
        return []
    detail = (result.stderr or output).strip().splitlines()
    raise ValueError("Could not query Quickshell instances"
                     + (f": {detail[0]}" if detail else "."))


def stop_ukishima(root):
    command = quickshell_command()
    instances = quickshell_instances(command, root)
    if not instances:
        return False
    print("Stopping Ukishima...")
    for instance in instances:
        result = subprocess.run([command, "--no-color", "-p", str(root), "kill",
                                 "--pid", str(instance["pid"]), "--any-display"],
                                text=True, capture_output=True, check=False)
        if result.returncode != 0:
            detail = (result.stderr or result.stdout).strip().splitlines()
            raise ValueError("Quickshell could not stop Ukishima"
                             + (f": {detail[0]}" if detail else "."))
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if not quickshell_instances(command, root):
            return True
        time.sleep(0.1)
    raise ValueError("Ukishima did not stop within five seconds; no files changed.")


def restart_ukishima(root, was_running):
    if not was_running:
        return
    launcher = root / "launch.sh"
    if not launcher.is_file():
        print("Warning: Ukishima was stopped but launch.sh was not found; restart it manually.",
              file=sys.stderr)
        return
    try:
        subprocess.Popen([str(launcher)], cwd=root, start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)
    except OSError as error:
        print(f"Warning: Ukishima was stopped but could not be restarted: {error}",
              file=sys.stderr)
        return
    print("Restarted Ukishima.")


def plan(root):
    originals, updated = {}, {}
    for change in json.loads((SOURCE / "integration.json").read_text()):
        name = change["file"]
        path = regular_path(root, name)
        if name not in originals:
            originals[name] = path.read_bytes()
            updated[name] = originals[name].decode("utf-8")
        if updated[name].count(change["old"]) != 1:
            raise ValueError(f"Incompatible or already modified Ukishima file: {name}. "
                             "Expected integration point exactly once; no files changed.")
        updated[name] = updated[name].replace(change["old"], change["new"], 1)
    for name, asset in ASSETS.items():
        if regular_path(root, name).exists():
            raise ValueError(f"Refusing to overwrite existing extension file: {name}")
        updated[name] = (SOURCE / asset).read_text()
    # A different Plugins implementation must be merged manually.
    if "pluginsOpen" in originals["Pill.qml"].decode() or "aiPluginVisibility" in originals["Singletons/Flags.qml"].decode():
        raise ValueError("An existing Plugins integration needs a manual merge.")
    return originals, {name: text.encode("utf-8") for name, text in updated.items()}


def install(root, check):
    state = root / STATE
    if state.exists() or state.is_symlink():
        raise ValueError("Installation state already exists. Uninstall before reinstalling.")
    originals, updated = plan(root)
    print("Compatible source layout. Files to install/change:")
    for name in updated:
        print(f"  {name}")
    if check:
        print("Check only: nothing changed.")
        return
    modes = {name: (root / name).stat().st_mode & 0o777 for name in originals}
    was_running = stop_ukishima(root)
    written = []
    try:
        state.mkdir(mode=0o700)
        for name, data in originals.items():
            backup = state / name
            backup.parent.mkdir(parents=True, exist_ok=True)
            backup.write_bytes(data)
        manifest = {
            "version": 1,
            "files": {name: {"installed": digest(data), "original": digest(originals[name]) if name in originals else None,
                             "mode": modes.get(name, 0o644)} for name, data in updated.items()},
        }
        (state / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        for name, data in updated.items():
            atomic_write(root / name, data, modes.get(name))
            written.append(name)
    except Exception:
        for name in reversed(written):
            if name in originals:
                atomic_write(root / name, originals[name], modes[name])
            else:
                (root / name).unlink()
        if state.exists():
            shutil.rmtree(state)
        raise
    finally:
        restart_ukishima(root, was_running)
    print("Installed. Open Settings → Plugins.")


def uninstall(root, check):
    state = root / STATE
    if state.is_symlink():
        raise ValueError("Refusing symlinked backup directory.")
    manifest = json.loads(regular_path(root, STATE + "/manifest.json").read_text())
    changes = []
    allowed = set(ASSETS) | {c["file"] for c in json.loads((SOURCE / "integration.json").read_text())}
    if manifest.get("version") != 1 or set(manifest["files"]) != allowed:
        raise ValueError("Unrecognized installation manifest.")
    for name, record in manifest["files"].items():
        path = regular_path(root, name)
        if digest(path.read_bytes()) != record["installed"]:
            raise ValueError(f"{name} changed after installation. Uninstall refused; "
                             f"merge your changes with the backup under {STATE}/ first.")
        data = None
        if record["original"] is not None:
            data = regular_path(root, STATE + "/" + name).read_bytes()
            if digest(data) != record["original"]:
                raise ValueError(f"Backup checksum mismatch: {name}")
        changes.append((path, data, record["mode"]))
    if check:
        print("Uninstall check passed: nothing changed.")
        return
    was_running = stop_ukishima(root)
    try:
        for path, data, mode in changes:
            if data is None:
                path.unlink()
            else:
                atomic_write(path, data, mode)
        shutil.rmtree(state)
    finally:
        restart_ukishima(root, was_running)
    print("Removed extension files and restored original source. User settings and "
          "agent state were retained.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["install", "uninstall"])
    parser.add_argument("--ukishima", required=True, type=Path, help="Existing writable Ukishima source directory")
    parser.add_argument("--check", action="store_true", help="Validate without writing anything")
    args = parser.parse_args()
    root = args.ukishima.expanduser().resolve()
    if not root.is_dir() or root == Path("/") or root == Path.home() or root.is_relative_to(Path("/nix/store")):
        parser.error("Use an existing writable Ukishima source checkout, not a managed store path.")
    try:
        (install if args.action == "install" else uninstall)(root, args.check)
    except (OSError, ValueError, KeyError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
