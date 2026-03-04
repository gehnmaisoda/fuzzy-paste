import Foundation

/// スニペットアイテム。title と content で登録し、両方で検索可能。
public struct SnippetItem: Codable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let content: String
    public let tags: [String]
    public let createdAt: Date

    public init(id: UUID = UUID(), title: String, content: String, tags: [String] = [], createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.content = content
        self.tags = tags
        self.createdAt = createdAt
    }
}

/// エクスポート用ラッパー。バージョン情報と日時を付与して JSON に書き出す。
public struct SnippetExportData: Codable, Sendable {
    public let version: String
    public let exportedAt: Date
    public let snippets: [SnippetItem]

    public init(version: String, exportedAt: Date, snippets: [SnippetItem]) {
        self.version = version
        self.exportedAt = exportedAt
        self.snippets = snippets
    }
}

/// スニペットの永続化ストア。
/// 保存先: ~/Library/Application Support/FuzzyPaste/snippets.json
@MainActor
public final class SnippetStore {
    public private(set) var items: [SnippetItem] = []
    private let fileURL: URL

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("FuzzyPaste")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("snippets.json")
        load()
    }

    public func add(title: String, content: String, tags: [String] = []) {
        items.insert(SnippetItem(title: title, content: content, tags: tags), at: 0)
        save()
    }

    public func update(id: UUID, title: String, content: String, tags: [String] = []) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let old = items[index]
        items[index] = SnippetItem(id: old.id, title: title, content: content, tags: tags, createdAt: old.createdAt)
        save()
    }

    /// 全スニペットのタグを重複排除・ソートして返す
    public var allTags: [String] {
        Array(Set(items.flatMap(\.tags))).sorted()
    }

    public func remove(id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    // MARK: - Import / Export

    /// 全スニペットを JSON Data にエクスポートする。
    public func exportData() throws -> Data {
        let exportData = SnippetExportData(version: "1.0", exportedAt: Date(), snippets: items)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(exportData)
    }

    /// 全スニペットを JSON ファイルにエクスポートする。
    public func exportToFile(url: URL) throws {
        let data = try exportData()
        try data.write(to: url, options: .atomic)
    }

    /// JSON データを読み込み、新規と重複に分類して返す。
    /// ラッパー形式 (`SnippetExportData`) と生配列 (`[SnippetItem]`) の両方に対応。
    /// 重複判定: title + content が既存アイテムと一致するかどうか。
    public func parseImportData(_ data: Data) throws -> (new: [SnippetItem], duplicates: [SnippetItem]) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let imported: [SnippetItem]
        if let wrapped = try? decoder.decode(SnippetExportData.self, from: data) {
            imported = wrapped.snippets
        } else {
            imported = try decoder.decode([SnippetItem].self, from: data)
        }

        let existingKeys = Set(items.map { "\($0.title)\n\($0.content)" })
        var newItems: [SnippetItem] = []
        var duplicates: [SnippetItem] = []
        for item in imported {
            let key = "\(item.title)\n\(item.content)"
            if existingKeys.contains(key) {
                duplicates.append(item)
            } else {
                newItems.append(item)
            }
        }
        return (new: newItems, duplicates: duplicates)
    }

    /// JSON ファイルを読み込み、新規と重複に分類して返す。
    public func parseImportFile(url: URL) throws -> (new: [SnippetItem], duplicates: [SnippetItem]) {
        let data = try Data(contentsOf: url)
        return try parseImportData(data)
    }

    /// スニペットを追加する（新しい UUID を割り当て）。
    public func importItems(_ newItems: [SnippetItem]) {
        let reassigned = newItems.map {
            SnippetItem(title: $0.title, content: $0.content, tags: $0.tags, createdAt: $0.createdAt)
        }
        items.insert(contentsOf: reassigned, at: 0)
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([SnippetItem].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
