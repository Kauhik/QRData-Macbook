//
//  CloudKitUploader.swift
//  QRData Macbook
//
//  Created by Kaushik Manian on 15/9/25.
//

import Foundation
import CloudKit
import CryptoKit

struct CloudKitUploader {
    let container: CKContainer

    init(containerID: String) {
        self.container = CKContainer(identifier: containerID)
    }

    struct UploadResult { let packRecordID: CKRecord.ID; let version: Int }

    // Added `customURLs` (up to 5)
    func uploadPack(from folder: URL, version: Int, customURLs: [URL]) async throws -> UploadResult {
        let db = container.publicCloudDatabase

        // Gather files (regular files only)
        let files = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false }

        // Build manifest + CKRecord
        struct Manifest: Codable {
            struct Item: Codable { let key: String; let filename: String; let sha256: String }
            let version: Int; let assets: [Item]
        }

        func sha256Hex(_ url: URL) throws -> String {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let hash = SHA256.hash(data: data)
            return hash.map { String(format: "%02x", $0) }.joined()
        }

        // Sanitizer for CKRecord field keys: allow [A-Za-z0-9_], ensure <= 255, unique per record
        func sanitizedFieldKey(for filename: String) -> String {
            let baseName = filename
            var core = baseName.replacingOccurrences(of: "[^A-Za-z0-9]+",
                                                     with: "_",
                                                     options: .regularExpression)
            core = core.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            if core.isEmpty { core = "file" }
            var key = "asset_" + core
            if key.count > 255 { key = String(key.prefix(255)) }
            return key
        }

        var usedKeys = Set<String>()
        func uniqueKey(_ proposed: String) -> String {
            var key = proposed
            var i = 2
            while usedKeys.contains(key) {
                var base = proposed
                if base.count > 250 { base = String(base.prefix(250)) }
                key = "\(base)_\(i)"
                i += 1
            }
            usedKeys.insert(key)
            return key
        }

        var items: [Manifest.Item] = []
        let record = CKRecord(recordType: "ContentPack")

        for file in files {
            let name = file.lastPathComponent
            let key = uniqueKey(sanitizedFieldKey(for: name))
            let hex = try sha256Hex(file)
            items.append(.init(key: key, filename: name, sha256: hex))
            record[key] = CKAsset(fileURL: file)
        }

        // Store up to 5 URLs as a JSON-encoded string field "customURLs"
        let limited = Array(customURLs.prefix(5)).map { $0.absoluteString }
        if !limited.isEmpty {
            let json = try JSONEncoder().encode(limited)
            if let jsonString = String(data: json, encoding: .utf8) {
                record["customURLs"] = jsonString as CKRecordValue
            }
        }

        let manifest = Manifest(version: version, assets: items)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".json")
        try JSONEncoder().encode(manifest).write(to: tmp, options: .atomic)
        record["version"] = version as CKRecordValue
        record["manifest"] = CKAsset(fileURL: tmp)

        let saved = try await db.save(record)
        try? FileManager.default.removeItem(at: tmp)
        return .init(packRecordID: saved.recordID, version: version)
    }

    func updateBootstrap(toLatest packRecordID: CKRecord.ID,
                         version: Int,
                         bootstrapRecordName: String) async throws {
        let db = container.publicCloudDatabase
        let id = CKRecord.ID(recordName: bootstrapRecordName)
        let existing = try? await db.record(for: id)
        let record = existing ?? CKRecord(recordType: "Bootstrap", recordID: id)
        record["version"] = version as CKRecordValue
        record["latestPack"] = CKRecord.Reference(recordID: packRecordID, action: .none)
        _ = try await db.save(record)
    }
}
