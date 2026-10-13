#!/usr/bin/env python3
"""Reproduce the AppKit/GCD quit-loop regression with isolated, owned demo processes."""
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import time
import urllib.request

binary = Path(os.environ.get("IPHONEKIT_APP_PATH", str(Path(__file__).resolve().parents[1] / "dist/IPhoneKit.app"))) / "Contents/MacOS/IPhoneKit"
for stop_signal in (signal.SIGTERM, signal.SIGINT):
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    token = secrets.token_hex(32)
    process = subprocess.Popen([str(binary), "--demo", "--headless"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               env={**os.environ, "IPHONEKIT_PORT": str(port), "IPHONEKIT_API_KEY": token})
    try:
        endpoint = f"http://127.0.0.1:{port}/v1/phones"
        end = time.monotonic() + 15
        while time.monotonic() < end:
            assert process.poll() is None, "Demo app exited during startup"
            try:
                request = urllib.request.Request(endpoint, headers={"X-API-Key": token})
                with urllib.request.urlopen(request, timeout=0.3) as response:
                    assert json.load(response)["phones"][0]["id"] == "demo-iphone"
                break
            except (OSError, IndexError):
                time.sleep(0.05)
        else:
            raise AssertionError("Demo server did not start")
        process.send_signal(stop_signal)
        assert process.wait(timeout=8) == 0, "Graceful shutdown failed"
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
print("Owned demo processes shut down cleanly on SIGTERM and SIGINT.")
