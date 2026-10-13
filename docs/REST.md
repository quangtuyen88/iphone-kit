# Local REST API

Base URL: http://127.0.0.1:8766. Send the token as `X-API-Key` or `Authorization: Bearer`. POST bodies must be JSON with `Content-Type: application/json`. The Mac app must stay running. No browser-origin requests.

| Method | Path | Result / body |
| --- | --- | --- |
| GET | /health | Service health; no authentication or device information |
| GET | /v1/phones | {"phones": [...]} with IDs, readiness, message, native size, epoch |
| GET | /v1/phones/{id}/status | One phone |
| GET | /v1/phones/{id}/screenshot?long_edge=1344 | JPEG as base64 `jpeg`, `id`, `phone_id`, `epoch`, `width`, `height`, native size, orientation, capture timestamp, optional pointer position |
| POST | /v1/phones/{id}/prepare | {} — request platform permissions and enable control; requires user participation for pairing |
| POST | /v1/phones/{id}/bind-capture | {"capture_id":"..."} — select a source shown in the Mac app |
| POST | /v1/phones/{id}/cancel | {} — cancel queued work and release held inputs |
| POST | /v1/phones/{id}/tap | x, y, screenshot_id |
| POST | /v1/phones/{id}/double-tap | x, y, screenshot_id |
| POST | /v1/phones/{id}/triple-tap | x, y, screenshot_id |
| POST | /v1/phones/{id}/tap-and-hold | x, y, screenshot_id, duration? (ms; default 1000) |
| POST | /v1/phones/{id}/flick | x, y, screenshot_id, direction (up/down/left/right) |
| POST | /v1/phones/{id}/drag | from_x, from_y, to_x, to_y, screenshot_id, speed? (slow/medium/fast) |
| POST | /v1/phones/{id}/hold-and-drag | drag fields + hold_duration_ms? (default 500) |
| POST | /v1/phones/{id}/type-text | text (1–1000 US-ASCII characters) |
| POST | /v1/phones/{id}/press-key | key, modifiers?, repeat_count? |
| POST | /v1/phones/{id}/press-home | {} |
| POST | /v1/phones/{id}/wake | {} — modifier-only Bluetooth HID pulse; safe to use when the display or bound screen source is unavailable |
| POST | /v1/phones/{id}/keep-awake | {"enabled":true} — while enabled, send the same harmless pulse after 20 seconds without input; automatically disables on unplug or app quit |
| POST | /v1/phones/{id}/move | x, y, screenshot_id; pointer only |
| POST | /v1/phones/{id}/release | {} — neutral input reports |
| POST | /v1/phones/{id}/actions | Full command with `action` in underscore form, e.g. `hold_and_drag` |
| GET | /v1/jobs/{id} | Recently completed action result; memory-only, no async job submission |

All pointer coordinates refer to the returned JPEG, not a resized browser preview or UIKit points. A screenshot ID expires after 60 seconds and is invalid after a connection, capture-source, or geometry change. Portrait pointer input only. No screenshot is returned by action routes.

Optional action fields: `idempotency_key` (1–128 bytes) and `deadline` (ISO-8601 UTC timestamp, second precision). Reuse the exact same command and key to retrieve the same result without replaying input. Reusing the key for another payload returns a conflict. Deduplication is bounded to 256 remembered commands and does not survive app restart.

Successful action result: `id`, `phone_id`, `action`, `status` (sent or simulated), `started_at`, `completed_at`, `epoch`, `message`. **Sent does not mean observed success.** Verify with another screenshot. Except for the harmless `wake` pulse, phone input is rejected unless status is `ready`. Keep-awake pulses use the same per-phone queue, never interleave with an action, and wait 20 seconds after recent input. Actions serialize per phone, with a maximum queue depth of 64. Interrupted input is not replayed automatically.

Keys: enter, escape, backspace, tab, space, right, left, down, up, delete, home, end, pageup, pagedown. Modifiers: control, shift, alternate, command. Unsupported text is rejected before any character is sent; locale/focus/capitalisation are controlled by iOS.

Errors use `{"detail":{"error":"CODE","message":"..."}}` and a non-200 status: 400 invalid parameters, 401 missing/wrong token, 403 permission/origin/host, 404 unknown phone/route, 409 stale state or uncertain/interrupted input, 429 queue full, 503 disconnected/unavailable, 504 deadline expired. Never blindly retry interrupted actions.

REST screenshot responses and command payloads are not persisted or logged. Separately, macro profiles explicitly saved in the Mac UI include full-screen reference JPEGs in the private local `macros.json` file. Known phone ID, model, and Bluetooth address are cached locally with owner-only permissions so a physically attached sleeping phone remains identifiable after relaunch. An external MCP client can send requested screenshots to its model provider; only connect clients you trust.
