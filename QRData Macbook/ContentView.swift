//
//  ContentView.swift
//  QRData Macbook
//
//  Created by Kaushik Manian on 15/9/25.
//

import SwiftUI
import CloudKit
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {

    // ==== Configure this once ====
    private let containerID = "iCloud.com.kaushikmanian.LockerQ"
    private let bootstrapRecordName = "bootstrap-lockerqyes"     // fixed durable name

    // ==== UI state ====
    @State private var folderURL: URL?
    @State private var version: Int = Int(Date().timeIntervalSince1970)
    @State private var status: String = "Select a folder and Publish."
    @State private var latestQR: NSImage?

    // Custom URLs (up to 5)
    @State private var customURLStrings: [String] = Array(repeating: "", count: 5)

    // Exactly 3 CSV inputs (no drag & drop)
    @State private var csvURL1: URL?
    @State private var csvURL2: URL?
    @State private var csvURL3: URL?

    var body: some View {
        ScrollView { // allow vertical scrolling
            VStack(alignment: .leading, spacing: 16) {
                Text("PackBuilder").font(.largeTitle).bold()

                // Asset folder picker
                HStack(spacing: 12) {
                    Button("Choose Folder…", action: pickFolder)
                    Text(folderURL?.path(percentEncoded: false) ?? "No folder selected")
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }

                // Version and actions
                HStack(spacing: 12) {
                    Text("Version:")
                    TextField("Version", value: $version, formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder).frame(width: 160)
                    Spacer()
                    Button("Seed Schema…") { Task { await seedSchema() } }
                    Button("Publish to CloudKit") { Task { await publish() } }
                        .keyboardShortcut(.defaultAction)
                }

                // Custom URLs
                VStack(alignment: .leading, spacing: 8) {
                    Text("Custom URLs (up to 5, optional):")
                    ForEach(0..<5, id: \.self) { idx in
                        TextField("https://example.com/page", text: $customURLStrings[idx])
                            .textFieldStyle(.roundedBorder)
                    }
                }

                // Three CSV selectors (no drag & drop)
                VStack(alignment: .leading, spacing: 10) {
                    Text("CSV Files (exactly 3 inputs; optional):")

                    csvRow(title: "Choose CSV 1…", url: $csvURL1)
                    csvRow(title: "Choose CSV 2…", url: $csvURL2)
                    csvRow(title: "Choose CSV 3…", url: $csvURL3)

                    HStack {
                        Button("Clear CSVs") {
                            csvURL1 = nil; csvURL2 = nil; csvURL3 = nil
                        }
                        Spacer()
                        Text(csvSummaryText).font(.callout).foregroundStyle(.secondary)
                    }
                }

                Text(status).font(.callout).foregroundStyle(.secondary)

                Divider().padding(.vertical, 4)

                if let img = latestQR {
                    Image(nsImage: img).interpolation(.none)
                        .resizable().frame(width: 240, height: 240)
                        .border(.gray)
                    Button("Save QR as PNG…") { saveQR(img) }
                }

                Spacer(minLength: 20)
            }
            .padding(20)
        }
    }

    // MARK: - Small subviews

    @ViewBuilder
    private func csvRow(title: String, url: Binding<URL?>) -> some View {
        HStack(spacing: 12) {
            Button(title) { chooseCSV(for: url) }
            Text(url.wrappedValue?.lastPathComponent ?? "No file selected")
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
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

    private func chooseCSV(for binding: Binding<URL?>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.commaSeparatedText]
        if panel.runModal() == .OK {
            binding.wrappedValue = panel.url
        }
    }

    private var csvSummaryText: String {
        let count = [csvURL1, csvURL2, csvURL3].compactMap { $0 }.count
        return "\(count)/3 selected"
    }

    private func selectedCSVURLs() -> [URL] {
        [csvURL1, csvURL2, csvURL3].compactMap { $0 }
    }

    private func seedSchema() async {
        guard let folder = folderURL else { status = "Pick a folder first."; return }
        status = "Seeding schema…"
        do {
            try await SchemaSeeder.seed(
                containerID: containerID,
                sampleFolder: folder,
                extraCSVURLs: selectedCSVURLs()
            )
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

            let urls = customURLStrings
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .compactMap { URL(string: $0) }

            let res = try await uploader.uploadPack(
                from: folder,
                version: version,
                customURLs: Array(urls.prefix(5)),
                extraFileURLs: selectedCSVURLs()
            )

            try await uploader.updateBootstrap(
                toLatest: res.packRecordID,
                version: res.version,
                bootstrapRecordName: bootstrapRecordName
            )

            // Build bootstrap QR deep link
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
