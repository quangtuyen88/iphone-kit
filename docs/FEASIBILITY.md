# iPhoneKit — feasibility spike (TapKit-style iPhone control)

Historical platform evidence and design notes, not the current feature list or production certification. See [README](../README.md) and [v0.1.0 release notes](releases/v0.1.0.md) for shipped behavior. The experimental preview does not meet all production-distribution gates listed below.

**Verdict: buildable, zero install on the iPhone** — no jailbreak, no Developer Mode, no Xcode on the phone.
Every primitive below was verified end-to-end on 2026-09-30: macOS 27.0 (MacBook Pro, Apple N1 Bluetooth) driving an iPhone 14 (iOS 27.0) over USB + Bluetooth.

## Verified mechanisms

| Piece | Mechanism | Evidence |
| - | - | - |
| USB discovery / control plane | `dlopen` private `MobileDevice.framework`; USBMux-only discovery and legacy lockdown pairing; `Connect`, `ValidatePairing`, `StartSession`, `CopyValue`, `SetValue` | Production correction 2026-10-13: removed the experimental RemoteXPC path because it acquired developer tunnels; trusted USB setup works without those assertions |
| AssistiveTouch on/off | lockdown domain `com.apple.Accessibility`, key `AssistiveTouchEnabledByiTunes` | `rc=0`; iOS log `Setting AssistiveTouchEnabled to true` |
| Screen | `kCMIOHardwarePropertyAllowScreenCaptureDevices = 1` → `AVCaptureDevice` type `.external` (muxed) → `AVCaptureVideoDataOutput` BGRA | 1170×2532 frames at ~57 fps, Camera TCC only |
| Input transport | Mac acts as a **Bluetooth Classic HID device**: HID SDP record, Classic peer readiness, and L2CAP PSM `0x11` + `0x13`. macOS 27 uses an ABI-checked Classic initializer; older macOS retains the public async opener | 2026-10-13: two real phone-side disconnect/reconnect cycles recovered in 3.69 s / 3.83 s; taps verified through fresh USB screenshots. Rapid app restart can still need a setup timeout and automatic retry |
| Discoverability | private `CBClassicManager -setBTDiscoverable:` (`IOBluetoothPreferenceSetDiscoverableState` is a no-op on macOS 27) | bluetoothd `Local device is now discoverable` |
| Pointer mapping | HID absolute X/Y `0…32767` maps linearly onto the full portrait screen in pixels | pointer drawn at (585, 1266) for the centre command |
| Tap / drag / type / Home | button down→up; drag with button held; keyboard report (US-ANSI usages); Consumer `AC Home` (0x0223) | tapped Settings back button, scrolled the list, typed `wifi` into Settings search, returned to Home Screen |

Dead ends (checked, do not retry):
- BLE HID-over-GATT through public `CBPeripheralManager` → `CBErrorDomain 8 "The specified UUID is not allowed"` for `0x1812`.
- `IOBluetoothHostController setClassOfDevice:forTimeInterval:` → returns 0 but does nothing (not needed: iOS lists the Mac anyway).

## One-time pairing flow per phone

1. Plug the iPhone in over USB, unlock, tap **Trust**.
2. App enables AssistiveTouch over lockdown, publishes the HID SDP record, makes the Mac discoverable.
3. On the iPhone: **Settings › Bluetooth** → tap the Mac's name under *Devices* → shows **Connected**.
4. App opens L2CAP `0x11`/`0x13` to the phone; later launches reconnect without user action.

## Risks / open items

- Private SPI (`MobileDevice`, `CBClassicManager`, the macOS 27 Classic channel initializer) can change with macOS updates. `ClassicBluetooth` checks capabilities and the initializer ABI and fails closed if they change.
- macOS 27's aggregate `IOBluetoothDevice.isConnected()` can report a disconnected BLE peripheral even while its Classic peer is connected. Both readiness checks and channel creation must use the Classic transport; retaining the device or waiting longer alone did not fix the reproduced failure.
- Approval is not a visual lock: the agent checks connection, geometry, and screenshot age after approval, but does not visually check for a newly covering notification before tapping. A coordinate tap can therefore hit an overlay.
- Not yet tested: landscape/rotation mapping, pointer auto-hide timing, several phones on one Mac, and long-running stability. Locked-phone wake is verified: raw IOKit serial keeps physical attachment distinct from logical transport loss, and a modifier-only Bluetooth HID pulse lights the display; iOS passcode/USB policy is never bypassed.
- Typing is US-ASCII HID usages only; iOS auto-capitalisation still applies (typed `wifi` → `Wifi`), so agents must verify via screenshot.

## Device binding (verified with one phone)

- USB ↔ Bluetooth: the test phone's lockdown `BluetoothAddress` matched its IOBluetooth peer address — exact join key. Personal device identifiers are omitted.
- USB ↔ capture: `AVCaptureDevice.uniqueID` is a CMIO UUID, **not** the UDID. Join it actively: wiggle the HID pointer on phone X (or toggle AssistiveTouch over lockdown) and bind to the capture stream that changes.

## Original post-spike requirements (historical)

Gesture engine
- Flick: 8–10 ms report spacing, release ≤16 ms after the last motion report (the spike's 50 ms stall kills scroll momentum).
- Map pixel centres: `(x + 0.5) / w * 32767`; coordinates always refer to a specific screenshot's pixel space.
- Park the pointer / wait out auto-hide before capturing; report the pointer rect with each screenshot.
- Absolute pointer is clamped to the screen, so bezel-origin swipes are impossible — use keyboard shortcuts / consumer keys and verify Control Center / App Switcher alternatives.
- Typing: fail loudly on non-ASCII, verify the observed field text (autocapitalisation), and test the Eject key (0xB8) to show the software keyboard while the HID keyboard is connected.

HID link
- One awaitable executor per phone (actor); no fire-and-forget timers; epoch-checked callbacks.
- Send neutral pointer + keyboard + consumer reports on channel open and before admitting work; treat control + interrupt as one unit and rebuild both on any loss; handle `VIRTUAL_CABLE_UNPLUG`.
- Accept channels only from the bound peer address; never replay demo gestures on reconnect.

Shared contract (REST, MCP and a later cloud relay use the same DTOs)
- `Screenshot { id, phoneId, epoch, size, orientation, capturedAt, pointerRect }`
- `Action { idempotencyKey, phoneId, epoch, sequence, deadline, screenshotId, payload }`
- `Job.status`: `queued → running → sent → observed | failed | uncertain`

Production-distribution gates (not all met by the v0.1.0 preview): notarized build on a clean non-developer account; permission revoke + reboot; adjacent macOS/iOS versions; 2–4 phones per Mac with p99 latency; sleep/wake and USB unplug; 1-hour soak with rotation.

## Run the spike

```bash
CODESIGN_IDENTITY="Apple Development: …" spikes/hid-probe/build.sh   # stable identity keeps TCC grants
open spikes/hid-probe/build/HIDProbe.app --args auto          # non-interactive checks
open spikes/hid-probe/build/HIDProbe.app --args pair 1200     # HID host session + live frames
echo "click 104 208" > /tmp/iphonekit-cmd.txt                # move | click | hold x y ms | drag x0 y0 x1 y1 | type … | key enter [command] | home | wait ms
```

Frames: `/tmp/iphone-screen.png` (every 3 s) · Log: `/tmp/iphonekit-probe.log`. Coordinates are screen pixels (default 1170×2532, change with `screen W H`).

## Original build plan (historical)

1. `IPhoneKitCore` (SwiftPM): `DeviceService` (MobileDevice), `ScreenService` (CMIO/AVFoundation), `HIDLink` (Classic HID transport, reconnect), `GestureEngine` (tap/double/triple/long-press/flick/drag/hold-drag/type/key/home), `PhoneSession` (serial action queue, coordinate mapping, JPEG ≤1344 long edge).
2. `iphonekitd` local server: REST in TapKit's shape (`/v1/phones`, `/phones/{id}/screenshot|tap|…`) + MCP (stdio and Streamable HTTP).
3. SwiftUI Mac app: phone grid, manual gestures, onboarding (Trust → AssistiveTouch → Bluetooth pair).
4. Later: cloud relay + auth, browser live view, built-in agent loop.
