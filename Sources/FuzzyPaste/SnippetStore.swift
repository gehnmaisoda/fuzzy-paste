import Foundation

/// スニペットアイテム。title と content で登録し、両方で検索可能。
struct SnippetItem: Codable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var content: String
    var tags: [String]
    let createdAt: Date

    init(id: UUID = UUID(), title: String, content: String, tags: [String] = [], createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.content = content
        self.tags = tags
        self.createdAt = createdAt
    }
}

/// スニペットの永続化ストア。
/// 保存先: ~/Library/Application Support/FuzzyPaste/snippets.json
@MainActor
final class SnippetStore {
    private(set) var items: [SnippetItem] = []
    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("FuzzyPaste")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("snippets.json")
        load()
    }

    func add(title: String, content: String) {
        items.insert(SnippetItem(title: title, content: content), at: 0)
        save()
    }

    func update(id: UUID, title: String, content: String, tags: [String] = []) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let old = items[index]
        items[index] = SnippetItem(id: old.id, title: title, content: content, tags: tags, createdAt: old.createdAt)
        save()
    }

    /// 全スニペットのタグを重複排除・ソートして返す
    var allTags: [String] {
        Array(Set(items.flatMap(\.tags))).sorted()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
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
