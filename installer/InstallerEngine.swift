import Foundation
import CryptoKit

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
    public static let releaseDownloadUrl = "https://github.com/dbc-hbin/zzz-wine-d3dmetal-dx12/releases/download/v1.0.0/\(AsarPatcher.targetArchiveName)"

    @Published public var appPath: String = defaultAppPath
    @Published public var supportPath: String = defaultSupportPath
    @Published public var status: InstallStatus = InstallStatus()
    @Published public var isWorking: Bool = false
    @Published public var progress: Double = 0.0
    @Published public var currentStep: String = "Ready"
    @Published public var logs: [String] = []

    public init() {
    }

    public func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let formatted = "[\(timestamp)] \(message)"
        if CommandLine.arguments.contains("--cli") || CommandLine.arguments.contains("--install") {
            print(formatted)
        }
        if Thread.isMainThread {
            self.logs.append(formatted)
        } else {
            DispatchQueue.main.async {
                self.logs.append(formatted)
            }
        }
    }

    public func refreshStatus() {
        let fileManager = FileManager.default
        var newStatus = InstallStatus()

        newStatus.yaaglAppExists = fileManager.fileExists(atPath: appPath)
        newStatus.yaaglSupportExists = fileManager.fileExists(atPath: supportPath)

        let runningProcesses = findProcesses(named: "Yaagl ZZZ OS") + findProcesses(named: "wineserver")
        newStatus.yaaglIsRunning = !runningProcesses.isEmpty

        let tagPath = (supportPath as NSString).appendingPathComponent(".storage/wine_tag.neustorage")
        if let tagContent = try? String(contentsOfFile: tagPath, encoding: .utf8) {
            newStatus.currentWineTag = tagContent.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let appBackup = (appPath as NSString).appendingPathComponent("Contents/Resources/resources.neu.bak")
        let supportBackup = (supportPath as NSString).appendingPathComponent("resources.neu.bak")
        newStatus.hasBackup = fileManager.fileExists(atPath: appBackup) || fileManager.fileExists(atPath: supportBackup)

        newStatus.archiveAvailableLocally = findLocalArchive() != nil

        if Thread.isMainThread {
            self.status = newStatus
        } else {
            DispatchQueue.main.async {
                self.status = newStatus
            }
        }
    }

    public func findProcesses(named name: String) -> [Int32] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", name]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            }
        } catch {}
        return []
    }

    public func terminateYaaglProcesses() {
        log("Terminating running Yaagl and Wine processes...")
        let pids = findProcesses(named: "Yaagl ZZZ OS") + findProcesses(named: "wineserver")
        for pid in pids {
            kill(pid, SIGTERM)
        }
        Thread.sleep(forTimeInterval: 0.5)
        refreshStatus()
    }

    public func findLocalArchive() -> String? {
        let fileManager = FileManager.default
        let candidates = [
            (supportPath as NSString).appendingPathComponent("local-runtimes/\(AsarPatcher.targetArchiveName)"),
            (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(AsarPatcher.targetArchiveName),
            (Bundle.main.bundlePath as NSString).appendingPathComponent(AsarPatcher.targetArchiveName),
            ((Bundle.main.resourcePath ?? "") as NSString).appendingPathComponent(AsarPatcher.targetArchiveName),
            (("~/Downloads" as NSString).expandingTildeInPath as NSString).appendingPathComponent(AsarPatcher.targetArchiveName)
        ]
        for path in candidates {
            if fileManager.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    public func sha256OfFile(atPath path: String) -> String? {
        guard let stream = InputStream(fileAtPath: path) else { return nil }
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        let bufferSize = 1024 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: read))
            } else if read < 0 {
                return nil
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func downloadArchive(destinationPath: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: Self.releaseDownloadUrl) else {
            completion(.failure(NSError(domain: "Download", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid download URL."])))
            return
        }

        log("Downloading Wine runtime archive from remote repository...")
        let session = URLSession(configuration: .default)
        let downloadTask = session.downloadTask(with: url) { localUrl, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let localUrl = localUrl else {
                completion(.failure(NSError(domain: "Download", code: 2, userInfo: [NSLocalizedDescriptionKey: "Downloaded file not found."])))
                return
            }
            do {
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: destinationPath) {
                    try fileManager.removeItem(atPath: destinationPath)
                }
                try fileManager.moveItem(at: localUrl, to: URL(fileURLWithPath: destinationPath))
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
        downloadTask.resume()
    }

    public func install(completion: @escaping (Bool, String) -> Void) {
        isWorking = true
        progress = 0.0
        logs.removeAll()
        log("=== Starting Wine 11.17 ZZZ DX12 (GPTK4.0b2) Installation ===")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // 1. Check running processes
                DispatchQueue.main.async {
                    self.currentStep = "[1/5] Checking Yaagl status and running processes..."
                    self.progress = 0.1
                }
                self.log("Yaagl App path: \(self.appPath)")
                self.log("Yaagl Support path: \(self.supportPath)")

                if !FileManager.default.fileExists(atPath: self.appPath) {
                    throw NSError(domain: "Install", code: 10, userInfo: [NSLocalizedDescriptionKey: "Yaagl ZZZ OS.app not found: \(self.appPath)"])
                }
                if !FileManager.default.fileExists(atPath: self.supportPath) {
                    throw NSError(domain: "Install", code: 11, userInfo: [NSLocalizedDescriptionKey: "Yaagl ZZZ OS Support folder not found: \(self.supportPath)"])
                }

                if !self.findProcesses(named: "Yaagl ZZZ OS").isEmpty || !self.findProcesses(named: "wineserver").isEmpty {
                    self.log("Yaagl or Wine processes are active. Terminating safely for installation...")
                    self.terminateYaaglProcesses()
                    Thread.sleep(forTimeInterval: 1.0)
                }

                // 2. Prepare runtime archive
                DispatchQueue.main.async {
                    self.currentStep = "[2/5] Preparing runtime archive & verifying SHA-256..."
                    self.progress = 0.3
                }
                let localRuntimesDir = (self.supportPath as NSString).appendingPathComponent("local-runtimes")
                try FileManager.default.createDirectory(atPath: localRuntimesDir, withIntermediateDirectories: true)
                let destinationArchive = (localRuntimesDir as NSString).appendingPathComponent(AsarPatcher.targetArchiveName)

                if FileManager.default.fileExists(atPath: destinationArchive) {
                    self.log("Checking existing archive in local-runtimes...")
                    let hash = self.sha256OfFile(atPath: destinationArchive)
                    if hash == AsarPatcher.targetArchiveSha256 {
                        self.log("Archive SHA-256 integrity verified.")
                    } else {
                        self.log("Existing archive checksum mismatch. Finding alternative source...")
                        try FileManager.default.removeItem(atPath: destinationArchive)
                    }
                }

                if !FileManager.default.fileExists(atPath: destinationArchive) {
                    if let found = self.findLocalArchive() {
                        self.log("Copying local archive: \(found)")
                        try FileManager.default.copyItem(atPath: found, toPath: destinationArchive)
                    } else {
                        self.log("No local archive found. Downloading from GitHub Releases...")
                        let semaphore = DispatchSemaphore(value: 0)
                        var downloadError: Error?
                        self.downloadArchive(destinationPath: destinationArchive) { result in
                            if case .failure(let err) = result {
                                downloadError = err
                            }
                            semaphore.signal()
                        }
                        semaphore.wait()
                        if let err = downloadError {
                            throw err
                        }
                    }
                    self.log("Verifying SHA-256 checksum of prepared archive...")
                    let hash = self.sha256OfFile(atPath: destinationArchive)
                    guard hash == AsarPatcher.targetArchiveSha256 else {
                        throw NSError(domain: "Install", code: 20, userInfo: [NSLocalizedDescriptionKey: "Archive SHA-256 verification failed: \(hash ?? "none")"])
                    }
                    self.log("Archive SHA-256 verified successfully: \(AsarPatcher.targetArchiveSha256)")
                }

                // 3. Backup resources.neu
                DispatchQueue.main.async {
                    self.currentStep = "[3/5] Creating backups of resources.neu..."
                    self.progress = 0.5
                }
                let appNeuPath = (self.appPath as NSString).appendingPathComponent("Contents/Resources/resources.neu")
                let supportNeuPath = (self.supportPath as NSString).appendingPathComponent("resources.neu")

                let appNeuBackup = appNeuPath + ".bak"
                let supportNeuBackup = supportNeuPath + ".bak"

                if !FileManager.default.fileExists(atPath: appNeuBackup) && FileManager.default.fileExists(atPath: appNeuPath) {
                    try FileManager.default.copyItem(atPath: appNeuPath, toPath: appNeuBackup)
                    self.log("App bundle resources backed up: \(appNeuBackup)")
                }
                if !FileManager.default.fileExists(atPath: supportNeuBackup) && FileManager.default.fileExists(atPath: supportNeuPath) {
                    try FileManager.default.copyItem(atPath: supportNeuPath, toPath: supportNeuBackup)
                    self.log("Support folder resources backed up: \(supportNeuBackup)")
                }

                // 4. Patch resources.neu
                DispatchQueue.main.async {
                    self.currentStep = "[4/5] Registering 'Wine 11.17 ZZZ DX12 (GPTK4.0b2)' in Yaagl..."
                    self.progress = 0.7
                }
                let home = NSHomeDirectory()
                self.log("Patching support folder resources.neu...")
                try AsarPatcher.patch(sourcePath: supportNeuPath, outputPath: supportNeuPath, userHome: home, displayName: AsarPatcher.targetDisplayName)

                if FileManager.default.fileExists(atPath: appNeuPath) {
                    self.log("Synchronizing app bundle resources.neu...")
                    try FileManager.default.removeItem(atPath: appNeuPath)
                    try FileManager.default.copyItem(atPath: supportNeuPath, toPath: appNeuPath)
                }

                // 5. Extract and configure active wine
                DispatchQueue.main.async {
                    self.currentStep = "[5/5] Extracting Wine runtime and configuring environment..."
                    self.progress = 0.85
                }
                let wineDir = (self.supportPath as NSString).appendingPathComponent("wine")
                let wineBackupDir = (self.supportPath as NSString).appendingPathComponent("wine.bak")
                if FileManager.default.fileExists(atPath: wineDir) && !FileManager.default.fileExists(atPath: wineBackupDir) {
                    self.log("Backing up previous Wine directory: \(wineBackupDir)")
                    try? FileManager.default.moveItem(atPath: wineDir, toPath: wineBackupDir)
                }
                try FileManager.default.createDirectory(atPath: wineDir, withIntermediateDirectories: true)

                self.log("Extracting runtime files (tar -xJf)...")
                let tarTask = Process()
                tarTask.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                tarTask.arguments = ["-xJf", destinationArchive, "-C", self.supportPath]
                try tarTask.run()
                tarTask.waitUntilExit()
                if tarTask.terminationStatus != 0 {
                    throw NSError(domain: "Install", code: 30, userInfo: [NSLocalizedDescriptionKey: "Failed to extract Wine archive (exit status: \(tarTask.terminationStatus))"])
                }
                self.log("Wine runtime files extracted successfully.")

                // Set storage keys
                let storageDir = (self.supportPath as NSString).appendingPathComponent(".storage")
                try FileManager.default.createDirectory(atPath: storageDir, withIntermediateDirectories: true)
                let tagPath = (storageDir as NSString).appendingPathComponent("wine_tag.neustorage")
                let statePath = (storageDir as NSString).appendingPathComponent("wine_state.neustorage")
                try AsarPatcher.targetRuntimeId.write(toFile: tagPath, atomically: true, encoding: .utf8)
                try "ready".write(toFile: statePath, atomically: true, encoding: .utf8)
                self.log("Active Wine tag set in Yaagl: \(AsarPatcher.targetRuntimeId)")

                DispatchQueue.main.async {
                    self.progress = 1.0
                    self.currentStep = "Installation Complete!"
                    self.isWorking = false
                    self.refreshStatus()
                    self.log("=== Installation successfully completed! ===")
                    completion(true, "'Wine 11.17 ZZZ DX12 (GPTK4.0b2)' has been successfully installed and activated in Yaagl ZZZ OS!")
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
        logs.removeAll()
        log("=== Starting Backup Restoration ===")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let appNeuPath = (self.appPath as NSString).appendingPathComponent("Contents/Resources/resources.neu")
                let supportNeuPath = (self.supportPath as NSString).appendingPathComponent("resources.neu")
                let appNeuBackup = appNeuPath + ".bak"
                let supportNeuBackup = supportNeuPath + ".bak"

                if FileManager.default.fileExists(atPath: supportNeuBackup) {
                    try? FileManager.default.removeItem(atPath: supportNeuPath)
                    try FileManager.default.copyItem(atPath: supportNeuBackup, toPath: supportNeuPath)
                    self.log("Support folder resources.neu restored.")
                }
                if FileManager.default.fileExists(atPath: appNeuBackup) {
                    try? FileManager.default.removeItem(atPath: appNeuPath)
                    try FileManager.default.copyItem(atPath: appNeuBackup, toPath: appNeuPath)
                    self.log("App bundle resources.neu restored.")
                }

                let wineDir = (self.supportPath as NSString).appendingPathComponent("wine")
                let wineBackupDir = (self.supportPath as NSString).appendingPathComponent("wine.bak")
                if FileManager.default.fileExists(atPath: wineBackupDir) {
                    try? FileManager.default.removeItem(atPath: wineDir)
                    try FileManager.default.moveItem(atPath: wineBackupDir, toPath: wineDir)
                    self.log("Previous Wine directory restored.")
                }

                DispatchQueue.main.async {
                    self.isWorking = false
                    self.currentStep = "Restore Complete"
                    self.refreshStatus()
                    self.log("=== Backup restoration completed successfully! ===")
                    completion(true, "Restored to previous configuration from backup.")
                }
            } catch {
                DispatchQueue.main.async {
                    self.isWorking = false
                    self.refreshStatus()
                    self.log("Restore failed: \(error.localizedDescription)")
                    completion(false, error.localizedDescription)
                }
            }
        }
    }
}
