import Foundation
import Observation

@Observable @MainActor
public final class PhoneHub: ExclusivePhoneControlling {
  public private(set) var phones: [PhoneInfo] = []
  public private(set) var captures: [CaptureInfo] = []
  public private(set) var events: [DiagnosticEvent] = []
  public private(set) var permissionStatus: [String: String] = [:]
  public private(set) var lastError: String?
  public let isDemo: Bool
  @ObservationIgnored private let screen = ScreenService()
  @ObservationIgnored private let hid = HIDHost()
  @ObservationIgnored private var usb: DeviceService?
  @ObservationIgnored private var attached: [USBPhone] = []
  @ObservationIgnored private var prepared: Set<String> = []
  @ObservationIgnored private var bindings: [String: String] = [:]
  @ObservationIgnored private var queues: [String: CommandQueue] = [:]
  @ObservationIgnored private var setup: [String: Task<Void, any Error>] = [:]
  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var started = false
  @ObservationIgnored private var stopping = false
  @ObservationIgnored private var epochCounter: UInt64 = 0
  @ObservationIgnored private var fingerprints: [String: String] = [:]
  @ObservationIgnored private var epochs: [String: UInt64] = [:]
  @ObservationIgnored private var references: [String: Reference] = [:]
  @ObservationIgnored private var referenceOrder: [String] = []
  @ObservationIgnored private var pointers: [String: (Double, Double)] = [:]
  @ObservationIgnored private var cached: [String: CachedAction] = [:]
  @ObservationIgnored private var completedKeys: [String] = []
  @ObservationIgnored private var keepAwakePhoneIDs: Set<String> = []
  @ObservationIgnored private var lastActivity: [String: Date] = [:]
  @ObservationIgnored private var lastKeepAwakePulse: [String: Date] = [:]
  @ObservationIgnored private var lastKeepAwakeAttempt: [String: Date] = [:]
  @ObservationIgnored private var keepAwakeErrors: [String: String] = [:]
  @ObservationIgnored private var inputOwnership: [String: InputOwnership] = [:]
  @ObservationIgnored private var activeInputExecutions: [String: Int] = [:]
  @ObservationIgnored private var inputGeneration: UInt64 = 0
  @ObservationIgnored private var cancellationGenerations: [String: UInt64] = [:]
  @ObservationIgnored private var demo = DemoScreen()

  private enum InputOwnershipPhase {
    case active
    case draining
    case revoked
  }

  private struct InputOwnership {
    let token: UUID
    var generation: UInt64
    var phase: InputOwnershipPhase
  }

  private struct InputExecutionContext {
    let token: UUID?
    let generation: UInt64?
    let cancellationGeneration: UInt64
  }

  private struct Reference {
    let phoneID: String
    let epoch: UInt64
    let captureID: String?
    let generation: UInt64
    let geometry: ImageGeometry
    let capturedAt: Date
  }
  private struct CachedAction {
    let command: PhoneCommand
    let task: Task<ActionResult, any Error>
    let ownerToken: UUID?
    let generation: UInt64?
  }

  public init(demo: Bool = false) {
    isDemo = demo
    if !demo {
      bindings =
        UserDefaults.standard.dictionary(forKey: "iPhoneKit.captureBindings") as? [String: String]
        ?? [:]
    }
    hid.changed = { [weak self] in
          guard let self else { return }
          for phoneID in Array(inputOwnership.keys) {
            finalizeInputOwnershipIfQuiescent(phoneID: phoneID)
          }
          reconcile()
        }
    hid.diagnostic = { [weak self] message in self?.record(message) }
  }

  public func start() async {
    guard !started else { return }
    started = true
    stopping = false
    if isDemo {
      epochCounter = 1
      epochs["demo-iphone"] = 1
      captures = [CaptureInfo(id: "demo-screen", name: "Demo screen")]
      phones = [
        PhoneInfo(
          id: "demo-iphone", name: "Demo iPhone", model: "Simulated device", systemVersion: "Demo",
          status: .ready,
          message: "Demo mode — no hardware input.", width: 390, height: 844,
          captureID: "demo-screen", epoch: 1)
      ]
      permissionStatus = ["camera": "demo", "bluetooth": "demo"]
      record("Demo started. Your real devices are untouched.")
      return
    }
    do {
      try screen.enableDiscovery()
      usb = try DeviceService(
        updated: { [weak self] values in
          Task { @MainActor [weak self] in self?.updateUSB(values) }
        },
        diagnostic: { [weak self] message in
          Task { @MainActor [weak self] in self?.record(message) }
        })
      try await usb?.start()
    } catch {
      lastError = error.localizedDescription
      record(error.localizedDescription)
    }
    reconcile()
    loop = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
        guard let self, !stopping else { return }
        usb?.refresh()
        screen.refresh()
        hid.reconnect()
        reconcile()
        await maintainKeepAwake()
      }
    }
  }

  public func stop() async {
    guard started, !stopping else { return }
    stopping = true
    loop?.cancel()
    loop = nil
    setup.values.forEach { $0.cancel() }
    for phoneID in Set(inputOwnership.keys).union(activeInputExecutions.keys) {
      revokeInputOwnership(phoneID: phoneID, cancelQueue: false)

    }
    queues.values.forEach { $0.cancel() }
    hid.stop()
    await screen.stop()
    await usb?.stop()
    prepared.removeAll()
    keepAwakePhoneIDs.removeAll()
    lastActivity.removeAll()
    lastKeepAwakePulse.removeAll()
    lastKeepAwakeAttempt.removeAll()
    keepAwakeErrors.removeAll()
    started = false
    record("Stopped. Prior accessibility settings restored where phones are reachable.")
  }

  private func updateUSB(_ values: [USBPhone]) {
    guard !stopping else { return }
    let prior = Dictionary(uniqueKeysWithValues: attached.map { ($0.id, $0) })
    let currentIDs = Set(values.map { $0.id })
    for phone in values where prior[phone.id]?.available == true && !phone.available {
      queues[phone.id]?.cancel()
      revokeInputOwnership(phoneID: phone.id, cancelQueue: false)
      references = references.filter { $0.value.phoneID != phone.id }
      referenceOrder.removeAll { references[$0] == nil }
      if let address = phone.bluetoothAddress,
        let connection = hid.connections[normalizedBluetoothAddress(address)]
      {
        connection.neutralize(epoch: connection.epoch)
      }
      record("USB data paused for \(phone.name); physical cable remains attached.")
    }
    // A phone waking up is a fresh chance for Bluetooth: re-arm reconnects paused by earlier failures.
    for phone in values where prior[phone.id]?.available == false && phone.available {
      if let address = phone.bluetoothAddress {
        hid.connections[normalizedBluetoothAddress(address)]?.resetBackoff()
      }
    }
    for previous in attached where !currentIDs.contains(previous.id) {
      queues[previous.id]?.cancel()
      revokeInputOwnership(phoneID: previous.id, cancelQueue: false)
      prepared.remove(previous.id)
      keepAwakePhoneIDs.remove(previous.id)
      lastActivity.removeValue(forKey: previous.id)
      lastKeepAwakePulse.removeValue(forKey: previous.id)
      lastKeepAwakeAttempt.removeValue(forKey: previous.id)
      keepAwakeErrors.removeValue(forKey: previous.id)
      references = references.filter { $0.value.phoneID != previous.id }
      referenceOrder.removeAll { references[$0] == nil }
      if let address = previous.bluetoothAddress {
        let connection = hid.connections[normalizedBluetoothAddress(address)]
        connection?.enabled = false
        connection?.invalidate()
      }
    }
    attached = values
    reconcile()
  }

  public func prepare(phoneID: String) async throws {
    if isDemo { return }
    if let current = setup[phoneID] { return try await current.value }
    guard !stopping, attached.contains(where: { $0.id == phoneID }) else {
      throw KitError("PHONE_OFFLINE", "Connect and unlock the iPhone first.")
    }
    let task = Task { @MainActor in
      try await screen.requestPermission()
      try Task.checkCancellation()
      try await hid.requestPermission()
      try Task.checkCancellation()
      guard let usb else { throw KitError("USB_UNAVAILABLE", "USB discovery is not running.") }
      // Asks an untrusted phone to trust this Mac first; throws TRUST_REQUIRED with the current step.
      let enabled = try await usb.enableControl(phoneID: phoneID)
      try Task.checkCancellation()
      guard let phone = enabled ?? attached.first(where: { $0.id == phoneID }),
        let address = phone.bluetoothAddress
      else {
        throw KitError(
          "BLUETOOTH_ADDRESS_UNAVAILABLE",
          "iPhoneKit could not read this iPhone's Bluetooth address. Unlock it and retry.")
      }
      try hid.startService()
      prepared.insert(phoneID)
      let connection = hid.connection(address: address)
      connection.connect(userInitiated: true)
      if !connection.isReady {
        do { try hid.beginPairing() } catch { record(error.localizedDescription) }
      }
      screen.refresh()
      reconcile()
      if let captureID = bindings[phoneID] { try await screen.start(captureID: captureID) }
      try Task.checkCancellation()
      reconcile()
      record("Control enabled for \(phone.name). Pair in Settings > Bluetooth if needed.")
    }
    setup[phoneID] = task
    defer { setup.removeValue(forKey: phoneID) }
    do {
      try await task.value
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      throw error
    }
  }

  public func bindCapture(phoneID: String, captureID: String) throws {
    guard phones.contains(where: { $0.id == phoneID }),
      captures.contains(where: { $0.id == captureID })
    else {
      throw KitError("CAPTURE_NOT_FOUND", "Select a connected phone and screen source.")
    }
    let occupied = bindings.contains { entry in
      entry.key != phoneID && entry.value == captureID && phones.contains { $0.id == entry.key }
    }
    guard !occupied else {
      throw KitError("CAPTURE_ALREADY_BOUND", "This screen is assigned to another connected phone.")
    }
    queues[phoneID]?.cancel()
    bindings[phoneID] = captureID
    if !isDemo { UserDefaults.standard.set(bindings, forKey: "iPhoneKit.captureBindings") }
    fingerprints.removeValue(forKey: phoneID)
    reconcile()
  }

  private func reconcile() {
    guard !isDemo, !stopping else { return }
    captures = screen.captures
    permissionStatus = ["camera": screen.permission, "bluetooth": hid.permission]
    if attached.count == 1, captures.count == 1, let phone = attached.first,
      let capture = captures.first, bindings[phone.id] == nil
    {
      bindings[phone.id] = capture.id
      UserDefaults.standard.set(bindings, forKey: "iPhoneKit.captureBindings")
    }
    phones = attached.map { phone in
      let boundCaptureID = bindings[phone.id]
      let captureID = boundCaptureID.flatMap { id in
        captures.contains(where: { $0.id == id }) ? id : nil
      }
      let frame = phone.available ? captureID.flatMap { screen.frame(captureID: $0) } : nil
      let link = phone.bluetoothAddress.flatMap { hid.connections[normalizedBluetoothAddress($0)] }
      let fingerprint =
        "\(phone.available)/\(captureID ?? "")/\(frame?.geometryGeneration ?? 0)/\(link?.epoch ?? 0)"
      if fingerprints[phone.id] != fingerprint {
        epochCounter &+= 1
        epochs[phone.id] = epochCounter
        fingerprints[phone.id] = fingerprint
      }
      let status: PhoneStatus
      let message: String
      if !phone.available {
        status = .needsWake
        message =
          "USB data paused while the iPhone is asleep or locked. Wake and unlock it; for unattended use set Auto-Lock to Never and allow wired accessories while locked."
      } else if !phone.trusted {
        status = .needsTrust
        message =
          phone.trustProblem?.message(code: phone.trustCode.map(LockdownCode.hex))
          ?? TrustProblem.checkingMessage
      } else if !prepared.contains(phone.id) || phone.assistiveTouch == false {
        status = .needsSetup
        message = "Enable control to allow Camera, Bluetooth, and AssistiveTouch."
      } else if link?.isReady != true {
        status = .needsBluetooth
        message = link?.setupMessage ?? "On iPhone: Settings > Bluetooth > tap this Mac."
      } else if captureID == nil, boundCaptureID != nil {
        status = .needsCapture
        message =
          "The bound iPhone screen source is unavailable. Wake or reconnect the phone, then reselect the source if needed."
      } else if captureID == nil {
        status = .needsCapture
        message = "Select the screen source belonging to this phone."
      } else if frame == nil || ProcessInfo.processInfo.systemUptime - (frame?.uptime ?? 0) > 3 {
        status = .needsCapture
        message = "The iPhone screen stopped updating. Wake or reconnect it, then retry."
      } else {
        status = .ready
        message =
          frame!.width > frame!.height
          ? "Screen available. Rotate to portrait for pointer input." : "Connected and ready."
      }
      let trustProblem = status == .needsTrust ? phone.trustProblem : nil
      return PhoneInfo(
        id: phone.id, name: phone.name, model: phone.model, systemVersion: phone.systemVersion,
        bluetoothAddress: phone.bluetoothAddress,
        status: status, message: message, width: frame?.width ?? 0, height: frame?.height ?? 0,
        captureID: captureID, epoch: epochs[phone.id] ?? 0,
        keepAwake: keepAwakePhoneIDs.contains(phone.id),
        lastKeepAwakePulseAt: lastKeepAwakePulse[phone.id],
        keepAwakeError: keepAwakeErrors[phone.id],
        trust: trustProblem,
        trustErrorCode: trustProblem == nil ? nil : phone.trustCode.map(LockdownCode.hex))
    }
  }

  /// Asks a USB-connected phone to show "Trust This Computer?" again (after Don't Trust, or once the request expired).
  public func requestTrust(phoneID: String) {
    guard !isDemo, started, !stopping, let phone = attached.first(where: { $0.id == phoneID })
    else { return }
    usb?.requestTrust(phoneID: phoneID)
    record("Asked \(phone.name) to trust this Mac. Unlock it and tap Trust.")
  }

  public func screenshot(phoneID: String, longEdge: Int = 1344) async throws -> Screenshot {
    guard started, !stopping, let phone = phones.first(where: { $0.id == phoneID }) else {
      throw KitError("PHONE_OFFLINE", "Phone is not connected.")
    }
    if phone.status == .needsWake {
      throw KitError(
        "PHONE_ASLEEP",
        "The cable is attached, but iOS paused USB data while asleep or locked. Send wake, then unlock the iPhone if needed."
      )
    }
    guard (1...4096).contains(longEdge) else {
      throw KitError("INVALID_SIZE", "long_edge must be 1–4096.")
    }
    let result: Screenshot
    let reference: Reference
    if isDemo {
      let (jpeg, width, height) = try demo.jpeg(longEdge: longEdge)
      result = Screenshot(phoneID: phoneID, epoch: phone.epoch, width: width, height: height, nativeWidth: 390,
                                 nativeHeight: 844, capturedAt: Date(), jpeg: jpeg,
                                 capturedUptime: ProcessInfo.processInfo.systemUptime)
      reference = Reference(
        phoneID: phoneID, epoch: phone.epoch, captureID: nil, generation: 0,
        geometry: ImageGeometry(width: width, height: height, nativeWidth: 390, nativeHeight: 844),
        capturedAt: result.capturedAt)
    } else {
      guard screen.permission == "allowed" else {
        throw KitError("CAMERA_PERMISSION", "Enable control in the Mac app to allow screen access.")
      }
      guard let captureID = phone.captureID else {
        throw KitError(
          "CAPTURE_REQUIRED", "Choose the matching iPhone screen source in the Mac app.")
      }
      let lease = CaptureLease(epoch: phone.epoch, captureID: captureID)
      let frame = try await screen.screenshot(captureID: captureID, longEdge: longEdge)
      guard !stopping, bindings[phoneID] == captureID,
        attached.contains(where: { $0.id == phoneID && $0.available })
      else {
        throw KitError("CONNECTION_CHANGED", "Phone or screen source changed during capture.")
      }
      reconcile()
      let epoch = epochs[phoneID] ?? 0
      try lease.validate(
        epoch: epoch, captureID: bindings[phoneID], generation: frame.geometryGeneration,
        currentGeneration: screen.frame(captureID: captureID)?.geometryGeneration)
      let pointer = pointers[phoneID]
      result = Screenshot(phoneID: phoneID, epoch: epoch, width: frame.width, height: frame.height,
                                 nativeWidth: frame.nativeWidth, nativeHeight: frame.nativeHeight,
                                 capturedAt: frame.capturedAt, jpeg: frame.jpeg, pointerX: pointer.map { $0.0 * Double(frame.width) }, pointerY: pointer.map { $0.1 * Double(frame.height) },
                                 capturedUptime: frame.uptime)
      reference = Reference(
        phoneID: phoneID, epoch: epoch, captureID: captureID, generation: frame.geometryGeneration,
        geometry: ImageGeometry(
          width: frame.width, height: frame.height, nativeWidth: frame.nativeWidth,
          nativeHeight: frame.nativeHeight), capturedAt: frame.capturedAt)
    }
    references[result.id] = reference
    referenceOrder.append(result.id)
    if referenceOrder.count > 512 { references.removeValue(forKey: referenceOrder.removeFirst()) }
    return result
  }

  public func acquireInput(phoneID: String) throws -> PhoneInputLease {
      guard started, !stopping else {
        throw KitError("PHONE_OFFLINE", "Phone is not connected.")
      }
      reconcile()
      guard let phone = phones.first(where: { value in value.id == phoneID }) else {
        throw KitError("PHONE_OFFLINE", "Phone is not connected.")
      }
      guard phone.status == .ready else {
        throw KitError("PHONE_NOT_READY", "The iPhone is not ready for exclusive input.")
      }
      finalizeInputOwnershipIfQuiescent(phoneID: phoneID)
      if let owner = inputOwnership[phoneID], owner.phase == .active {
        throw KitError("INPUT_OWNED", "Phone input is owned by a visual macro.")
      }
      guard inputOwnership[phoneID] == nil, inputWorkIsDrained(phoneID: phoneID) else {
        throw KitError("INPUT_BUSY", "Phone input is already in use or still draining.")
      }
      inputGeneration &+= 1
      let generation = inputGeneration
      let token = UUID()
      inputOwnership[phoneID] = InputOwnership(token: token, generation: generation, phase: .active)
      record("Exclusive visual-macro input acquired; keep-awake pulses paused.")
      return PhoneInputLease(
        phoneID: phoneID,
        execute: { [weak self] command in
          guard let self else { throw KitError("PHONE_OFFLINE", "Phone controller is unavailable.") }
          return try await executeOwned(phoneID: phoneID, command: command, ownerToken: token, generation: generation)
        },
        guardedExecute: { [weak self] command, authorization in
          guard let self else { throw KitError("PHONE_OFFLINE", "Phone controller is unavailable.") }
          return try await executeOwned(phoneID: phoneID, command: command, ownerToken: token,
                                        generation: generation, authorization: authorization)
        },
        isDrained: { [weak self] in self?.inputWorkIsDrained(phoneID: phoneID) ?? true },
        cancel: { [weak self] in
          self?.cancelInputLease(phoneID: phoneID, ownerToken: token, generation: generation)
        },
        release: { [weak self] in
          self?.releaseInputLease(phoneID: phoneID, ownerToken: token, generation: generation)
        }
      )
    }

  private func validateInputEntry(phoneID: String, ownerToken: UUID?, generation: UInt64?) throws {
    if let ownerToken, let generation {
      guard let owner = inputOwnership[phoneID], owner.token == ownerToken,
        owner.generation == generation, owner.phase == .active
      else {
        throw KitError("INPUT_LEASE_INVALID", "This visual-macro input lease is no longer valid.")
      }
    } else {
      guard inputOwnership[phoneID] == nil else {
        throw KitError("INPUT_OWNED", "Phone input is owned by a visual macro.")
      }
    }
  }

  private func beginInputExecution(phoneID: String, ownerToken: UUID?, generation: UInt64?) throws
    -> InputExecutionContext
  {
    try validateInputEntry(phoneID: phoneID, ownerToken: ownerToken, generation: generation)
    activeInputExecutions[phoneID, default: 0] += 1
    return InputExecutionContext(
      token: ownerToken, generation: generation,
      cancellationGeneration: cancellationGenerations[phoneID, default: 0])
  }

  private func finishInputExecution(phoneID: String) {
    if let count = activeInputExecutions[phoneID], count > 1 {
      activeInputExecutions[phoneID] = count - 1
    } else {
      activeInputExecutions.removeValue(forKey: phoneID)
    }
    finalizeInputOwnershipIfQuiescent(phoneID: phoneID)
  }

  private func inputContextIsValid(phoneID: String, context: InputExecutionContext) -> Bool {
    guard started, !stopping,
      context.cancellationGeneration == cancellationGenerations[phoneID, default: 0]
    else { return false }
    if let token = context.token, let generation = context.generation {
      guard let owner = inputOwnership[phoneID], owner.token == token,
        owner.generation == generation, owner.phase != .revoked
      else { return false }
    } else if inputOwnership[phoneID] != nil {
      return false
    }
    return true
  }

  private func requireInputContext(phoneID: String, context: InputExecutionContext) throws {
    guard inputContextIsValid(phoneID: phoneID, context: context) else {
      if context.token != nil {
        throw KitError("INPUT_LEASE_INVALID", "This visual-macro input lease is no longer valid.")
      }
      if context.cancellationGeneration != cancellationGenerations[phoneID, default: 0] {
        throw KitError("CANCELLED", "Action cancelled before input completed.")
      }
      throw KitError("INPUT_OWNED", "Phone input is owned by a visual macro.")
    }
  }

  private func inputWorkIsDrained(phoneID: String) -> Bool {
    let address = attached.first(where: { phone in phone.id == phoneID })?.bluetoothAddress
    let pendingWrites =
      address.flatMap { value in hid.connections[normalizedBluetoothAddress(value)] }?.pendingInputWrites ?? 0
    return (activeInputExecutions[phoneID] ?? 0) == 0
      && (queues[phoneID]?.depth ?? 0) == 0 && pendingWrites == 0
  }

  private func finalizeInputOwnershipIfQuiescent(phoneID: String) {
      guard let owner = inputOwnership[phoneID], owner.phase != .active,
        inputWorkIsDrained(phoneID: phoneID)
      else { return }
      inputOwnership.removeValue(forKey: phoneID)
    }

  private func cancelInputLease(phoneID: String, ownerToken: UUID, generation: UInt64) {
    guard var owner = inputOwnership[phoneID], owner.token == ownerToken,
      owner.generation == generation
    else { return }
    discardCachedActions(phoneID: phoneID, ownerToken: ownerToken, generation: generation)
    inputGeneration &+= 1
    owner.generation = inputGeneration
    owner.phase = .revoked
    inputOwnership[phoneID] = owner
    queues[phoneID]?.cancel()
    neutralizeInput(phoneID: phoneID)
    finalizeInputOwnershipIfQuiescent(phoneID: phoneID)
    record("Exclusive visual-macro input cancelled; held inputs released.")
  }

  private func releaseInputLease(phoneID: String, ownerToken: UUID, generation: UInt64) {
    guard var owner = inputOwnership[phoneID], owner.token == ownerToken,
      owner.generation == generation,
      owner.phase == .active
    else { return }
    owner.phase = .draining
    inputOwnership[phoneID] = owner
    finalizeInputOwnershipIfQuiescent(phoneID: phoneID)
    record("Exclusive visual-macro input released; pending input is draining.")
  }

  private func revokeInputOwnership(phoneID: String, cancelQueue: Bool) {
    // Public input may be waiting for Bluetooth before it reaches the command queue.
    cancellationGenerations[phoneID, default: 0] &+= 1
    guard var owner = inputOwnership[phoneID] else { return }
    discardCachedActions(phoneID: phoneID, ownerToken: owner.token, generation: owner.generation)
    inputGeneration &+= 1
    owner.generation = inputGeneration
    owner.phase = .revoked
    inputOwnership[phoneID] = owner
    if cancelQueue { queues[phoneID]?.cancel() }
    neutralizeInput(phoneID: phoneID)
    finalizeInputOwnershipIfQuiescent(phoneID: phoneID)

  }

  private func neutralizeInput(phoneID: String) {
    guard let address = attached.first(where: { $0.id == phoneID })?.bluetoothAddress,
      let connection = hid.connections[normalizedBluetoothAddress(address)]
    else { return }
    connection.neutralize(epoch: connection.epoch)
  }

  private func discardCachedActions(phoneID: String, ownerToken: UUID, generation: UInt64) {
    let prefix = phoneID + ":"
    let discardedKeys = cached.compactMap { key, entry in
      key.hasPrefix(prefix) && entry.ownerToken == ownerToken && entry.generation == generation
        ? key : nil
    }
    cached = cached.filter { !discardedKeys.contains($0.key) }
    completedKeys.removeAll { discardedKeys.contains($0) }
  }

  public func execute(phoneID: String, command: PhoneCommand) async throws -> ActionResult {
    try await executeInput(phoneID: phoneID, command: command, ownerToken: nil, generation: nil)
  }

  private func executeOwned(
      phoneID: String, command: PhoneCommand, ownerToken: UUID, generation: UInt64,
      authorization: GuardedInput? = nil
    ) async throws -> ActionResult {
      try await executeInput(phoneID: phoneID, command: command, ownerToken: ownerToken,
                             generation: generation, authorization: authorization)
    }

  private func executeInput(
      phoneID: String, command: PhoneCommand, ownerToken: UUID?, generation: UInt64?,
      authorization: GuardedInput? = nil
    ) async throws -> ActionResult {
      guard started, !stopping, phones.contains(where: { phone in phone.id == phoneID }) else {
        throw KitError("PHONE_OFFLINE", "Phone is not connected.")
      }
      try validateInputEntry(phoneID: phoneID, ownerToken: ownerToken, generation: generation)
      if let key = command.idempotencyKey {
        guard (1...128).contains(key.utf8.count) else {
          throw KitError("INVALID_KEY", "idempotency_key must contain 1–128 bytes.")
        }
        let scopedKey = phoneID + ":" + key
        if let entry = cached[scopedKey] {
          let context = try beginInputExecution(phoneID: phoneID, ownerToken: ownerToken, generation: generation)
          defer { finishInputExecution(phoneID: phoneID) }
          guard entry.command == command else {
            throw KitError("IDEMPOTENCY_CONFLICT", "This idempotency key already names a different action.")
          }
          _ = context
          return try await entry.task.value
        }
        while cached.count >= 256, !completedKeys.isEmpty {
          cached.removeValue(forKey: completedKeys.removeFirst())
        }
        guard cached.count < 256 else { throw KitError("QUEUE_FULL", "Too many actions are pending.") }
        let context = try beginInputExecution(phoneID: phoneID, ownerToken: ownerToken, generation: generation)
        let task = Task { @MainActor [self] in
          defer { finishInputExecution(phoneID: phoneID) }
          return try await perform(phoneID: phoneID, command: command, context: context, authorization: authorization)
        }
        cached[scopedKey] = CachedAction(command: command, task: task, ownerToken: ownerToken, generation: generation)
        defer {
          if let entry = cached[scopedKey], entry.ownerToken == ownerToken, entry.generation == generation {
            completedKeys.append(scopedKey)
          }
        }
        return try await task.value
      }
      let context = try beginInputExecution(phoneID: phoneID, ownerToken: ownerToken, generation: generation)
      defer { finishInputExecution(phoneID: phoneID) }
      return try await perform(phoneID: phoneID, command: command, context: context, authorization: authorization)
    }

  private func perform(
      phoneID: String, command: PhoneCommand, context: InputExecutionContext,
      authorization: GuardedInput? = nil
    ) async throws -> ActionResult {
      try requireInputContext(phoneID: phoneID, context: context)
      reconcile()
      try requireInputContext(phoneID: phoneID, context: context)
      guard let currentPhone = phones.first(where: { phone in phone.id == phoneID }) else {
        throw KitError("PHONE_OFFLINE", "Phone is not connected.")
      }
      if command.action != .wake, currentPhone.status != .ready {
        let code = currentPhone.status == .needsWake ? "PHONE_ASLEEP" : "PHONE_NOT_READY"
        throw KitError(code, "The iPhone is not ready for input. Wake it or restore its screen connection first.")
      }
      let reference: Reference?
      if command.action.usesCoordinates {
        guard let id = command.screenshotID, let value = references[id], value.phoneID == phoneID else {
          throw KitError("SCREENSHOT_REQUIRED", "Take a screenshot and pass its screenshot_id with pointer actions.")
        }
        reference = value
      } else {
        reference = nil
      }
      let plan = try GesturePlan.build(command, geometry: reference?.geometry)
      let connection: HIDConnection?
      if isDemo {
        connection = nil
      } else {
        if command.action == .wake,
          let address = attached.first(where: { phone in phone.id == phoneID })?.bluetoothAddress
        {
          try requireInputContext(phoneID: phoneID, context: context)
          try hid.startService()
          prepared.insert(phoneID)
          let wakeLink = hid.connection(address: address)
          wakeLink.enabled = true
          wakeLink.connect(userInitiated: true)
          for _ in 0..<50 where !wakeLink.isReady {
            try Task.checkCancellation()
            try requireInputContext(phoneID: phoneID, context: context)
            try await Task.sleep(for: .milliseconds(100))
          }
        }
        try requireInputContext(phoneID: phoneID, context: context)
        guard prepared.contains(phoneID),
          let address = attached.first(where: { phone in phone.id == phoneID })?.bluetoothAddress,
          let current = hid.connections[normalizedBluetoothAddress(address)], current.isReady
        else {
          throw KitError("BLUETOOTH_DISCONNECTED", "Enable control and pair this Mac in iPhone Settings > Bluetooth.")
        }
        connection = current
      }
      try requireInputContext(phoneID: phoneID, context: context)
      reconcile()
      let expected = epochs[phoneID] ?? 0
      let linkEpoch = connection?.epoch ?? 0
      let deadline = command.deadline ?? Date().addingTimeInterval(65)
      let queue = queues[phoneID] ?? CommandQueue()
      queues[phoneID] = queue
      try requireInputContext(phoneID: phoneID, context: context)
      return try await queue.submit { [self] in
        let start = Date()
        try requireInputContext(phoneID: phoneID, context: context)
        guard !stopping, epochs[phoneID] == expected, deadline > start else {
          throw KitError("CONNECTION_CHANGED", "Action expired or connection changed while queued. Take a fresh screenshot.")
        }
        @MainActor func valid() -> Bool {
          guard inputContextIsValid(phoneID: phoneID, context: context), !stopping,
            epochs[phoneID] == expected
          else { return false }
          guard let current = phones.first(where: { phone in phone.id == phoneID }),
            command.action == .wake || current.status == .ready
          else { return false }
          guard let reference else { return isDemo || attached.contains(where: { phone in phone.id == phoneID }) }
          guard Date().timeIntervalSince(reference.capturedAt) <= 60, reference.epoch == expected else { return false }
          if isDemo { return true }
          guard let captureID = reference.captureID, bindings[phoneID] == captureID,
            let frame = screen.frame(captureID: captureID), frame.geometryGeneration == reference.generation,
            ProcessInfo.processInfo.systemUptime - frame.uptime < 3
          else { return false }
          return true
        }
        guard valid() else { throw KitError("STALE_SCREENSHOT", "Screen changed or screenshot expired. Take a fresh screenshot.") }
        if let connection {
          try await GestureRunner().run(plan, transport: connection, epoch: linkEpoch,
                                        deadline: deadline, stillValid: valid, authorization: authorization)
        } else {
          try Task.checkCancellation()
          try await Task.sleep(for: .milliseconds(20))
          try await authorization?.authorize()
          try Task.checkCancellation()
          try requireInputContext(phoneID: phoneID, context: context)
          guard valid() else { throw KitError("CONNECTION_CHANGED", "Screen or connection changed during validation.") }
          guard deadline > Date() else { throw KitError("DEADLINE_EXCEEDED", "Action deadline expired.") }
          try authorization?.witness.beginDispatch()
          if command.action == .tap {
            demo.checked.toggle()
            demo.home = false
          }
          if command.action == .typeText { demo.text += command.text ?? "" }
          if command.action == .pressHome { demo.home = true }
        }
        try requireInputContext(phoneID: phoneID, context: context)
        if let geometry = reference?.geometry, let x = command.toX ?? command.x,
          let y = command.toY ?? command.y
        {
          pointers[phoneID] = (x / Double(geometry.width), y / Double(geometry.height))
        }
        record("\(command.action.rawValue) input sent.")
        return ActionResult(phoneID: phoneID, action: command.action, status: isDemo ? "simulated" : "sent",
                            startedAt: start, epoch: expected, completedUptime: ProcessInfo.processInfo.systemUptime)
      }
    }

  public func cancel(phoneID: String) {
    // Public cancellation is the emergency stop and is allowed while a lease owns the phone.
    // Revoking the generation prevents work that has not reached the queue from starting later.
    revokeInputOwnership(phoneID: phoneID, cancelQueue: false)
    queues[phoneID]?.cancel()
    neutralizeInput(phoneID: phoneID)
    record("Pending actions cancelled; held inputs released.")
  }

  private func record(_ message: String) {
    events.append(DiagnosticEvent(message))
    if events.count > 100 { events.removeFirst(events.count - 100) }
  }

  public func setKeepAwake(phoneID: String, enabled: Bool) throws {
    guard started, !stopping, let phone = phones.first(where: { $0.id == phoneID }) else {
      throw KitError("PHONE_OFFLINE", "Phone is not connected.")
    }
    if enabled && !isDemo {
      let address = attached.first(where: { $0.id == phoneID })?.bluetoothAddress
      let linkReady =
        address.flatMap { hid.connections[normalizedBluetoothAddress($0)] }?.isReady == true
      guard prepared.contains(phoneID), linkReady, phone.status != .needsTrust else {
        throw KitError(
          "PHONE_NOT_READY", "Enable control and pair Bluetooth before turning on keep-awake.")
      }
    }
    if enabled {
      keepAwakePhoneIDs.insert(phoneID)
      lastActivity[phoneID] = Date()
      lastKeepAwakeAttempt.removeValue(forKey: phoneID)
      keepAwakeErrors.removeValue(forKey: phoneID)
    } else {
      keepAwakePhoneIDs.remove(phoneID)
      lastActivity.removeValue(forKey: phoneID)
      lastKeepAwakePulse.removeValue(forKey: phoneID)
      lastKeepAwakeAttempt.removeValue(forKey: phoneID)
      keepAwakeErrors.removeValue(forKey: phoneID)
    }
    if isDemo, let index = phones.firstIndex(where: { $0.id == phoneID }) {
      phones[index].keepAwake = enabled
    } else {
      reconcile()
    }
    record("Keep-awake \(enabled ? "enabled" : "disabled") for \(phone.name).")
  }

  private func maintainKeepAwake(now: Date = Date()) async {
    let due = keepAwakePhoneIDs.filter {
      KeepAwakePolicy.isDue(
        enabled: true, lastActivity: lastActivity[$0], lastAttempt: lastKeepAwakeAttempt[$0],
        now: now)
    }
    for phoneID in due {
      guard !Task.isCancelled else { return }
      guard keepAwakePhoneIDs.contains(phoneID) else { continue }
      // A visual macro owns the phone until all of its work has drained.
      // Leave lastKeepAwakeAttempt untouched so the pulse resumes after release.
      guard inputOwnership[phoneID] == nil else { continue }
      lastKeepAwakeAttempt[phoneID] = now
      do {
        let result = try await execute(phoneID: phoneID, command: PhoneCommand(action: .wake))
        lastKeepAwakePulse[phoneID] = result.completedAt
        keepAwakeErrors.removeValue(forKey: phoneID)
        reconcile()
      } catch is CancellationError {
        continue
      } catch {
        let message = (error as? KitError)?.message ?? error.localizedDescription
        if keepAwakeErrors[phoneID] != message { record("Keep-awake pulse failed: \(message)") }
        keepAwakeErrors[phoneID] = message
        reconcile()
      }
    }
  }
}
