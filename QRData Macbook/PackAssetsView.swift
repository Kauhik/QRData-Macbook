//
//  PackAssetsView.swift
//  QRData Macbook
//
//  Created by Kaushik Manian on 24/9/25.
//

import SwiftUI
import CloudKit
import AppKit
import QuickLookThumbnailing

@MainActor
final class PackAssetsVM: ObservableObject {
    @Published var record: CKRecord?
    @Published var items: [CloudKitUploader.AssetItem] = []
    @Published var customURLs: [URL] = []
    @Published var isLoading = false
    @Published var status: String?

    private let uploader: CloudKitUploader
    private let recordID: CKRecord.ID

    init(containerID: String, recordID: CKRecord.ID) {
        self.uploader = CloudKitUploader(containerID: containerID)
        self.recordID = recordID
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let rec = try await uploader.fetchPackRecord(by: recordID)
            self.record = rec
            self.items  = uploader.assetsForPack(record: rec)
            self.customURLs = uploader.customURLStrings(from: rec).compactMap { URL(string: $0) }
            status = "Loaded \(items.count) assets."
        } catch {
            status = "Load failed: \(error.localizedDescription)"
        }
    }

    func saveAssetToDisk(_ item: CloudKitUploader.AssetItem) {
        guard let src = item.asset?.fileURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.filename
        if panel.runModal() == .OK, let dst = panel.url {
            do {
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.copyItem(at: src, to: dst)
            } catch {
                status = "Save failed: \(error.localizedDescription)"
            }
        }
    }
}

struct PackAssetsView: View {
    let containerID: String
    let summary: CloudKitUploader.PackSummary

    @StateObject private var vm: PackAssetsVM

    init(containerID: String, summary: CloudKitUploader.PackSummary) {
        self.containerID = containerID
        self.summary = summary
        _vm = StateObject(wrappedValue: PackAssetsVM(containerID: containerID, recordID: summary.recordID))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if !vm.customURLs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Custom URLs").font(.headline)
                        ForEach(vm.customURLs, id: \.self) { url in
                            Link(destination: url) {
                                HStack(spacing: 6) {
                                    Image(systemName: "link")
                                    Text(url.absoluteString)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                    }
                }

                if vm.items.isEmpty {
                    Text(vm.isLoading ? "Loading…" : "No assets found.")
                        .foregroundStyle(.secondary)
                } else {
                    assetsGrid
                }

                if let msg = vm.status {
                    Text(msg).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .navigationTitle("v\(summary.version) Assets")
        .task { await vm.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.recordName)
                .font(.caption)
                .textSelection(.enabled)
            Text(summary.creationDate.formatted(date: .abbreviated, time: .standard))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var assetsGrid: some View {
        LazyVGrid(columns: [ GridItem(.adaptive(minimum: 220), spacing: 16, alignment: .top) ],
                  spacing: 16) {
            ForEach(vm.items, id: \.self) { item in
                AssetCard(
                    item: item,
                    onSave: { vm.saveAssetToDisk(item) }
                )
            }
        }
    }
}

// MARK: - Card + thumbnail preview

private struct AssetCard: View {
    let item: CloudKitUploader.AssetItem
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(item.filename)
                .font(.callout)
                .lineLimit(2)
                .textSelection(.enabled)

            if let s = item.sha256 {
                Text("sha256: \(s.prefix(16))…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Button("Open") {
                    if let url = item.asset?.fileURL {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Reveal") {
                    if let url = item.asset?.fileURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                Spacer()
                Button("Save As…", action: onSave)
            }
        }
        .padding(10)
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
        .contextMenu {
            if let url = item.asset?.fileURL {
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button("Save As…", action: onSave)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let url = item.asset?.fileURL {
            ThumbnailView(url: url)
        } else {
            PlaceholderView(text: "No preview")
        }
    }
}

// Generic Quick Look thumbnail view
private struct ThumbnailView: View {
    let url: URL
    @State private var image: NSImage?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            if let img = image {
                Image(nsImage: img).resizable().scaledToFit()
            } else if isLoading {
                ProgressView().controlSize(.small)
            } else {
                PlaceholderView(text: url.pathExtension.uppercased().isEmpty ? "FILE" : url.pathExtension.uppercased())
                    .task { await makeThumbnail() }
            }
        }
        .onAppear {
            if image == nil && !isLoading {
                Task { await makeThumbnail() }
            }
        }
    }

    private func makeThumbnail() async {
        isLoading = true
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 512, height: 512),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, error in
            DispatchQueue.main.async {
                defer { isLoading = false }
                if let cg = rep?.cgImage {
                    let nsimg = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height)))
                    self.image = nsimg
                } else {
                    // fallback to system icon
                    self.image = NSWorkspace.shared.icon(forFile: url.path)
                }
            }
        }
    }
}

private struct PlaceholderView: View {
    let text: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.text.image").font(.system(size: 36))
            Text(text).font(.caption)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
