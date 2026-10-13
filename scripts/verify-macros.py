#!/usr/bin/env python3
"""Verify recording, persistence, approval, and playback in an isolated offline demo."""
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import stat
import subprocess
import tempfile
import time


def fingerprint(path):
    try:
        info = path.stat()
        return info.st_ino, info.st_size, info.st_mtime_ns, stat.S_IMODE(info.st_mode)
    except FileNotFoundError:
        return None


binary = Path(os.environ.get("IPHONEKIT_APP_PATH", str(Path(__file__).resolve().parents[1] / "dist/IPhoneKit.app"))) / "Contents/MacOS/IPhoneKit"
assert binary.is_file(), "Build the app first with scripts/build-app.sh"
temporary = Path(tempfile.gettempdir())
temporary_mode = stat.S_IMODE(temporary.stat().st_mode)
other_stores = [temporary / "iphonekit-demo/macros.json",
                Path.home() / "Library/Application Support/iPhoneKit/macros.json"]
originals = {path: fingerprint(path) for path in other_stores}
with tempfile.TemporaryDirectory(prefix="iphonekit-macro-check-") as name:
    directory = Path(name)
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    process = subprocess.Popen(
        [str(binary), "--demo", "--macro-self-test"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        env={**os.environ, "IPHONEKIT_PORT": str(port), "IPHONEKIT_API_KEY": secrets.token_hex(32),
             "IPHONEKIT_MACRO_TEST_DIRECTORY": str(directory)},
    )
    try:
        report_path = directory / "report.json"
        deadline = time.monotonic() + 45
        while not report_path.exists():
            assert process.poll() is None, "Demo app exited before producing its report"
            assert time.monotonic() < deadline, "Macro verification timed out"
            time.sleep(0.05)
        report = json.loads(report_path.read_text())
        expected = {"state": "completed", "offline": True, "steps": 2, "actions": 4,
                    "approvals": 2, "saved_profiles": 1, "reloaded_profiles": 1}
        for key, value in expected.items():
            assert report.get(key) == value, f"Unexpected {key}: {report}"
        store = directory / "macros.json"
        saved = json.loads(store.read_text())
        assert saved["version"] == 1 and len(saved["profiles"]) == 1, "Invalid saved profile envelope"
        assert len(saved["profiles"][0]["steps"]) == 2, "Recorded steps did not persist"
        assert stat.S_IMODE(directory.stat().st_mode) == 0o700, "Macro directory is not private"
        assert stat.S_IMODE(store.stat().st_mode) == 0o600, "Macro file is not private"
        assert stat.S_IMODE(temporary.stat().st_mode) == temporary_mode, "Shared temp permissions changed"
        for path, original in originals.items():
            assert fingerprint(path) == original, f"Unrelated macro store changed: {path}"
        process.send_signal(signal.SIGTERM)
        assert process.wait(timeout=8) == 0, "Graceful shutdown failed"
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
print("Offline macros passed: 2 recorded steps, 4 verified actions, 2 approvals, private save/reload, clean shutdown.")
