import Foundation

/// クリップボード履歴の1エントリ。
/// JSON で永続化するため Codable に準拠。
struct ClipItem: Codable, Identifiable, Sendable {
    let id: UUID
    let text: String
    let copiedAt: Date

    init(text: String) {
        self.id = UUID()
        self.text = text
        self.copiedAt = Date()
    }
}

/// クリップボード履歴をメモリ上に保持し、JSON ファイルで永続化するストア。
/// 最大 500 件を FIFO で管理。同じテキストの重複は先頭に移動して統合する。
///
/// 保存先: ~/Library/Application Support/FuzzyPaste/history.json
@MainActor
final class HistoryStore {
    private static let maxItems = 500

    private(set) var items: [ClipItem] = []
    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("FuzzyPaste")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        load()
    }

    func add(_ text: String) {
        // 同じテキストが既にあれば削除（重複排除）→ 先頭に新規挿入
        items.removeAll { $0.text == text }
        items.insert(ClipItem(text: text), at: 0)

        // 上限を超えた古いエントリを切り捨て
        if items.count > Self.maxItems {
            items = Array(items.prefix(Self.maxItems))
        }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([ClipItem].self, from: data)) ?? []
    }

    /// アトミック書き込みにより、書き込み中にクラッシュしてもファイルが壊れない
    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
