import Foundation
import Security
import Darwin
import IPhoneKitCore

public enum TokenStore {
    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/iPhoneKit/api-token")
    }
    public static func loadOrCreate() throws -> String {
        let path = fileURL
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: path.path) { return try read(path) }
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw KitError("TOKEN_FAILED", "Secure token generation failed.") }
        let token = random.map { String(format: "%02x", $0) }.joined()
        let descriptor = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        if descriptor < 0, errno == EEXIST { return try read(path) }
        guard descriptor >= 0 else { throw KitError("TOKEN_FAILED", "Cannot create the local API token.") }
        defer { close(descriptor) }
        let data = Data(token.utf8)
        let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard written == data.count, fsync(descriptor) == 0 else { throw KitError("TOKEN_FAILED", "Cannot save the local API token.") }
        return token
    }
    private static func read(_ path: URL) throws -> String {
        let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw KitError("TOKEN_FAILED", "Cannot read the local API token.") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_size <= 256 else {
            throw KitError("TOKEN_FAILED", "The API token file must be a regular file owned by this user.")
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw KitError("TOKEN_FAILED", "Cannot secure API token permissions.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (32...128).contains(token.utf8.count) else { throw KitError("TOKEN_FAILED", "The API token file is invalid.") }
        return token
    }
}
