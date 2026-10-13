import Foundation
import Testing

@testable import IPhoneKitCore

@MainActor
private func demoHubForOwnership() async -> PhoneHub {
  let hub = PhoneHub(demo: true)
  await hub.start()
  return hub
}

@Test @MainActor func leaseBlocksManualInput() async throws {
  let hub = await demoHubForOwnership()
  let lease = try hub.acquireInput(phoneID: "demo-iphone")

  do {
    _ = try await hub.execute(phoneID: "demo-iphone", command: PhoneCommand(action: .pressHome))
    Issue.record("Manual input should be rejected while a lease is active")
  } catch {
    #expect((error as? KitError)?.code == "INPUT_OWNED")
  }
  do {
    _ = try hub.acquireInput(phoneID: "demo-iphone")
    Issue.record("A phone cannot have two active leases")
  } catch {
    #expect((error as? KitError)?.code == "INPUT_OWNED")
  }

  _ = try await lease.execute(PhoneCommand(action: .pressHome))
  lease.release()
  let next = try hub.acquireInput(phoneID: "demo-iphone")
  next.release()
  await hub.stop()
}

@Test @MainActor func pendingManualInputPreventsAcquire() async throws {
  let hub = await demoHubForOwnership()
  let pending = Task { @MainActor in
    try await hub.execute(phoneID: "demo-iphone", command: PhoneCommand(action: .pressHome))
  }
  await Task.yield()
  do {
    _ = try hub.acquireInput(phoneID: "demo-iphone")
    Issue.record("Acquire should reject an execute that has started")
  } catch {
    #expect((error as? KitError)?.code == "INPUT_BUSY")
  }
  _ = try await pending.value
  let lease = try hub.acquireInput(phoneID: "demo-iphone")
  lease.release()
  await hub.stop()
}

@Test @MainActor func cancelRevokesLeaseAndAllowsFreshGenerationAfterDrain() async throws {
  let hub = await demoHubForOwnership()
  let lease = try hub.acquireInput(phoneID: "demo-iphone")
  let pending = Task { @MainActor in
    try await lease.execute(PhoneCommand(action: .pressHome))
  }
  await Task.yield()
  lease.cancel()
  do {
    _ = try await pending.value
    Issue.record("Cancellation should stop owned input")
  } catch {}
  do {
    _ = try await lease.execute(PhoneCommand(action: .pressHome))
    Issue.record("A cancelled lease must not execute later")
  } catch {
    #expect((error as? KitError)?.code == "INPUT_LEASE_INVALID")
  }
  let fresh = try hub.acquireInput(phoneID: "demo-iphone")
  fresh.release()
  await hub.stop()
}

@Test @MainActor func releaseDrainsExecutionBeforeTransfer() async throws {
  let hub = await demoHubForOwnership()
  let lease = try hub.acquireInput(phoneID: "demo-iphone")
  let pending = Task { @MainActor in
    try await lease.execute(PhoneCommand(action: .pressHome))
  }
  await Task.yield()
  lease.release()
  do {
    _ = try hub.acquireInput(phoneID: "demo-iphone")
    Issue.record("Release must drain pending owned work before transfer")
  } catch {
    #expect((error as? KitError)?.code == "INPUT_BUSY")
  }
  _ = try await pending.value
  let fresh = try hub.acquireInput(phoneID: "demo-iphone")
  fresh.release()
  await hub.stop()

}

@Test(arguments: [false, true]) @MainActor
func emergencyStopCancelsAdmittedManualInput(restart: Bool) async throws {
  let hub = await demoHubForOwnership()
  var admitted = false
  let command = PhoneCommand(action: .wake, idempotencyKey: "cancel-before-queue")
  let pending = Task { @MainActor in
    admitted = true
    return try await hub.execute(phoneID: "demo-iphone", command: command)
  }
  for _ in 0..<1000 {
    if admitted { break }
    await Task.yield()
  }
  #expect(admitted)
  if restart {
    await hub.stop()
    await hub.start()
  } else {
    hub.cancel(phoneID: "demo-iphone")
  }
  do {
    _ = try await pending.value
    Issue.record("Stop must cancel admitted input even before it reaches the command queue")
  } catch {
    #expect((error as? KitError)?.code == "CANCELLED")
  }
  do {
    _ = try await hub.execute(phoneID: "demo-iphone", command: command)
    Issue.record("Retrying a cancelled idempotency key must not replay input")
  } catch {
    #expect((error as? KitError)?.code == "CANCELLED")
  }
  let next = try hub.acquireInput(phoneID: "demo-iphone")
  _ = try await next.execute(PhoneCommand(action: .pressHome))
  next.release()
  await hub.stop()
}

@Test @MainActor func emergencyStopDoesNotCancelAnotherPhone() async throws {
  let hub = await demoHubForOwnership()
  var admitted = false
  let pending = Task { @MainActor in
    admitted = true
    return try await hub.execute(
      phoneID: "demo-iphone",
      command: PhoneCommand(action: .wake, idempotencyKey: "other-phone"))
  }
  for _ in 0..<1000 {
    if admitted { break }
    await Task.yield()
  }
  #expect(admitted)
  hub.cancel(phoneID: "another-phone")
  #expect(try await pending.value.status == "simulated")
  await hub.stop()
}
