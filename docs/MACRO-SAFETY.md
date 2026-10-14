# Visual macro safety

## Current design

- Each step requires two fresh before frames with monotonic capture-time evidence, including a queued first-send guard immediately before input. Missing uptime is not fabricated into freshness evidence. Connection epoch, capture binding and portrait geometry must remain valid.
- An informative target match and mandatory full-screen context evidence are required. Context tolerance is capped at **0.035**, even when target tolerance is looser. A full-screen target at an equally strict tolerance already supplies that context evidence. Popups outside a crop are checked; conservative pauses during animation are intentional. Visual similarity is heuristic and can still miss overlays or last-moment changes.
- The dispatch witness is owned by the MainActor, not protected by ad hoc locks. It distinguishes whether input actually began from later confirmation. A frozen command outcome is separate from the last visually verified step; neither is permission to replay uncertain input.
- Stop, changed connection/capture, failed guards and uncertain outcomes require explicit operator inspection. After inspection, start a **new run from step 1**; never resume an interrupted run. Stop cannot undo input already sent.
- The diagnostic trace is typed, RAM-only and capped at 100 events. It contains no PII, screenshots, OCR, phone identifiers or credentials. Raw backend errors are not exported.

## Evidence and limits

Deterministic fake-controller/matcher tests cover the software safety contracts. The full test suite and isolated offline macro workflow pass. The native demo also verifies that interrupted runs show last verified progress, require inspection, and reset consent when review is reopened.

The read-only probe below tests image guards against an actual capture. The latest live attempt could not connect to the app's loopback API; it did not validate a physical phone. Even a successful probe would not prove real HID fault handling, macro dispatch, first-send timing, cancellation delivery or recovery after physical disconnect. Physical fault handling is **not yet certified**.

### Opt-in read-only capture probe

Test: `liveCaptureImageGuardsRejectOutsideCropOverlay` in `Tests/IPhoneKitAgentTests/LiveGuardTests.swift`.

Run manually: `IPHONEKIT_LIVE_GUARD_SMOKE=1 swift test --filter liveCaptureImageGuardsRejectOutsideCropOverlay`.

Without exactly `IPHONEKIT_LIVE_GUARD_SMOKE=1`, Swift Testing skips it. Use the already-running app with exactly one ready, non-demo portrait phone on a harmless static screen whose left side has informative content. Unready, absent or ambiguous devices fail explicitly; they do not silently skip. `IPHONEKIT_PORT` must be a nonzero UInt16 (default 8766); the host is literally `127.0.0.1`. Authentication uses `IPHONEKIT_API_KEY` or reads the existing `~/Library/Application Support/iPhoneKit/api-token`; it never creates keys.

Only `GET /v1/phones` and `GET /v1/phones/{id}/screenshot?long_edge=900` are sent. Redirects and persistent caches are disabled. The probe never sends POST, phone input, radio changes or permission/setup requests. Responses decode Core DTOs with `KitJSON`. Optional missing capture uptime from an older running app remains absent: no timing is invented. Native capture dimensions are not treated as a resized-screen aspect-ratio contract.

The unchanged real JPEG must pass both target and context matching. An in-memory high-quality JPEG overlay painted on the right must preserve an informative left-side crop match while failing full-context matching at 0.035. There is no relaxed tolerance or fuzzy-pass fallback. Images are not persisted; tokens, phone IDs, OCR and raw backend response/error details are not printed. The probe is not run automatically as part of hardware certification.

## Manual hardware matrix — not yet certified

Operators must use harmless screens and gestures: no purchases, messages, deletions, account changes or other account mutations. Disable unrelated automation and inspect the phone after every interruption. Record only redacted outcomes, not images or identifiers.

| Physical scenario | Required observation |
| --- | --- |
| Disconnect/reconnect during approval | Prior approval cannot authorize input on the new connection. Inspect, then begin a new run from step 1. |
| Disconnect/reconnect during dispatch | No automatic replay; report whether dispatch began separately from last verified progress. Inspect actual phone state before a new run. |
| Rotation or capture rebind before/while dispatching | Stale geometry/binding cannot pass queued first-send checks; uncertain in-flight effects require inspection. |
| Popup outside the target crop | Target similarity alone cannot authorize input; mandatory context rejects the popup. |
| Stop mid-gesture | No subsequent macro gesture; observe release/cancellation on real hardware and inspect any partial effect. Do not assume already-sent input was undone. |

Passing fake tests or the read-only capture probe does not mark any row completed. Each row needs explicit real-device observation before physical-fault certification.
