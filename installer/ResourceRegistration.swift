import CryptoKit
import Foundation

/// Keeps each installed frontend paired with its own pre-registration resource.
/// Pending updates must not replace the backup for the currently running version.
enum ResourceRegistration {
    static func register(resourcePath: String, archivePath: String, backupDirectory: String) throws {
        let manager = FileManager.default
        let resource = URL(fileURLWithPath: resourcePath)
        let original = try Data(contentsOf: resource)
        let originalHash = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        let backups = URL(fileURLWithPath: backupDirectory, isDirectory: true)
        let previousBackup = backups.appendingPathComponent(originalHash + ".neu")
        let pristine: Data
        if manager.fileExists(atPath: previousBackup.path) {
            pristine = try Data(contentsOf: previousBackup)
        } else {
            guard original.range(of: Data("__yaaglD3MetalUpdate".utf8)) == nil else {
                throw NSError(domain: "Registration", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "The registered Yaagl frontend was changed without a matching backup. Its current resources have been preserved. Update Yaagl with an official resource before registering again."])
            }
            pristine = original
        }

        let staging = resource.deletingLastPathComponent().appendingPathComponent(".wine-registration-\(UUID().uuidString).neu")
        defer { try? manager.removeItem(at: staging) }
        try AsarPatcher.patch(sourcePath: resourcePath, outputPath: staging.path,
                              archivePath: archivePath, displayName: RuntimePackage.targetDisplayName)
        let patched = try Data(contentsOf: staging)
        let patchedHash = SHA256.hash(data: patched).map { String(format: "%02x", $0) }.joined()
        let backup = backups.appendingPathComponent(patchedHash + ".neu")
        try manager.createDirectory(at: backups, withIntermediateDirectories: true)
        if !manager.fileExists(atPath: backup.path) {
            try pristine.write(to: backup, options: .atomic)
        }
        // Never publish a frontend for which restoring the same version is impossible.
        guard try Data(contentsOf: backup) == pristine else {
            throw NSError(domain: "Registration", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "The Yaagl registration backup does not match this frontend. No resource was replaced."])
        }
        if patched != original {
            _ = try manager.replaceItemAt(resource, withItemAt: staging)
        }
    }

    struct RestorePlan {
        fileprivate let current: Data
        fileprivate let original: Data?

        var restoresRegisteredResource: Bool { original != nil }
    }

    /// Validates that the current resource can be safely detached without changing it.
    static func prepareRestore(resourcePath: String, backupDirectory: String, archivePath: String? = nil) throws -> RestorePlan {
        let resource = URL(fileURLWithPath: resourcePath)
        let current = try Data(contentsOf: resource)
        let hash = SHA256.hash(data: current).map { String(format: "%02x", $0) }.joined()
        let backup = URL(fileURLWithPath: backupDirectory, isDirectory: true).appendingPathComponent(hash + ".neu")
        guard FileManager.default.fileExists(atPath: backup.path) else {
            guard current.range(of: Data("__yaaglD3MetalUpdate".utf8)) == nil else {
                throw NSError(domain: "Registration", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    "Yaagl's registered frontend has changed. Restore cannot safely remove its update helper; the frontend and helper have been preserved."])
            }
            return RestorePlan(current: current, original: nil)
        }
        let original = try Data(contentsOf: backup)
        guard original.range(of: Data("__yaaglD3MetalUpdate".utf8)) == nil else {
            throw NSError(domain: "Registration", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "The saved frontend still requires the registration helper. Restore was stopped without replacing it."])
        }
        if let archivePath {
            let verification = resource.deletingLastPathComponent().appendingPathComponent(".wine-unregister-check-\(UUID().uuidString).neu")
            defer { try? FileManager.default.removeItem(at: verification) }
            try original.write(to: verification, options: .withoutOverwriting)
            try AsarPatcher.patch(sourcePath: verification.path, outputPath: verification.path,
                                  archivePath: archivePath, displayName: RuntimePackage.targetDisplayName)
            guard try AsarPatcher.contentsEquivalent(Data(contentsOf: verification), current) else {
                throw NSError(domain: "Registration", code: 6, userInfo: [NSLocalizedDescriptionKey:
                    "The saved frontend backup does not reproduce the installed registration. Nothing was removed."])
            }
        }
        return RestorePlan(current: current, original: original)
    }

    /// Applies a previously validated plan only if the resource is unchanged.
    @discardableResult
    static func restore(resourcePath: String, plan: RestorePlan) throws -> Bool {
        let resource = URL(fileURLWithPath: resourcePath)
        guard try Data(contentsOf: resource) == plan.current else {
            throw NSError(domain: "Registration", code: 5, userInfo: [NSLocalizedDescriptionKey:
                "Yaagl's resources changed after uninstall validation. Nothing was removed."])
        }
        guard let original = plan.original else { return false }
        try original.write(to: resource, options: .atomic)
        return true
    }

    /// Returns false when an upstream update already replaced our registered resource.
    @discardableResult
    static func restore(resourcePath: String, backupDirectory: String, archivePath: String? = nil) throws -> Bool {
        try restore(resourcePath: resourcePath, plan: prepareRestore(resourcePath: resourcePath, backupDirectory: backupDirectory, archivePath: archivePath))
    }
}
