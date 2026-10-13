# iPhoneKit

A local-first Mac app that gives AI agents an iPhone. USB carries the live screen; Bluetooth Classic HID carries pointer and keyboard input. Nothing is installed on the phone. No jailbreak or Developer Mode.

## Preview download

Download the Apple silicon (`arm64`) app and `SHA256SUMS` from [v0.1.0](https://github.com/quangtuyen88/iphone-kit/releases/tag/v0.1.0). Extract the ZIP and move `IPhoneKit.app` into Applications. Quit any existing copy with Cmd+Q before replacing it.

**Experimental preview: ad-hoc signed, not notarized.** Verify the download with `shasum -a 256 -c SHA256SUMS` in the download directory. macOS may block opening it; only if you trust this release, use **System Settings > Privacy & Security > Open Anyway** after trying to open the app. Ad-hoc rebuilds can require new Camera/Bluetooth grants. See [release notes and known issues](docs/releases/v0.1.0.md).

## Build and open

Requirements: macOS 14.6+ and a Swift 6.2+ toolchain. Hardware mechanisms have been verified on macOS 27 / iOS 27; older OS versions remain a release gate.

```bash
scripts/build-app.sh
open dist/IPhoneKit.app
```

The build script uses an available Developer ID / Apple Development signing identity, or ad-hoc signing if none exists. Set `CODESIGN_IDENTITY` to select one (`-` forces ad-hoc signing). Notarization and distribution signing are not included. A stable identity preserves privacy grants across rebuilds. Set `IPHONEKIT_APP_PATH` to a new bundle path to build and run the smoke/shutdown/macro checks against an isolated app instead of replacing `dist/IPhoneKit.app`.

## Connect a real phone

1. Plug in a USB data cable. Unlock the iPhone, tap **Trust This Computer**, and enter its passcode.
2. Select the phone in iPhoneKit and click **Enable control**. Allow **Camera** and **Bluetooth** when macOS asks. Camera access is for the USB iPhone screen, not your webcam.
3. On the iPhone, open **Settings > Bluetooth** and tap this Mac. Accept pairing prompts on both devices. Keep that page open until iPhoneKit says **Connected and ready**.
4. For unattended work, set **Settings > Display & Brightness > Auto-Lock > Never** and allow wired accessories while locked in **Settings > Privacy & Security**. iPhoneKit can send a harmless wake pulse while the cable remains attached, but it cannot bypass the passcode or iOS USB security. For multiple phones, choose and verify each phone's screen source explicitly.

The app enables AssistiveTouch only during setup and journals the prior value before changing it. Quit with Cmd+Q to stop control and restore the prior setting. Closing the window does not quit the app. If a phone is unplugged or locked during quit, restoration stays pending and is retried when it is connected at the next launch.

## Manual controls

Live click/drag, tap, double/triple tap, long press, flick, drag, hold-and-drag, keyboard text, Home, Keep awake, and Stop. **Keep awake** sends a modifier-only Bluetooth pulse after 20 seconds without phone input; it is off by default, stops on unplug/quit, and is not persisted. Stop cancels queued actions and releases held inputs. Keyboard typing is US-ASCII; iOS keyboard layout, autocapitalisation, and focus still apply.

## Built-in agent chat

The **Agent chat** tab runs a screenshot/one-action/verification loop against your own vision model. Open **Model settings**, enter an OpenAI-compatible Chat Completions base URL and a vision-capable model, and optionally save its API key. Keys stay in this Mac's Keychain, scoped to the endpoint's scheme, host, and port; changing endpoints does not reuse another endpoint's key.

Choose a ready phone, enter a task, click **Run task**, and confirm the screenshot-sharing disclosure. Only then does the app contact that exact provider. HTTPS is required except for literal loopback HTTP (e.g. `http://127.0.0.1:1234/v1`). Redirects are blocked. Providers must support image input, JSON-object replies, and `max_tokens` on Chat Completions.

Every proposed mutation waits for **Approve action** against its exact screenshot. Reject or Stop cancels the task and releases held inputs. Tasks stay pinned to their starting phone, stop at 20 steps, and never automatically replay uncertain input. Chat is volatile and not saved at quit. On-screen instructions are treated as untrusted data; review actions involving payments, messaging, deletion, or private accounts carefully.

Demo mode uses an offline scripted planner and a simulated phone, never your model provider or real hardware. Run a demo task to exercise approval and verification without credentials. Actual provider/model compatibility is tested only after you configure it and explicitly authorize a task.

## Local game macros

The **Macros** tab records short portrait-game gesture sequences and replays them using local image matching and optional OCR on the Mac. It does not contact a model provider or install anything on the phone.

1. Select a ready portrait phone, open your game, and choose **New**, then **Record gestures**.
2. Tap or drag on the phone preview using the gesture picker. Wait for a visible result, then choose **Capture result**. Repeat one action at a time; **Finish recording** when done. Actions without a distinguishable result cannot be recorded.
3. Review each step's before/after images, guard region, optional required text, delay, and timeout. Individual approval is on by default; disable it only for reviewed gameplay actions. Crops should retain distinctive context and avoid the floating AssistiveTouch button.
4. Set loop, action, and time limits; optionally capture a goal screen as a stop condition. **Save profile**, then **Review & run**, acknowledge the limits, and **Approve & run**.

Profiles support at most 20 steps, 20 loops, 100 actions, and 5–600 seconds per run, including waits and approvals. Playback is pinned to the recorded phone and portrait geometry. Manual/API/MCP input and keep-awake pulses cannot interleave with recording or playback. **Stop** or **⌘.** cancels automation and releases held input. An unexpected screen, connection change, timeout, or uncertain action pauses/stops the run; no uncertain action is automatically retried. Inspect the phone before starting a new run.

Profiles and full-screen reference JPEGs are stored locally in `~/Library/Application Support/iPhoneKit/macros.json` with private file permissions. Selecting a smaller guard region does **not** redact the saved image. Avoid recording private screens. Demo profiles use a separate private temporary directory; self-tests use isolated disposable stores.

Use your own game/account and follow its rules. Image/OCR checks are not a guarantee against overlays or last-moment screen changes. Do not put purchases, sign-in, messaging, or account changes in automatic loops. Real-game reliability and long hardware runs remain unverified.

## MCP agents

Click **Copy MCP configuration** and paste it into your MCP client's configuration. The bundled `iphonekit-mcp` helper uses stdio and calls the Mac app's loopback API; it does not own hardware or trigger Camera/Bluetooth prompts. Compatible with Claude Code, Codex, and other stdio MCP clients.

Tools: `list_phones`, `get_phone_status`, `screenshot`, `tap`, `double_tap`, `triple_tap`, `long_press`, `flick`, `drag`, `hold_and_drag`, `type_text`, `press_key`, `press_home`, `wake`, `set_keep_awake`, `cancel_action`.

Pointer actions require `screenshot_id` from the screenshot they refer to. Coordinates are pixels in that returned JPEG. Input completion means **sent**, not that the intended UI task succeeded: take another screenshot and verify. Agents should ask before purchases, messages, deletion, or sharing private data.

## Local API

Default: `http://127.0.0.1:8766`. Click **Copy API key** for the token. The token lives in `~/Library/Application Support/iPhoneKit/api-token` with mode 0600; keep it private. All device routes require `X-API-Key` or `Authorization: Bearer`. Browser-origin requests are rejected; no CORS, public listener, cloud relay, or telemetry.

See [REST API](docs/REST.md). Optional environment variables: `IPHONEKIT_PORT` and `IPHONEKIT_API_KEY`. Run the app executable with `--headless` for a background user-session host (the app still owns the platform run loops and privacy identity).

## Test without a phone

Quit any real-phone instance first, then:

```bash
open dist/IPhoneKit.app --args --demo
python3 scripts/smoke-test.py
swift test
python3 scripts/verify-shutdown.py
python3 scripts/verify-macros.py
```

Demo mode uses a simulated device and never accesses phone hardware. Smoke tests exercise the actual HTTP listener and bundled stdio helper. Shutdown tests launch isolated demo instances on separate ports and verify SIGTERM/SIGINT cleanup. Macro verification launches an owned offline demo, records two steps, saves/reloads privately, runs four screen-verified actions with two approvals, and verifies graceful shutdown without changing normal profiles. Swift tests cover report encoding, gestures, FIFO/cancellation, input leases, macro safety and visual matching, stale epochs, journal failures, JSON, HTTP security, and readable demo rendering.

Development flags: `--demo --agent-self-test --ui-snapshot` runs a fully offline agent check with simulated approval and captures the result; `--demo --macro-self-test --ui-snapshot` exercises the macro workflow and selects the Macros tab. Macro self-tests write `report.json` and `macros.json` into a unique private temporary directory, or `IPHONEKIT_MACRO_TEST_DIRECTORY` when explicitly supplied in demo self-test mode. `--demo --ui-snapshot` renders an owned demo window to `/tmp/iphonekit-ui.png` without Screen Recording permission; `--auto-prepare` explicitly runs setup for attached real phones and can change AssistiveTouch after permissions are approved.

## Scope and limitations

- Native Mac UI, built-in BYO-model agent chat, bounded local game macros, local REST, and stdio MCP. No hosted account, subscription, cloud relay, remote MCP/OAuth, or browser live streaming yet.
- Pointer actions currently require portrait; landscape capture works but uncalibrated pointer input fails closed.
- Single-pointer HID is not multi-touch injection. Some bezel/system gestures need keyboard alternatives.
- Known issue: TikTok search-result thumbnails ignored short HID clicks in hardware testing, while tab navigation and a long-press menu worked. The cause remains unverified; increasing press duration to 150 or 250 ms did not resolve it. Do not treat `sent` as proof that a video opened or blindly repeat the action.
- Several phones can be routed by their exact Bluetooth addresses; multi-phone capture must be explicitly bound. Multi-phone throughput and long soak tests are not yet certified.
- Private Apple SPI is isolated and capability-checked, but macOS updates can break it. Bluetooth reports are serialized and await write completion; congestion/latency remains a hardware release gate.
- Screenshots may contain the iOS pointer. Its last commanded position is returned when known; visibility is not inferred.

Architecture: [feasibility and platform evidence](docs/FEASIBILITY.md). The original spike remains separate from the app.
