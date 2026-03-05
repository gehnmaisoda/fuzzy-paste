import Foundation

/// スニペットのコンテンツ種別。テキスト・画像・ファイルの3タイプ。
public enum SnippetContent: Codable, Sendable, Equatable {
    case text(String)
    case image(ImageMetadata)
    case file(FileMetadata)
}

extension SnippetContent {
    /// ファイル名マッピングを適用した新しい SnippetContent を返す。
    /// テキストの場合はそのまま返す。
    func remappingFileName(_ mapping: [String: String]) -> SnippetContent {
        switch self {
        case .text:
            return self
        case .image(let meta):
            guard let newName = mapping[meta.fileName] else { return self }
            return .image(ImageMetadata(
                fileName: newName, originalUTType: meta.originalUTType,
                originalFileName: meta.originalFileName,
                pixelWidth: meta.pixelWidth, pixelHeight: meta.pixelHeight,
                fileSizeBytes: meta.fileSizeBytes))
        case .file(let meta):
            guard let newName = mapping[meta.fileName] else { return self }
            return .file(FileMetadata(
                fileName: newName, originalFileName: meta.originalFileName,
                fileExtension: meta.fileExtension, utType: meta.utType,
                fileSizeBytes: meta.fileSizeBytes))
        }
    }
}

/// スニペットアイテム。title と content で登録し、両方で検索可能。
public struct SnippetItem: Codable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let content: SnippetContent
    public let tags: [String]
    public let createdAt: Date

    public init(id: UUID = UUID(), title: String, content: SnippetContent, tags: [String] = [], createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.content = content
        self.tags = tags
        self.createdAt = createdAt
    }

    /// コンテンツが実質的に空でないかどうか。空白のみのテキストは空とみなす。
    public var hasContent: Bool {
        switch content {
        case .text(let s): return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .image, .file: return true
        }
    }

    /// テキストコンテンツを返す。画像・ファイルの場合は nil。
    public var text: String? {
        if case .text(let s) = content { return s }
        return nil
    }

    /// 画像メタデータを返す。テキスト・ファイルの場合は nil。
    public var imageMetadata: ImageMetadata? {
        if case .image(let m) = content { return m }
        return nil
    }

    /// ファイルメタデータを返す。テキスト・画像の場合は nil。
    public var fileMetadata: FileMetadata? {
        if case .file(let m) = content { return m }
        return nil
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
        let dir = AppPaths.appSupportDir
        fileURL = dir.appendingPathComponent("snippets.json")
        load()
    }

    /// 画像ファイル削除用コールバック。AppDelegate が設定する。
    public var onImageDelete: ((String) -> Void)?
    /// ファイル削除用コールバック。AppDelegate が設定する。
    public var onFileDelete: ((String) -> Void)?

    public func add(title: String, content: SnippetContent, tags: [String] = []) {
        items.insert(SnippetItem(title: title, content: content, tags: tags), at: 0)
        save()
    }

    public func update(id: UUID, title: String, content: SnippetContent, tags: [String] = []) {
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
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        switch item.content {
        case .image(let meta):
            onImageDelete?(meta.fileName)
        case .file(let meta):
            onFileDelete?(meta.fileName)
        case .text:
            break
        }
        items.remove(at: index)
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

        let existingKeys = Set(items.map { duplicateKey(for: $0) })
        var newItems: [SnippetItem] = []
        var duplicates: [SnippetItem] = []
        for item in imported {
            let key = duplicateKey(for: item)
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

    /// ファイル名マッピングを適用してスニペットをインポートする（新しい UUID を割り当て）。
    /// バンドルインポート時に、古いファイル名を新しいファイル名に置き換える。
    public func importItems(_ newItems: [SnippetItem], fileNameMapping: [String: String]) {
        let remapped = newItems.map { item -> SnippetItem in
            let content = item.content.remappingFileName(fileNameMapping)
            return SnippetItem(id: item.id, title: item.title, content: content, tags: item.tags, createdAt: item.createdAt)
        }
        importItems(remapped)
    }

    /// 重複判定用キーを生成する。
    private func duplicateKey(for item: SnippetItem) -> String {
        switch item.content {
        case .text(let text):
            return "text:\(item.title)\n\(text)"
        case .image(let meta):
            return "image:\(item.title)\n\(meta.fileName)"
        case .file(let meta):
            return "file:\(item.title)\n\(meta.fileName)"
        }
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
