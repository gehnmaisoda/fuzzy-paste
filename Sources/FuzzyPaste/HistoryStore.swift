import Foundation

/// 画像のメタデータ。実際の画像ファイルは images/ 配下に保存され、
/// JSON にはこのメタデータのみを記録する。
struct ImageMetadata: Codable, Sendable, Equatable {
    let fileName: String        // UUID.png (images/ 配下)
    let originalUTType: String  // "public.png" 等
    let originalFileName: String? // Finder コピー時の元ファイル名
    let pixelWidth: Int
    let pixelHeight: Int
    let fileSizeBytes: Int64
}

/// ファイルのメタデータ。実際のファイルは files/ 配下に保存され、
/// JSON にはこのメタデータのみを記録する。
struct FileMetadata: Codable, Sendable, Equatable {
    let fileName: String          // UUID.ext (files/ 配下)
    let originalFileName: String  // コピー時の元ファイル名
    let fileExtension: String     // "pdf" 等
    let utType: String            // "com.adobe.pdf" 等
    let fileSizeBytes: Int64
}

/// クリップボードアイテムのコンテンツ種別。
enum ClipContent: Sendable, Equatable {
    case text(String)
    case image(ImageMetadata)
    case file(FileMetadata)
}

extension ClipContent: Codable {}

/// クリップボード履歴の1エントリ。
/// JSON で永続化するため Codable に準拠。
struct ClipItem: Codable, Identifiable, Sendable {
    let id: UUID
    let content: ClipContent
    let copiedAt: Date

    init(text: String) {
        self.id = UUID()
        self.content = .text(text)
        self.copiedAt = Date()
    }

    init(imageMetadata: ImageMetadata) {
        self.id = UUID()
        self.content = .image(imageMetadata)
        self.copiedAt = Date()
    }

    init(fileMetadata: FileMetadata) {
        self.id = UUID()
        self.content = .file(fileMetadata)
        self.copiedAt = Date()
    }

    /// テキストコンテンツを返す。画像・ファイルの場合は nil。
    var text: String? {
        if case .text(let string) = content { return string }
        return nil
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
    /// 画像ファイル削除用コールバック。ImageStore が設定する。
    var onImageDelete: ((String) -> Void)?
    /// ファイル削除用コールバック。FileStore が設定する。
    var onFileDelete: ((String) -> Void)?

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("FuzzyPaste")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        load()
    }

    /// テキストアイテムを追加。同じテキストが既にあれば重複排除して先頭に移動。
    /// 空白・改行・タブのみのテキストは無視する。
    func add(_ text: String) {
        guard !text.allSatisfy(\.isWhitespace) else { return }
        items.removeAll { $0.text == text }
        items.insert(ClipItem(text: text), at: 0)
        trimAndSave()
    }

    /// 画像アイテムを追加。画像は重複排除しない（毎回新規）。
    func addImage(_ metadata: ImageMetadata) {
        items.insert(ClipItem(imageMetadata: metadata), at: 0)
        trimAndSave()
    }

    /// ファイルアイテムを追加。ファイルは重複排除しない（毎回新規）。
    func addFile(_ metadata: FileMetadata) {
        items.insert(ClipItem(fileMetadata: metadata), at: 0)
        trimAndSave()
    }

    /// 上限を超えた古いエントリを切り捨て、画像・ファイルの実体も削除してから保存。
    private func trimAndSave() {
        if items.count > Self.maxItems {
            let removed = Array(items[Self.maxItems...])
            items = Array(items.prefix(Self.maxItems))
            for item in removed {
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
