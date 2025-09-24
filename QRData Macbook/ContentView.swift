//
//  ContentView.swift
//  QRData Macbook
//
//  Created by Kaushik Manian on 15/9/25.
//

import SwiftUI
import CloudKit
import AppKit

struct ContentView: View {

    // ==== Configure this once ====
    private let containerID = "iCloud.com.kaushikmanian.LockerQ"
    private let bootstrapRecordName = "bootstrap-lockerqyes"

    // ==== UI state ====
    @State private var folderURL: URL?
    @State private var version: Int = Int(Date().timeIntervalSince1970)
    @State private var status: String = "Select a folder and Publish."
    @State private var latestQR: NSImage?
    @State private var customURLString: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("PackBuilder").font(.largeTitle).bold()

            HStack(spacing: 12) {
                Button("Choose Folder…", action: pickFolder)
                Text(folderURL?.path(percentEncoded: false) ?? "No folder selected")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            HStack(spacing: 12) {
                Text("Version:")
                TextField("Version", value: $version, formatter: NumberFormatter())
                    .textFieldStyle(.roundedBorder).frame(width: 160)
                Spacer()
                Button("Seed Schema…") { Task { await seedSchema() } }
                Button("Publish to CloudKit") { Task { await publish() } }
                    .keyboardShortcut(.defaultAction)
            }

            HStack(spacing: 12) {
                Text("Custom URL (optional):")
                TextField("https://example.com/page", text: $customURLString)
                    .textFieldStyle(.roundedBorder)
            }

            Text(status).font(.callout).foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            if let img = latestQR {
                Image(nsImage: img).interpolation(.none)
                    .resizable().frame(width: 240, height: 240)
                    .border(.gray)
                Button("Save QR as PNG…") { saveQR(img) }
            }

            Spacer()
        }
        .padding(20)
    }

    // MARK: - Actions

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            folderURL = panel.urls.first
        }
    }

    private func seedSchema() async {
        guard let folder = folderURL else { status = "Pick a folder first."; return }
        status = "Seeding schema…"
        do {
            try await SchemaSeeder.seed(containerID: containerID, sampleFolder: folder)
            status = "Schema seeded in Development."
        } catch {
            status = "Seed failed: \(error.localizedDescription)"
        }
    }

    private func publish() async {
        guard let folder = folderURL else { status = "Pick a folder first."; return }
        status = "Uploading pack…"
        do {
            let uploader = CloudKitUploader(containerID: containerID)
            let trimmed = customURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = trimmed.isEmpty ? nil : URL(string: trimmed)
            let res = try await uploader.uploadPack(from: folder, version: version, customURL: url)
            try await uploader.updateBootstrap(toLatest: res.packRecordID,
                                               version: res.version,
                                               bootstrapRecordName: bootstrapRecordName)
            let qrString = "lockerqyes://bootstrap?container=\(containerID)&record=\(bootstrapRecordName)"
            guard let img = QRGenerator.makeQR(from: qrString, scale: 10) else {
                status = "Published v\(res.version), but QR failed."
                return
            }
            latestQR = img
            status = "Published v\(res.version). QR ready."
        } catch {
            status = "Publish failed: \(error.localizedDescription)"
        }
    }

    private func saveQR(_ image: NSImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "LockerQYes-Bootstrap-QR.png"
        if panel.runModal() == .OK, let url = panel.url {
            do { try QRGenerator.savePNG(image, to: url) }
            catch { status = "Save failed: \(error.localizedDescription)" }
        }
    }
}

#Preview {
    ContentView()
}
