import Foundation
import CryptoKit

public enum AsarPatcherError: LocalizedError {
    case invalidFileFormat(String)
    case headerParseFailed(String)
    case jsFileNotFound
    case stringDecodingFailed
    case insertionAnchorNotFound
    case serializationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidFileFormat(let msg): return "Invalid ASAR file format: \(msg)"
        case .headerParseFailed(let msg): return "Header parse failed: \(msg)"
        case .jsFileNotFound: return "Could not find index.js in resources.neu assets."
        case .stringDecodingFailed: return "Could not decode JS source code as UTF-8."
        case .insertionAnchorNotFound: return "Could not find insertion anchor for Wine distributions."
        case .serializationFailed: return "JSON serialization failed."
        }
    }
}

public struct AsarPatcher {
    public static let targetRuntimeId = "11.17-zzz-dx12-tuned-stage-parallel-cache-warmup-cursor-rollback-gptk4b2-arm64server"
    public static let targetDisplayName = "Wine 11.17 ZZZ DX12 (GPTK4.0b2)"
    public static let targetArchiveName = "wine-11.17-git.913e31f-zzz-dx12-tuned-d3dmetal-cache-warmup-cursor-rollback-gptk4b2.tar.xz"
    public static let targetArchiveSha256 = "bdc0819cc8e196b139b2352029f7b5d6423a07fdc4d148b238f721f968d1502d"
    public static let targetArchiveSize = 241864652
    public static let targetRuntimeManifestSha256 = "f16ff088947017c05c69bda1e332659119f92d244ffbab5d2bbaedb46689c568"

    public static func patch(
        sourcePath: String,
        outputPath: String,
        userHome: String,
        displayName: String = targetDisplayName
    ) throws {
        let sourceData = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
        guard sourceData.count >= 16 else {
            throw AsarPatcherError.invalidFileFormat("File is too small.")
        }

        let headerSizePlus4 = Int(sourceData.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self) })
        let headerJsonLen = Int(sourceData.subdata(in: 12..<16).withUnsafeBytes { $0.load(as: UInt32.self) })
        let payloadStart = 16 + headerSizePlus4 - 4

        guard sourceData.count >= payloadStart else {
            throw AsarPatcherError.invalidFileFormat("Header size exceeds file size.")
        }

        let headerData = sourceData.subdata(in: 16..<(16 + headerJsonLen))
        guard var headerObj = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              var files = headerObj["files"] as? [String: Any],
              var dist = files["dist"] as? [String: Any],
              var distFiles = dist["files"] as? [String: Any],
              var assets = distFiles["assets"] as? [String: Any],
              var assetFiles = assets["files"] as? [String: Any] else {
            throw AsarPatcherError.headerParseFailed("Could not navigate dist/assets structure.")
        }

        guard let jsKey = assetFiles.keys.first(where: { $0.hasPrefix("index.") && $0.hasSuffix(".js") }),
              var jsMeta = assetFiles[jsKey] as? [String: Any],
              let jsSize = jsMeta["size"] as? Int,
              let jsOffsetStr = jsMeta["offset"] as? String,
              let jsOffset = Int(jsOffsetStr) else {
            throw AsarPatcherError.jsFileNotFound
        }

        let jsEnd = payloadStart + jsOffset + jsSize
        guard sourceData.count >= jsEnd else {
            throw AsarPatcherError.invalidFileFormat("index.js data exceeds file bounds.")
        }

        let jsData = sourceData.subdata(in: (payloadStart + jsOffset)..<jsEnd)
        guard var jsString = String(data: jsData, encoding: .utf8) else {
            throw AsarPatcherError.stringDecodingFailed
        }

        let localUrl = "file://\(userHome)/Library/Application%20Support/Yaagl%20ZZZ%20OS/local-runtimes/\(targetArchiveName)"

        let newEntry: [String: Any] = [
            "id": targetRuntimeId,
            "displayName": displayName,
            "remoteUrl": localUrl,
            "archiveSha256": targetArchiveSha256,
            "archiveSize": targetArchiveSize,
            "wineVersion": "wine-11.17",
            "runtimeManifestSha256": targetRuntimeManifestSha256,
            "attributes": [
                "renderBackend": "d3dmetal",
                "winePath": "wine",
                "precomposedD3DMetal": true,
                "d3dMetalGraphicsCache": true
            ]
        ]

        let newEntryData = try JSONSerialization.data(withJSONObject: newEntry, options: [.sortedKeys])
        guard let newEntryJson = String(data: newEntryData, encoding: .utf8) else {
            throw AsarPatcherError.serializationFailed
        }

        if let idRange = jsString.range(of: "\"id\":\"\(targetRuntimeId)\"") {
            var start = idRange.lowerBound
            while start > jsString.startIndex && jsString[start] != "{" {
                start = jsString.index(before: start)
            }
            var depth = 0
            var end = start
            while end < jsString.endIndex {
                if jsString[end] == "{" { depth += 1 }
                else if jsString[end] == "}" {
                    depth -= 1
                    if depth == 0 {
                        end = jsString.index(after: end)
                        break
                    }
                }
                end = jsString.index(after: end)
            }
            jsString.replaceSubrange(start..<end, with: newEntryJson)
        } else if let p3Range = jsString.range(of: "11.0-d3dmetal-gptk4.0b2-rtx5060-i1") {
            var pos = p3Range.lowerBound
            while pos > jsString.startIndex && jsString[pos] != "{" {
                pos = jsString.index(before: pos)
            }
            var depth = 0
            while pos < jsString.endIndex {
                if jsString[pos] == "{" { depth += 1 }
                else if jsString[pos] == "}" {
                    depth -= 1
                    if depth == 0 {
                        pos = jsString.index(after: pos)
                        break
                    }
                }
                pos = jsString.index(after: pos)
            }
            jsString.insert(contentsOf: ",\(newEntryJson)", at: pos)
        } else {
            throw AsarPatcherError.insertionAnchorNotFound
        }

        let newJsData = jsString.data(using: .utf8)!
        let sizeDelta = newJsData.count - jsData.count

        jsMeta["size"] = newJsData.count
        let jsHash = SHA256.hash(data: newJsData).map { String(format: "%02x", $0) }.joined()
        jsMeta["integrity"] = [
            "algorithm": "SHA256",
            "hash": jsHash
        ]
        assetFiles[jsKey] = jsMeta
        assets["files"] = assetFiles
        distFiles["assets"] = assets
        dist["files"] = distFiles
        files["dist"] = dist

        func adjustOffsets(in dict: inout [String: Any]) {
            guard var f = dict["files"] as? [String: Any] else { return }
            for (k, v) in f {
                if var sub = v as? [String: Any] {
                    if sub["files"] != nil {
                        adjustOffsets(in: &sub)
                        f[k] = sub
                    } else if let offStr = sub["offset"] as? String, let off = Int(offStr) {
                        if off > jsOffset {
                            sub["offset"] = String(off + sizeDelta)
                            f[k] = sub
                        }
                    }
                }
            }
            dict["files"] = f
        }
        adjustOffsets(in: &headerObj)

        let newHeaderJsonData = try JSONSerialization.data(withJSONObject: headerObj, options: [])
        let padLen = (4 - (newHeaderJsonData.count % 4)) % 4
        let headerSize = newHeaderJsonData.count + padLen

        var outputData = Data()
        var u4: UInt32 = 4
        var h8: UInt32 = UInt32(headerSize + 8)
        var h4: UInt32 = UInt32(headerSize + 4)
        var jsonLen: UInt32 = UInt32(newHeaderJsonData.count)

        outputData.append(Data(bytes: &u4, count: 4))
        outputData.append(Data(bytes: &h8, count: 4))
        outputData.append(Data(bytes: &h4, count: 4))
        outputData.append(Data(bytes: &jsonLen, count: 4))
        outputData.append(newHeaderJsonData)
        if padLen > 0 {
            outputData.append(Data(repeating: 0, count: padLen))
        }

        outputData.append(newJsData)
        let remainingOriginalPayload = sourceData.subdata(in: (payloadStart + jsOffset + jsSize)..<sourceData.count)
        outputData.append(remainingOriginalPayload)

        let tempUrl = URL(fileURLWithPath: outputPath + ".tmp.\(UUID().uuidString)")
        try outputData.write(to: tempUrl)
        let destinationUrl = URL(fileURLWithPath: outputPath)
        if FileManager.default.fileExists(atPath: outputPath) {
            _ = try FileManager.default.replaceItemAt(destinationUrl, withItemAt: tempUrl)
        } else {
            try FileManager.default.moveItem(at: tempUrl, to: destinationUrl)
        }
    }
}
