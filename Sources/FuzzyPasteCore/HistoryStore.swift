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

    public init(fileName: String, originalUTType: String, originalFileName: String?, pixelWidth: Int, pixelHeight: Int, fileSizeBytes: Int64) {
        self.fileName = fileName
        self.originalUTType = originalUTType
        self.originalFileName = originalFileName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fileSizeBytes = fileSizeBytes
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

/// クリップボード履歴の1エントリ。
/// JSON で永続化するため Codable に準拠。
public struct ClipItem: Codable, Identifiable, Sendable {
    public let id: UUID
    public let content: ClipContent
    public let copiedAt: Date

    public init(text: String) {
        self.id = UUID()
        self.content = .text(text)
        self.copiedAt = Date()
    }

    public init(imageMetadata: ImageMetadata) {
        self.id = UUID()
        self.content = .image(imageMetadata)
        self.copiedAt = Date()
    }

    public init(fileMetadata: FileMetadata) {
        self.id = UUID()
        self.content = .file(fileMetadata)
        self.copiedAt = Date()
    }

    /// テキストコンテンツを返す。画像・ファイルの場合は nil。
    public var text: String? {
        if case .text(let string) = content { return string }
        return nil
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
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("FuzzyPaste")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        load()
    }

    /// テキストアイテムを追加。同じテキストが既にあれば重複排除して先頭に移動。
    /// 空白・改行・タブのみのテキストは無視する。
    public func add(_ text: String) {
        guard !text.allSatisfy(\.isWhitespace) else { return }
        items.removeAll { $0.text == text }
        items.insert(ClipItem(text: text), at: 0)
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
