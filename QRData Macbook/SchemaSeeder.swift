//
//  SchemaSeeder.swift
//  QRData Macbook
//
//  Created by Kaushik Manian on 15/9/25.
//

import Foundation
import CloudKit
import CryptoKit

enum SchemaSeeder {

    // Call this once at app launch or via a button in ContentView
    static func seed(containerID: String, sampleFolder: URL) async throws {
        let container = CKContainer(identifier: containerID)
        let db = container.publicCloudDatabase

        // 1) Build a tiny manifest for whatever is inside sampleFolder
        let files = try FileManager.default.contentsOfDirectory(
            at: sampleFolder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false }

        struct Manifest: Codable {
            struct Item: Codable { let key: String; let filename: String; let sha256: String }
            let version: Int
            let assets: [Item]
        }

        func sha256Hex(_ url: URL) throws -> String {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let hash = SHA256.hash(data: data)
            return hash.map { String(format: "%02x", $0) }.joined()
        }

        // Strict sanitizer for CloudKit field keys
        func sanitizedFieldKey(for filename: String) -> String {
            var core = filename.replacingOccurrences(of: "[^A-Za-z0-9]+",
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
        let packRecord = CKRecord(recordType: "ContentPack")
        for file in files {
            let name = file.lastPathComponent
            let key = uniqueKey(sanitizedFieldKey(for: name))
            let hex = try sha256Hex(file)
            items.append(.init(key: key, filename: name, sha256: hex))
            packRecord[key] = CKAsset(fileURL: file)
        }

        let manifest = Manifest(version: Int(Date().timeIntervalSince1970), assets: items)
        let tmpManifestURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".json")
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: tmpManifestURL, options: .atomic)

        packRecord["version"]  = manifest.version as CKRecordValue
        packRecord["manifest"] = CKAsset(fileURL: tmpManifestURL)

        // 2) Save ContentPack (creates the record type/fields in Development)
        let savedPack = try await db.save(packRecord)

        // 3) Create/update the single Bootstrap record (fixed name)
        let bootstrapID = CKRecord.ID(recordName: "bootstrap-lockerqyes")
        let existing = try? await db.record(for: bootstrapID)
        let bootstrap = existing ?? CKRecord(recordType: "Bootstrap", recordID: bootstrapID)
        bootstrap["version"] = manifest.version as CKRecordValue
        bootstrap["latestPack"] = CKRecord.Reference(recordID: savedPack.recordID, action: .none)
        _ = try await db.save(bootstrap)

        try? FileManager.default.removeItem(at: tmpManifestURL)
    }
}
