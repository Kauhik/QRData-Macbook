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

    struct UploadResult {
        let packRecordID: CKRecord.ID
        let version: Int
        let assetCount: Int
    }

    struct PackSummary: Identifiable, Equatable {
        let id: CKRecord.ID
        let recordID: CKRecord.ID
        let recordName: String
        let version: Int
        let creationDate: Date
        let assetCount: Int
        init(record: CKRecord, version: Int, assetCount: Int) {
            self.recordID   = record.recordID
            self.id         = record.recordID
            self.recordName = record.recordID.recordName
            self.version    = version
            self.creationDate = record.creationDate ?? .distantPast
            self.assetCount = assetCount
        }
    }

    // NEW: Asset item for detail view
    struct AssetItem: Identifiable, Hashable {
        let id = UUID()
        let key: String
        let filename: String
        let sha256: String?
        let asset: CKAsset?
    }

    // Accepts a base folder of assets, up to 5 custom URLs, and extra file URLs (e.g., CSVs)
    func uploadPack(
        from folder: URL,
        version: Int,
        customURLs: [URL],
        extraFileURLs: [URL]
    ) async throws -> UploadResult {
        let db = container.publicCloudDatabase

        // Gather files (regular files only)
        let folderFiles = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false }

        // Merge with extra files (e.g., CSVs) and de-duplicate by absoluteString
        var combinedByPath = [String: URL]()
        for url in folderFiles + extraFileURLs {
            combinedByPath[url.absoluteString] = url
        }
        let allFiles = Array(combinedByPath.values)

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
                if base.count > 250 { base = String(base.prefix(250)) } // reserve for suffix
                key = "\(base)_\(i)"
                i += 1
            }
            usedKeys.insert(key)
            return key
        }

        var items: [Manifest.Item] = []
        let record = CKRecord(recordType: "ContentPack")

        for file in allFiles {
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
        record["version"]  = version as CKRecordValue
        record["manifest"] = CKAsset(fileURL: tmp)

        let saved = try await db.save(record)
        try? FileManager.default.removeItem(at: tmp)
        return .init(packRecordID: saved.recordID, version: version, assetCount: items.count)
    }

    func updateBootstrap(toLatest packRecordID: CKRecord.ID,
                         version: Int,
                         bootstrapRecordName: String) async throws {
        let db = container.publicCloudDatabase
        let id = CKRecord.ID(recordName: bootstrapRecordName)
        let existing = try? await db.record(for: id)
        let record = existing ?? CKRecord(recordType: "Bootstrap", recordID: id)
        record["version"]    = version as CKRecordValue
        record["latestPack"] = CKRecord.Reference(recordID: packRecordID, action: .none)
        _ = try await db.save(record)
    }

    func clearBootstrap(bootstrapRecordName: String) async throws {
        let db = container.publicCloudDatabase
        let id = CKRecord.ID(recordName: bootstrapRecordName)
        let record = (try? await db.record(for: id)) ?? CKRecord(recordType: "Bootstrap", recordID: id)
        record["latestPack"] = nil
        record["version"]    = 0 as CKRecordValue
        _ = try await db.save(record)
    }

    func deletePack(recordName: String) async throws {
        let db = container.publicCloudDatabase
        let id = CKRecord.ID(recordName: recordName)
        _ = try await db.deleteRecord(withID: id)
    }

    // MARK: - History helpers (Cloud-driven)

    func fetchBootstrapLatest(bootstrapRecordName: String) async throws -> CKRecord.ID? {
        let db = container.publicCloudDatabase
        let id = CKRecord.ID(recordName: bootstrapRecordName)
        let record = try await db.record(for: id)
        if let ref = record["latestPack"] as? CKRecord.Reference {
            return ref.recordID
        }
        return nil
    }

    func fetchContentPacks(limit: Int = 100) async throws -> [PackSummary] {
        let db = container.publicCloudDatabase

        // Use a predicate that references a QUERYABLE field (version)
        let predicate = NSPredicate(format: "version >= %d", 0)
        let query = CKQuery(recordType: "ContentPack", predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "version", ascending: false)]

        var cursor: CKQueryOperation.Cursor?
        var out: [PackSummary] = []

        repeat {
            let page = try await (cursor != nil
                                  ? db.records(continuingMatchFrom: cursor!)
                                  : db.records(matching: query, desiredKeys: nil))

            for (_, result) in page.matchResults {
                if case .success(let rec) = result {
                    let version = rec["version"] as? Int ?? 0
                    var assetCount = rec.allKeys().filter { $0.hasPrefix("asset_") }.count

                    if assetCount == 0, let manifestAsset = rec["manifest"] as? CKAsset,
                       let url = manifestAsset.fileURL {
                        struct Man: Codable { struct Item: Codable { let key: String; let filename: String; let sha256: String }; let version: Int; let assets: [Item] }
                        if let data = try? Data(contentsOf: url),
                           let man = try? JSONDecoder().decode(Man.self, from: data) {
                            assetCount = man.assets.count
                        }
                    }

                    out.append(.init(record: rec, version: version, assetCount: assetCount))
                }
            }

            cursor = page.queryCursor
        } while cursor != nil && out.count < limit

        return out
    }

    // MARK: - NEW: Detail helpers

    func fetchPackRecord(by id: CKRecord.ID) async throws -> CKRecord {
        try await container.publicCloudDatabase.record(for: id)
    }

    func assetsForPack(record: CKRecord) -> [AssetItem] {
        // Try manifest first for stable filenames and checksums
        var manifestItems: [(key: String, filename: String, sha256: String?)] = []

        if let manifestAsset = record["manifest"] as? CKAsset,
           let murl = manifestAsset.fileURL,
           let data = try? Data(contentsOf: murl) {
            struct Man: Codable { struct Item: Codable { let key: String; let filename: String; let sha256: String }
                let version: Int; let assets: [Item] }
            if let man = try? JSONDecoder().decode(Man.self, from: data) {
                manifestItems = man.assets.map { ($0.key, $0.filename, $0.sha256) }
            }
        }

        // If no manifest, fall back to every field starting with "asset_"
        if manifestItems.isEmpty {
            let assetKeys = record.allKeys().filter { $0.hasPrefix("asset_") }.sorted()
            manifestItems = assetKeys.map { key in
                let filename = (record[key] as? CKAsset)?.fileURL?.lastPathComponent ?? String(key.dropFirst("asset_".count))
                return (key, filename, nil)
            }
        }

        return manifestItems.map { entry in
            let asset = record[entry.key] as? CKAsset
            return AssetItem(key: entry.key, filename: entry.filename, sha256: entry.sha256, asset: asset)
        }
    }

    func customURLStrings(from record: CKRecord) -> [String] {
        if let jsonString = record["customURLs"] as? String,
           let data = jsonString.data(using: .utf8),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            return arr
        }
        return []
    }
}
