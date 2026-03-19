import Foundation

/// 画像のメタデータ。実際の画像ファイルは images/ 配下に保存され、
/// JSON にはこのメタデータのみを記録する。
public struct ImageMetadata: Codable, Sendable, Equatable {
    public let fileName: String        // UUID.png (images/ 配下)
    public let originalUTType: String  // "public.png" 等
    public let originalFileName: String? // Finder コピー時の元ファイル名
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let fileSizeBytes: Int64
    /// OCR で抽出されたテキスト。未実行または検出なしなら nil。
    /// クリップボード履歴の画像でのみ使用。スニペットではタイトル・タグで検索できるため OCR は行わない。
    public var ocrText: String?

    public init(fileName: String, originalUTType: String, originalFileName: String?, pixelWidth: Int, pixelHeight: Int, fileSizeBytes: Int64, ocrText: String? = nil) {
        self.fileName = fileName
        self.originalUTType = originalUTType
        self.originalFileName = originalFileName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fileSizeBytes = fileSizeBytes
        self.ocrText = ocrText
    }
}

/// ファイルのメタデータ。実際のファイルは files/ 配下に保存され、
/// JSON にはこのメタデータのみを記録する。
public struct FileMetadata: Codable, Sendable, Equatable {
    public let fileName: String          // UUID.ext (files/ 配下)
    public let originalFileName: String  // コピー時の元ファイル名
    public let fileExtension: String     // "pdf" 等
    public let utType: String            // "com.adobe.pdf" 等
    public let fileSizeBytes: Int64

    public init(fileName: String, originalFileName: String, fileExtension: String, utType: String, fileSizeBytes: Int64) {
        self.fileName = fileName
        self.originalFileName = originalFileName
        self.fileExtension = fileExtension
        self.utType = utType
        self.fileSizeBytes = fileSizeBytes
    }
}

/// クリップボードアイテムのコンテンツ種別。
public enum ClipContent: Sendable, Equatable {
    case text(String)
    case image(ImageMetadata)
    case file(FileMetadata)
}

extension ClipContent: Codable {}

extension ClipContent {
    /// コンテンツ種別から自動付与されるタグ。テキストは空。
    public var autoTags: [String] {
        switch self {
        case .text: return []
        case .image: return [AutoTag.imageTag]
        case .file(let meta): return AutoTag.tags(forExtension: meta.fileExtension)
        }
    }
}

/// クリップボード履歴の1エントリ。
/// JSON で永続化するため Codable に準拠。
public struct ClipItem: Identifiable, Sendable {
    public let id: UUID
    public let content: ClipContent
    public let copiedAt: Date
    /// ペースト/コピーされた回数。frecency スコアの計算に使用。
    public var useCount: Int
    /// 最後にペースト/コピーされた日時。frecency スコアの減衰計算に使用。
    public var lastUsedAt: Date?
    /// スニペット使用履歴の場合、元スニペットの ID。
    public var snippetId: UUID?

    public init(text: String) {
        self.id = UUID()
        self.content = .text(text)
        self.copiedAt = Date()
        self.useCount = 0
        self.lastUsedAt = nil
        self.snippetId = nil
    }

    public init(imageMetadata: ImageMetadata) {
        self.id = UUID()
        self.content = .image(imageMetadata)
        self.copiedAt = Date()
        self.useCount = 0
        self.lastUsedAt = nil
        self.snippetId = nil
    }

    public init(fileMetadata: FileMetadata) {
        self.id = UUID()
        self.content = .file(fileMetadata)
        self.copiedAt = Date()
        self.useCount = 0
        self.lastUsedAt = nil
        self.snippetId = nil
    }

    /// 既存アイテムの内容を置き換えて再構築する。OCR テキスト更新等で使用。
    init(id: UUID, content: ClipContent, copiedAt: Date, useCount: Int = 0, lastUsedAt: Date? = nil, snippetId: UUID? = nil) {
        self.id = id
        self.content = content
        self.copiedAt = copiedAt
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
        self.snippetId = snippetId
    }

    /// テキストコンテンツを返す。画像・ファイルの場合は nil。
    public var text: String? {
        if case .text(let string) = content { return string }
        return nil
    }
}

extension ClipItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, content, copiedAt, useCount, lastUsedAt, snippetId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decode(ClipContent.self, forKey: .content)
        copiedAt = try container.decode(Date.self, forKey: .copiedAt)
        useCount = try container.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        snippetId = try container.decodeIfPresent(UUID.self, forKey: .snippetId)
    }
}

/// クリップボード履歴をメモリ上に保持し、JSON ファイルで永続化するストア。
/// 設定可能な最大件数で FIFO 管理。同じテキストの重複は先頭に移動して統合する。
///
/// 保存先: ~/Library/Application Support/FuzzyPaste/history.json
@MainActor
public final class HistoryStore {
    nonisolated public static let defaultMaxHistoryCount = 500

    public private(set) var maxItems = HistoryStore.defaultMaxHistoryCount

    public private(set) var items: [ClipItem] = []
    private let fileURL: URL
    /// 画像ファイル削除用コールバック。ImageStore が設定する。
    public var onImageDelete: ((String) -> Void)?
    /// ファイル削除用コールバック。FileStore が設定する。
    public var onFileDelete: ((String) -> Void)?

    public init() {
        let dir = AppPaths.appSupportDir
        fileURL = dir.appendingPathComponent("history.json")
        load()
    }

    /// テキストアイテムを追加。同じテキストが既にあれば重複排除して先頭に移動。
    /// 空白・改行・タブのみのテキストは無視する。
    /// 重複排除時は frecency データ（useCount / lastUsedAt）を引き継ぐ。
    public func add(_ text: String) {
        guard !text.allSatisfy(\.isWhitespace) else { return }
        let existing = items.first { $0.text == text && $0.snippetId == nil }
        items.removeAll { $0.text == text && $0.snippetId == nil }
        var newItem = ClipItem(text: text)
        if let existing {
            newItem.useCount = existing.useCount
            newItem.lastUsedAt = existing.lastUsedAt
        }
        items.insert(newItem, at: 0)
        trimAndSave()
    }

    /// スニペット使用をマーカーとして履歴に追加。同じ snippetId があれば先頭に移動。
    public func addSnippetUse(snippetId: UUID) {
        let existing = items.first { $0.snippetId == snippetId }
        items.removeAll { $0.snippetId == snippetId }
        var newItem = ClipItem(text: "")
        newItem.snippetId = snippetId
        if let existing {
            newItem.useCount = existing.useCount
            newItem.lastUsedAt = existing.lastUsedAt
        }
        items.insert(newItem, at: 0)
        trimAndSave()
    }

    /// 画像アイテムを追加。画像は重複排除しない（毎回新規）。
    public func addImage(_ metadata: ImageMetadata) {
        items.insert(ClipItem(imageMetadata: metadata), at: 0)
        trimAndSave()
    }

    /// ファイルアイテムを追加。ファイルは重複排除しない（毎回新規）。
    public func addFile(_ metadata: FileMetadata) {
        items.insert(ClipItem(fileMetadata: metadata), at: 0)
        trimAndSave()
    }

    /// 指定した画像アイテムの OCR テキストを更新して保存する。
    public func updateOCRText(_ text: String, forImageFileName fileName: String) {
        guard let index = items.firstIndex(where: {
            if case .image(let meta) = $0.content { return meta.fileName == fileName }
            return false
        }) else { return }
        guard case .image(var meta) = items[index].content else { return }
        meta.ocrText = text
        let old = items[index]
        items[index] = ClipItem(id: old.id, content: .image(meta), copiedAt: old.copiedAt,
                                useCount: old.useCount, lastUsedAt: old.lastUsedAt)
        save()
    }

    /// 使用回数と最終使用日時を更新する。ペースト/コピー時に呼ぶ。
    public func recordUse(id: UUID) {
        recordUses(ids: [id])
    }

    /// 複数アイテムの使用回数と最終使用日時を一括更新する。マルチペースト時に使用。
    public func recordUses(ids: [UUID]) {
        let idSet = Set(ids)
        let now = Date()
        var updated = false
        for index in items.indices where idSet.contains(items[index].id) {
            items[index].useCount += 1
            items[index].lastUsedAt = now
            updated = true
        }
        if updated { save() }
    }

    /// 最大件数を変更し、超過分があればトリムして保存。
    public func setMaxItems(_ count: Int) {
        guard maxItems != count else { return }
        maxItems = count
        trimAndSave()
    }

    /// すべての履歴を削除し、画像・ファイルの実体も削除して保存。
    public func clearAll() {
        let removed = items
        items = []
        deleteAssociatedFiles(for: removed)
        save()
    }

    /// 上限を超えた古いエントリを切り捨て、画像・ファイルの実体も削除してから保存。
    private func trimAndSave() {
        if items.count > maxItems {
            let removed = Array(items[maxItems...])
            items = Array(items.prefix(maxItems))
            deleteAssociatedFiles(for: removed)
        }
        save()
    }

    /// 削除対象アイテムに紐づく画像・ファイルの実体を削除する。
    private func deleteAssociatedFiles(for items: [ClipItem]) {
        for item in items {
            switch item.content {
            case .image(let meta):
                onImageDelete?(meta.fileName)
            case .file(let meta):
                onFileDelete?(meta.fileName)
            case .text:
                break
            }
        }
    }

    /// JSON ファイルから履歴を読み込み直す。
    /// 外部プロセス（CLI 等）による変更を反映するために公開している。
    public func reload() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([ClipItem].self, from: data)) ?? []
    }

    /// 監視対象の JSON ファイルパスを返す。
    public var monitoredFileURL: URL { fileURL }

    private func load() { reload() }

    /// アトミック書き込みにより、書き込み中にクラッシュしてもファイルが壊れない
    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
        lastSaveDate = Date()
    }

    /// 自分自身の save による変更を無視するためのタイムスタンプ。
    public private(set) var lastSaveDate: Date = .distantPast
}
