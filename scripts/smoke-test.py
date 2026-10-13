#!/usr/bin/env python3
"""Exercise real REST and stdio MCP front doors. Start iPhoneKit --demo first."""
import base64
import json
import os
from pathlib import Path
import select
import stat
import subprocess
import time
import urllib.request
import urllib.error

port = os.environ.get("IPHONEKIT_PORT", "8766")
base = f"http://127.0.0.1:{port}"
token_path = Path.home() / "Library/Application Support/iPhoneKit/api-token"
token = os.environ.get("IPHONEKIT_API_KEY") or token_path.read_text().strip()
if "IPHONEKIT_API_KEY" not in os.environ:
    assert stat.S_IMODE(token_path.stat().st_mode) == 0o600


def call(path, body=None, auth=True, headers=None):
    fields = dict(headers or {})
    if auth:
        fields["X-API-Key"] = token
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        fields["Content-Type"] = "application/json"
    request = urllib.request.Request(base + path, data=data, headers=fields)
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as response:
        return response.code, json.load(response)


assert call("/health", auth=False)[0] == 200
assert call("/v1/phones", auth=False)[0] == 401
assert call("/v1/phones", headers={"Origin": "null"})[0] == 403
phones = call("/v1/phones")[1]["phones"]
assert len(phones) == 1 and phones[0]["id"] == "demo-iphone", "Start the app with --demo."
phone = phones[0]["id"]
status, shot = call(f"/v1/phones/{phone}/screenshot")
assert status == 200 and shot["height"] == 1344
assert base64.b64decode(shot["jpeg"]).startswith(b"\xff\xd8")
assert call(f"/v1/phones/{phone}/tap", {"x": 50, "y": 100})[0] == 400
command = {"x": 50, "y": 100, "screenshot_id": shot["id"], "idempotency_key": "smoke-" + str(time.time_ns())}
status, first = call(f"/v1/phones/{phone}/tap", command)
assert status == 200 and first["status"] == "simulated"
assert call(f"/v1/phones/{phone}/tap", command)[1]["id"] == first["id"]
assert call(f"/v1/phones/{phone}/type-text", {"text": "café"})[0] == 400
assert call(f"/v1/phones/{phone}/press-home", {})[0] == 200
root = Path(__file__).resolve().parents[1]
helper = Path(os.environ.get("IPHONEKIT_APP_PATH", str(root / "dist/IPhoneKit.app"))) / "Contents/MacOS/iphonekit-mcp"
process = subprocess.Popen([str(helper)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                           env={**os.environ, "IPHONEKIT_PORT": port})


def rpc(identifier, method, params=None):
    message = {"jsonrpc": "2.0", "id": identifier, "method": method}
    if params is not None:
        message["params"] = params
    process.stdin.write(json.dumps(message) + "\n")
    process.stdin.flush()
    ready, _, _ = select.select([process.stdout], [], [], 15)
    assert ready, "MCP did not reply"
    reply = json.loads(process.stdout.readline())
    assert reply["id"] == identifier and "error" not in reply, "MCP protocol error"
    return reply["result"]


try:
    initialization = rpc(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}})
    assert initialization["serverInfo"]["name"] == "iPhoneKit"
    tools = rpc(2, "tools/list")["tools"]
    assert {"list_phones", "screenshot", "tap", "flick", "drag", "press_home", "type_text", "cancel_action"} <= {t["name"] for t in tools}
    assert "screenshot_id" in next(t for t in tools if t["name"] == "tap")["inputSchema"]["required"]
    assert phone in rpc(3, "tools/call", {"name": "list_phones", "arguments": {}})["content"][0]["text"]
    screenshot = rpc(4, "tools/call", {"name": "screenshot", "arguments": {"phone_id": phone}})
    assert screenshot["content"][0]["mimeType"] == "image/jpeg"
    metadata = json.loads(screenshot["content"][1]["text"])
    tapped = rpc(5, "tools/call", {"name": "tap", "arguments": {"phone_id": phone, "x": 20, "y": 30, "screenshot_id": metadata["screenshot_id"]}})
    assert "simulated" in tapped["content"][0]["text"]
    assert rpc(6, "tools/call", {"name": "press_home", "arguments": {"phone_id": phone}}).get("isError") is not True
    assert rpc(7, "tools/call", {"name": "type_text", "arguments": {"phone_id": phone, "text": "Demo task"}}).get("isError") is not True
    assert rpc(8, "tools/call", {"name": "tap", "arguments": {"phone_id": phone, "x": 0, "y": 0}}).get("isError") is True
    assert rpc(9, "tools/call", {"name": "cancel_action", "arguments": {"phone_id": phone}}).get("isError") is not True
finally:
    process.stdin.close()
    process.wait(timeout=10)
assert process.returncode == 0
print("REST + stdio MCP smoke test passed (demo; no hardware actions).")
