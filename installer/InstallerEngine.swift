import Foundation
import Darwin

public struct InstallStatus {
    public var yaaglAppExists: Bool = false
    public var yaaglSupportExists: Bool = false
    public var yaaglIsRunning: Bool = false
    public var currentWineTag: String = ""
    public var hasBackup: Bool = false
    public var archiveAvailableLocally: Bool = false
}

public class InstallerEngine: ObservableObject {
    public static let defaultAppPath = "/Applications/Yaagl ZZZ OS.app"
    public static let defaultSupportPath = ("~/Library/Application Support/Yaagl ZZZ OS" as NSString).expandingTildeInPath
    public static var releaseDownloadUrl: String {
        let archiveName = RuntimePackage.legacyArchiveName
        let encoded = archiveName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? archiveName
        return "https://github.com/dbc-hbin/zzz-wine-d3dmetal-dx12/releases/download/v1.0.0/\(encoded)"
    }

    @Published public var appPath: String = defaultAppPath
    @Published public var supportPath: String = defaultSupportPath
    @Published public var status = InstallStatus()
    @Published public var isWorking = false
    @Published public var progress = 0.0
    @Published public var currentStep = "Ready"
    @Published public var logs: [String] = []

    public init() {}

    public func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let formatted = "[\(timestamp)] \(message)"
        if CommandLine.arguments.contains("--cli") || CommandLine.arguments.contains("--install") {
            print(formatted)
        }
        if Thread.isMainThread {
            logs.append(formatted)
        } else {
            DispatchQueue.main.async { self.logs.append(formatted) }
        }
    }

    public func refreshStatus() {
        let fileManager = FileManager.default
        var newStatus = InstallStatus()
        newStatus.yaaglAppExists = fileManager.fileExists(atPath: appPath)
        newStatus.yaaglSupportExists = fileManager.fileExists(atPath: supportPath)
        newStatus.yaaglIsRunning = !findYaaglProcesses().isEmpty
        let tagPath = (storagePath as NSString).appendingPathComponent("wine_tag.neustorage")
        if let tag = try? String(contentsOfFile: tagPath, encoding: .utf8) {
            newStatus.currentWineTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        newStatus.hasBackup = backupPaths.contains { fileManager.fileExists(atPath: $0) }
        newStatus.archiveAvailableLocally = findLocalArchive() != nil
        if Thread.isMainThread {
            status = newStatus
        } else {
            DispatchQueue.main.async { self.status = newStatus }
        }
    }

    public func findProcesses(matching pattern: String) -> [Int32] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", pattern]
        let output = Pipe()
        task.standardOutput = output
        do {
            try task.run()
            task.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        } catch {
            return []
        }
    }

    public func findYaaglProcesses() -> [Int32] {
        let fileManager = FileManager.default
        let executableDirectory = (appPath as NSString).appendingPathComponent("Contents/MacOS")
        let executableNames = (try? fileManager.contentsOfDirectory(atPath: executableDirectory)) ?? []
        let appProcesses = executableNames.flatMap { executableName in
            findProcesses(matching: "^\(NSRegularExpression.escapedPattern(for: (executableDirectory as NSString).appendingPathComponent(executableName)))([[:space:]]|$)")
        }
        let winePattern = "^\(NSRegularExpression.escapedPattern(for: winePath))(/|[[:space:]]|$)"
        let ignoredProcesses = currentProcessAndAncestors()
        return Array(Set(appProcesses + findProcesses(matching: winePattern))).filter { !ignoredProcesses.contains($0) }
    }

    private func currentProcessAndAncestors() -> Set<Int32> {
        var processIDs: Set<Int32> = [getpid()]
        var currentPID = getpid()
        while currentPID > 1 {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/ps")
            task.arguments = ["-o", "ppid=", "-p", String(currentPID)]
            let output = Pipe()
            task.standardOutput = output
            do {
                try task.run()
                task.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                guard let parentText = String(data: data, encoding: .utf8),
                      let parentPID = Int32(parentText.trimmingCharacters(in: .whitespacesAndNewlines)),
                      parentPID > 1,
                      !processIDs.contains(parentPID) else {
                    break
                }
                processIDs.insert(parentPID)
                currentPID = parentPID
            } catch {
                break
            }
        }
        return processIDs
    }

    public func findLocalArchive() -> String? {
        let fileManager = FileManager.default
        let names = [RuntimePackage.targetArchiveName, RuntimePackage.legacyArchiveName]
        var candidates: [String] = []
        for name in names {
            candidates.append(((Bundle.main.resourcePath ?? "") as NSString).appendingPathComponent(name))
            candidates.append(((Bundle.main.bundlePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name))
            candidates.append((Bundle.main.bundlePath as NSString).appendingPathComponent(name))
            candidates.append((supportPath as NSString).appendingPathComponent("local-runtimes/\(name)"))
            candidates.append((FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(name))
            candidates.append((("~/Downloads" as NSString).expandingTildeInPath as NSString).appendingPathComponent(name))
        }
        return candidates.first { !$0.isEmpty && fileManager.fileExists(atPath: $0) }
    }

    private func bundledArchive() -> String? {
        let fileManager = FileManager.default
        let names = [RuntimePackage.targetArchiveName, RuntimePackage.legacyArchiveName]
        let candidates = names.flatMap { name in
            [
                ((Bundle.main.resourcePath ?? "") as NSString).appendingPathComponent(name),
                ((Bundle.main.bundlePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name),
                (Bundle.main.bundlePath as NSString).appendingPathComponent(name)
            ]
        }
        return candidates.first { !$0.isEmpty && fileManager.fileExists(atPath: $0) }
    }

    public func downloadArchive(destinationPath: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: Self.releaseDownloadUrl) else {
            completion(.failure(NSError(domain: "Install", code: 20, userInfo: [NSLocalizedDescriptionKey: "Invalid runtime download URL."])))
            return
        }
        log("Downloading the prebuilt Wine runtime from GitHub Releases...")
        URLSession.shared.downloadTask(with: url) { temporaryURL, _, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let temporaryURL else {
                completion(.failure(NSError(domain: "Install", code: 21, userInfo: [NSLocalizedDescriptionKey: "The runtime download did not produce a file."])))
                return
            }
            do {
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: destinationPath) {
                    try fileManager.removeItem(atPath: destinationPath)
                }
                try fileManager.moveItem(at: temporaryURL, to: URL(fileURLWithPath: destinationPath))
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    public func install(completion: @escaping (Bool, String) -> Void) {
        isWorking = true
        progress = 0.0
        logs.removeAll()
        log("=== Starting \(RuntimePackage.targetDisplayName) installation ===")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.requireYaaglInstallation()
                try self.requireNoRunningYaaglProcesses()
                DispatchQueue.main.async {
                    self.currentStep = "[1/4] Preparing the runtime archive..."
                    self.progress = 0.15
                }
                let archivePath = try self.installationArchivePath()

                DispatchQueue.main.async {
                    self.currentStep = "[2/4] Extracting Wine into a staging directory..."
                    self.progress = 0.4
                }
                let stagingDirectory = try self.extractRuntime(at: archivePath)
                defer { try? FileManager.default.removeItem(atPath: stagingDirectory) }

                DispatchQueue.main.async {
                    self.currentStep = "[3/4] Registering Wine in Yaagl..."
                    self.progress = 0.6
                }
                let backupsCreated = try self.backUpLauncherConfiguration()
                do {
                    try self.patchLauncherResources(archivePath: archivePath)
                    DispatchQueue.main.async {
                        self.currentStep = "[4/4] Replacing Yaagl's Wine runtime..."
                        self.progress = 0.8
                    }
                    try self.replaceWine(withStagedWineAt: (stagingDirectory as NSString).appendingPathComponent("wine"))
                    try self.activateRegisteredRuntime()
                } catch {
                    self.restoreNewlyCreatedBackups(backupsCreated)
                    throw error
                }

                DispatchQueue.main.async {
                    self.progress = 1.0
                    self.currentStep = "Installation Complete!"
                    self.isWorking = false
                    self.refreshStatus()
                    self.log("=== Installation completed successfully ===")
                    completion(true, "\(RuntimePackage.targetDisplayName) is installed and available in Yaagl's Wine menu.")
                }
            } catch {
                DispatchQueue.main.async {
                    self.progress = 0.0
                    self.currentStep = "Installation Failed"
                    self.isWorking = false
                    self.refreshStatus()
                    self.log("Error: \(error.localizedDescription)")
                    completion(false, error.localizedDescription)
                }
            }
        }
    }

    public func restore(completion: @escaping (Bool, String) -> Void) {
        isWorking = true
        progress = 0.0
        logs.removeAll()
        log("=== Restoring the previous Yaagl Wine configuration ===")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.requireYaaglInstallation()
                try self.requireNoRunningYaaglProcesses()
                guard FileManager.default.fileExists(atPath: self.wineBackupPath) else {
                    throw NSError(domain: "Install", code: 40, userInfo: [NSLocalizedDescriptionKey: "No previous Wine runtime backup is available."])
                }
                try self.restoreLauncherConfiguration()
                try self.restoreWineBackup()
                try self.removeBackups()
                DispatchQueue.main.async {
                    self.isWorking = false
                    self.progress = 1.0
                    self.currentStep = "Restore Complete"
                    self.refreshStatus()
                    self.log("=== Previous Yaagl Wine configuration restored ===")
                    completion(true, "Restored Yaagl's previous Wine runtime and launcher configuration.")
                }
            } catch {
                DispatchQueue.main.async {
                    self.isWorking = false
                    self.progress = 0.0
                    self.currentStep = "Restore Failed"
                    self.refreshStatus()
                    self.log("Restore failed: \(error.localizedDescription)")
                    completion(false, error.localizedDescription)
                }
            }
        }
    }

    private var storagePath: String {
        (supportPath as NSString).appendingPathComponent(".storage")
    }

    private var supportResourcesPath: String {
        (supportPath as NSString).appendingPathComponent("resources.neu")
    }

    private var appResourcesPath: String {
        (appPath as NSString).appendingPathComponent("Contents/Resources/resources.neu")
    }

    private var winePath: String {
        (supportPath as NSString).appendingPathComponent("wine")
    }

    private var wineBackupPath: String {
        winePath + ".bak"
    }

    private var backupPaths: [String] {
        [supportResourcesPath + ".bak", appResourcesPath + ".bak", wineBackupPath,
         (storagePath as NSString).appendingPathComponent("wine_tag.neustorage.bak"),
         (storagePath as NSString).appendingPathComponent("wine_state.neustorage.bak")]
    }

    private func requireYaaglInstallation() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: appPath) else {
            throw NSError(domain: "Install", code: 10, userInfo: [NSLocalizedDescriptionKey: "Yaagl ZZZ OS.app was not found at \(appPath)."])
        }
        guard fileManager.fileExists(atPath: supportPath) else {
            throw NSError(domain: "Install", code: 11, userInfo: [NSLocalizedDescriptionKey: "Yaagl ZZZ OS support folder was not found at \(supportPath)."])
        }
    }

    private func requireNoRunningYaaglProcesses() throws {
        guard findYaaglProcesses().isEmpty else {
            throw NSError(domain: "Install", code: 12, userInfo: [NSLocalizedDescriptionKey: "Quit Yaagl ZZZ OS and its Wine processes before changing the runtime."])
        }
    }

    private func installationArchivePath() throws -> String {
        let fileManager = FileManager.default
        let localRuntimes = (supportPath as NSString).appendingPathComponent("local-runtimes")
        try fileManager.createDirectory(atPath: localRuntimes, withIntermediateDirectories: true)
        let destination = (localRuntimes as NSString).appendingPathComponent(RuntimePackage.targetArchiveName)

        if let bundledArchive = bundledArchive() {
            log("Copying bundled runtime archive to Yaagl: \(bundledArchive)")
            let temporaryDestination = destination + ".tmp.\(UUID().uuidString)"
            do {
                try fileManager.copyItem(atPath: bundledArchive, toPath: temporaryDestination)
                if fileManager.fileExists(atPath: destination) {
                    _ = try fileManager.replaceItemAt(URL(fileURLWithPath: destination), withItemAt: URL(fileURLWithPath: temporaryDestination))
                } else {
                    try fileManager.moveItem(atPath: temporaryDestination, toPath: destination)
                }
            } catch {
                try? fileManager.removeItem(atPath: temporaryDestination)
                throw error
            }
            return destination
        }

        if fileManager.fileExists(atPath: destination) {
            log("Using the existing local runtime archive: \(destination)")
            return destination
        }
        if let source = findLocalArchive() {
            log("Copying prebuilt runtime archive to Yaagl: \(source)")
            try fileManager.copyItem(atPath: source, toPath: destination)
            return destination
        }

        let downloadComplete = DispatchSemaphore(value: 0)
        var downloadError: Error?
        downloadArchive(destinationPath: destination) { result in
            if case .failure(let error) = result {
                downloadError = error
            }
            downloadComplete.signal()
        }
        downloadComplete.wait()
        if let downloadError {
            throw downloadError
        }
        return destination
    }

    private func extractRuntime(at archivePath: String) throws -> String {
        let stagingDirectory = (supportPath as NSString).appendingPathComponent(".wine-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: stagingDirectory, withIntermediateDirectories: false)
        do {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            task.arguments = ["-xJf", archivePath, "-C", stagingDirectory]
            let standardError = Pipe()
            task.standardError = standardError
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else {
                let output = String(data: standardError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let details = output.map { ": \($0)" } ?? ""
                throw NSError(domain: "Install", code: 30, userInfo: [NSLocalizedDescriptionKey: "Failed to extract the Wine runtime (tar exit status \(task.terminationStatus))\(details)"])
            }
            var isDirectory: ObjCBool = false
            let stagedWine = (stagingDirectory as NSString).appendingPathComponent("wine")
            guard FileManager.default.fileExists(atPath: stagedWine, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw NSError(domain: "Install", code: 31, userInfo: [NSLocalizedDescriptionKey: "The runtime archive does not contain the expected wine directory."])
            }
            return stagingDirectory
        } catch {
            try? FileManager.default.removeItem(atPath: stagingDirectory)
            throw error
        }
    }

    private func backUpLauncherConfiguration() throws -> [String] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: supportResourcesPath) else {
            throw NSError(domain: "Install", code: 50, userInfo: [NSLocalizedDescriptionKey: "Yaagl support resources.neu was not found."])
        }
        guard fileManager.fileExists(atPath: appResourcesPath) else {
            throw NSError(domain: "Install", code: 51, userInfo: [NSLocalizedDescriptionKey: "Yaagl app resources.neu was not found."])
        }
        try fileManager.createDirectory(atPath: storagePath, withIntermediateDirectories: true)
        let paths = [supportResourcesPath, appResourcesPath,
                     (storagePath as NSString).appendingPathComponent("wine_tag.neustorage"),
                     (storagePath as NSString).appendingPathComponent("wine_state.neustorage")]
        var created: [String] = []
        for path in paths {
            let backup = path + ".bak"
            if fileManager.fileExists(atPath: backup) { continue }
            if fileManager.fileExists(atPath: path) {
                try fileManager.copyItem(atPath: path, toPath: backup)
            } else {
                guard fileManager.createFile(atPath: backup, contents: Data()) else {
                    throw NSError(domain: "Install", code: 52, userInfo: [NSLocalizedDescriptionKey: "Could not create a backup marker for \(path)."])
                }
            }
            created.append(backup)
        }
        return created
    }

    private func patchLauncherResources(archivePath: String) throws {
        try AsarPatcher.patch(sourcePath: supportResourcesPath, outputPath: supportResourcesPath, archivePath: archivePath, displayName: RuntimePackage.targetDisplayName)
        try AsarPatcher.patch(sourcePath: appResourcesPath, outputPath: appResourcesPath, archivePath: archivePath, displayName: RuntimePackage.targetDisplayName)
    }

    private func replaceWine(withStagedWineAt stagedWine: String) throws {
        let fileManager = FileManager.default
        let displacedWine = (supportPath as NSString).appendingPathComponent(".wine-replaced-\(UUID().uuidString)")
        let hadWine = fileManager.fileExists(atPath: winePath)
        let hasBackup = fileManager.fileExists(atPath: wineBackupPath)
        if hadWine {
            let destination = hasBackup ? displacedWine : wineBackupPath
            log(hasBackup ? "Temporarily moving the active Wine runtime aside." : "Preserving the previous Wine runtime.")
            try fileManager.moveItem(atPath: winePath, toPath: destination)
        }
        do {
            try fileManager.moveItem(atPath: stagedWine, toPath: winePath)
        } catch {
            if hadWine {
                let displaced = hasBackup ? displacedWine : wineBackupPath
                if fileManager.fileExists(atPath: displaced) {
                    do {
                        try fileManager.moveItem(atPath: displaced, toPath: winePath)
                    } catch {
                        throw NSError(domain: "Install", code: 32, userInfo: [NSLocalizedDescriptionKey: "Could not install the new Wine runtime and could not restore the previous runtime: \(error.localizedDescription)"])
                    }
                }
            }
            throw error
        }
        if hadWine && hasBackup {
            try fileManager.removeItem(atPath: displacedWine)
        }
    }

    private func activateRegisteredRuntime() throws {
        let tagPath = (storagePath as NSString).appendingPathComponent("wine_tag.neustorage")
        let statePath = (storagePath as NSString).appendingPathComponent("wine_state.neustorage")
        try RuntimePackage.targetRuntimeId.write(toFile: tagPath, atomically: true, encoding: .utf8)
        try "ready".write(toFile: statePath, atomically: true, encoding: .utf8)
        log("Selected \(RuntimePackage.targetDisplayName) in Yaagl's Wine menu.")
    }

    private func restoreWineBackup() throws {
        let fileManager = FileManager.default
        let displacedWine = (supportPath as NSString).appendingPathComponent(".wine-restore-\(UUID().uuidString)")
        let hadWine = fileManager.fileExists(atPath: winePath)
        if hadWine {
            try fileManager.moveItem(atPath: winePath, toPath: displacedWine)
        }
        do {
            try fileManager.moveItem(atPath: wineBackupPath, toPath: winePath)
        } catch {
            if hadWine, fileManager.fileExists(atPath: displacedWine) {
                do {
                    try fileManager.moveItem(atPath: displacedWine, toPath: winePath)
                } catch {
                    throw NSError(domain: "Install", code: 41, userInfo: [NSLocalizedDescriptionKey: "Could not restore the previous Wine runtime and could not restore the installed runtime: \(error.localizedDescription)"])
                }
            }
            throw error
        }
        if hadWine {
            try fileManager.removeItem(atPath: displacedWine)
        }
    }

    private func restoreLauncherConfiguration() throws {
        for path in [supportResourcesPath, appResourcesPath,
                     (storagePath as NSString).appendingPathComponent("wine_tag.neustorage"),
                     (storagePath as NSString).appendingPathComponent("wine_state.neustorage")] {
            let backup = path + ".bak"
            guard FileManager.default.fileExists(atPath: backup) else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: backup)
            if let size = attributes[.size] as? NSNumber, size.intValue == 0 {
                if FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.removeItem(atPath: path)
                }
            } else {
                if FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.removeItem(atPath: path)
                }
                try FileManager.default.copyItem(atPath: backup, toPath: path)
            }
        }
    }

    private func restoreNewlyCreatedBackups(_ backups: [String]) {
        for backup in backups {
            let path = String(backup.dropLast(4))
            if FileManager.default.fileExists(atPath: backup) {
                try? restoreBackup(at: backup, to: path)
                try? FileManager.default.removeItem(atPath: backup)
            }
        }
    }

    private func restoreBackup(at backup: String, to path: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: backup)
        if let size = attributes[.size] as? NSNumber, size.intValue == 0 {
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
        } else {
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
            try FileManager.default.copyItem(atPath: backup, toPath: path)
        }
    }

    private func removeBackups() throws {
        for backup in backupPaths where FileManager.default.fileExists(atPath: backup) {
            try FileManager.default.removeItem(atPath: backup)
        }
    }
}
