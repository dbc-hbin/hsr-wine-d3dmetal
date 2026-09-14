import Foundation

@main
private struct RegistrationCommand {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count == 4, arguments[0] == "--resource-path", arguments[2] == "--archive-path",
                  arguments[1].hasPrefix("/"), arguments[3].hasPrefix("/") else {
                throw NSError(domain: "Registration", code: 10, userInfo: [NSLocalizedDescriptionKey:
                    "Usage: hsr-wine-register --resource-path ABSOLUTE_UPDATE_PATH --archive-path ABSOLUTE_ARCHIVE_PATH"])
            }
            let resource = URL(fileURLWithPath: arguments[1]).standardizedFileURL
            let archive = URL(fileURLWithPath: arguments[3]).standardizedFileURL
            let archiveDirectory = archive.deletingLastPathComponent()
            let support = archiveDirectory.deletingLastPathComponent()
            guard archiveDirectory.lastPathComponent == "local-runtimes",
                  resource == support.appendingPathComponent("resources.neu.update") else {
                throw NSError(domain: "Registration", code: 11, userInfo: [NSLocalizedDescriptionKey:
                    "Only the pending Yaagl resource update beside the local runtime archive can be registered."])
            }
            let current = support.appendingPathComponent("resources.neu")
            let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
            let currentDate = attributes[.modificationDate] as? Date ?? Date()
            try ResourceRegistration.register(resourcePath: resource.path, archivePath: archive.path,
                backupDirectory: support.appendingPathComponent(".hsr-wine-registration/backups").path)
            // Keep the updated resource newer than the active version, which the
            // installer already made newer than the app bundle's rsync source.
            try FileManager.default.setAttributes([.modificationDate: max(Date(), currentDate.addingTimeInterval(1))],
                                                   ofItemAtPath: resource.path)
            print("Wine registration preserved in the pending Yaagl update.")
        } catch {
            FileHandle.standardError.write(Data(("Wine registration update failed: \(error.localizedDescription)\n").utf8))
            exit(EXIT_FAILURE)
        }
    }
}
