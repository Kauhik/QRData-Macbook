//
//  PublishHistory.swift
//  QRData Macbook
//
//  Created by Kaushik Manian on 24/9/25.
//

import Foundation

struct PublishRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let version: Int
    let recordName: String
    let assetCount: Int
    let urlsCount: Int
    let csvCount: Int
}

final class PublishHistory: ObservableObject {
    @Published private(set) var items: [PublishRecord] = []
    private let key = "LockerQYes_PublishHistory"

    init() { load() }

    func add(version: Int, recordName: String, assetCount: Int, urlsCount: Int, csvCount: Int, date: Date = .now) {
        let rec = PublishRecord(id: UUID(), date: date, version: version, recordName: recordName, assetCount: assetCount, urlsCount: urlsCount, csvCount: csvCount)
        items.append(rec)
        save()
    }

    func remove(_ record: PublishRecord) {
        items.removeAll { $0.id == record.id }
        save()
    }

    var latest: PublishRecord? {
        items.sorted(by: { $0.date > $1.date }).first
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        if let decoded = try? JSONDecoder().decode([PublishRecord].self, from: data) {
            items = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
