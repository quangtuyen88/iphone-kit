import Foundation
import IPhoneKitCore

public struct MacroStore {
    private struct Envelope: Codable {
        let version: Int
        let profiles: [MacroProfile]
    }

    private static let currentVersion = 1
    private static let maximumFileBytes = 64 * 1024 * 1024
    private static let maximumProfiles = 100
    private static let maximumImageBytes = 48 * 1024 * 1024

    private let url: URL

    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support", isDirectory: true)
            self.url = base.appendingPathComponent("iPhoneKit", isDirectory: true).appendingPathComponent("macros.json")
        }
    }

    public func load() throws -> [MacroProfile] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return [] }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try manager.attributesOfItem(atPath: url.path)
        } catch {
            throw storeError("Cannot inspect the saved macro file.")
        }
        if let type = attributes[.type] as? FileAttributeType, type != .typeRegular {
            throw storeError("The saved macro path is not a regular file.")
        }
        guard let size = (attributes[.size] as? NSNumber)?.intValue,
              size >= 0, size <= Self.maximumFileBytes else {
            throw storeError("The saved macro file exceeds the storage limit.")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw storeError("Cannot read the saved macro file.")
        }
        guard data.count <= Self.maximumFileBytes else {
            throw storeError("The saved macro file exceeds the storage limit.")
        }
        let envelope: Envelope
        do {
            envelope = try KitJSON.decoder().decode(Envelope.self, from: data)
        } catch {
            // Never replace or silently reset a corrupt file. The caller can surface this
            // error and decide how to recover.
            throw storeError("The saved macro file is corrupt or has an unsupported format.")
        }
        guard envelope.version == Self.currentVersion else {
            throw storeError("The saved macro file uses an unsupported version.")
        }
        try validateProfiles(envelope.profiles)
        return envelope.profiles
    }

    public func save(_ profiles: [MacroProfile]) throws {
        try validateProfiles(profiles)
        let envelope = Envelope(version: Self.currentVersion, profiles: profiles)
        let data: Data
        do {
            data = try KitJSON.encoder().encode(envelope)
        } catch {
            throw storeError("The macro data could not be encoded.")
        }
        guard data.count <= Self.maximumFileBytes else {
            throw storeError("The macro data exceeds the storage limit.")
        }

        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            // A pre-existing corrupt destination is never overwritten by a save. This
            // check also ensures a destination changed between load and save is noticed.
            if manager.fileExists(atPath: url.path) { _ = try load() }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch let error as KitError {
            throw error
        } catch {
            throw storeError("Cannot prepare the private macro directory.")
        }

        let temporary = directory.appendingPathComponent(".macros-\(UUID().uuidString).tmp")
        var temporaryExists = false
        defer {
            if temporaryExists { try? manager.removeItem(at: temporary) }
        }
        do {
            try data.write(to: temporary, options: [.atomic])
            temporaryExists = true
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if manager.fileExists(atPath: url.path) {
                _ = try manager.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: [])
            } else {
                try manager.moveItem(at: temporary, to: url)
            }
            temporaryExists = false
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch let error as KitError {
            throw error
        } catch {
            throw storeError("Cannot atomically save the macro file.")
        }
    }

    private func validateProfiles(_ profiles: [MacroProfile]) throws {
        guard profiles.count <= Self.maximumProfiles else {
            throw storeError("A macro store may contain at most 100 profiles.")
        }
        guard Set(profiles.map(\.id)).count == profiles.count else {
            throw storeError("Macro profiles must have unique IDs.")
        }
        var imageBytes = 0
        for profile in profiles {
            do {
                // Empty profiles are intentionally accepted here as persisted drafts;
                // normal execution/UI validation uses the default allowDraft: false.
                try profile.validate(allowDraft: true)
            } catch {
                throw storeError("A saved macro profile failed validation.")
            }
            for step in profile.steps {
                imageBytes += step.before.image.count
                imageBytes += step.after.image.count
            }
            if let stopWhen = profile.stopWhen { imageBytes += stopWhen.image.count }
            guard imageBytes <= Self.maximumImageBytes else {
                throw storeError("Saved macro images exceed the storage limit.")
            }
        }
    }

    private func storeError(_ message: String) -> KitError {
        KitError("MACRO_STORE_ERROR", message)
    }
}
