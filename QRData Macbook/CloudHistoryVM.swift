//
//  CloudHistoryVM.swift
//  QRData Macbook
//
//  Created by Kaushik Manian on 24/9/

import Foundation
import CloudKit

@MainActor
final class CloudHistoryVM: ObservableObject {
    @Published var packs: [CloudKitUploader.PackSummary] = []
    @Published var currentLatestID: CKRecord.ID?
    @Published var isLoading: Bool = false
    @Published var status: String?

    private let uploader: CloudKitUploader
    private let bootstrapRecordName: String

    init(containerID: String, bootstrapRecordName: String) {
        self.uploader = CloudKitUploader(containerID: containerID)
        self.bootstrapRecordName = bootstrapRecordName
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let packsTask = uploader.fetchContentPacks(limit: 200)
            async let latestTask = uploader.fetchBootstrapLatest(bootstrapRecordName: bootstrapRecordName)
            let (p, latest) = try await (packsTask, latestTask)
            self.packs = p
            self.currentLatestID = latest
            self.status = "Loaded \(p.count) publishes."
        } catch {
            self.status = "Load failed: \(error.localizedDescription)"
        }
    }

    func delete(_ summary: CloudKitUploader.PackSummary) async {
        isLoading = true
        status = "Deleting \(summary.recordName)…"
        defer { isLoading = false }
        do {
            try await uploader.deletePack(recordName: summary.recordName)

            // Recompute history and move Bootstrap to the most recent remaining (or clear it)
            let newPacks = try await uploader.fetchContentPacks(limit: 200)
            self.packs = newPacks
            if let head = newPacks.first {
                try await uploader.updateBootstrap(
                    toLatest: head.recordID,
                    version: head.version,
                    bootstrapRecordName: bootstrapRecordName
                )
                currentLatestID = head.recordID
                status = "Deleted. Bootstrap moved to v\(head.version)."
            } else {
                try await uploader.clearBootstrap(bootstrapRecordName: bootstrapRecordName)
                currentLatestID = nil
                status = "Deleted. Bootstrap cleared."
            }
        } catch {
            status = "Delete failed: \(error.localizedDescription)"
        }
    }
}
