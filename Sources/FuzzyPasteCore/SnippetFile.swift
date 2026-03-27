import Foundation
import ImageIO
import UniformTypeIdentifiers

/// SnippetItem と Markdown ファイルの相互変換を行うユーティリティ。
public enum SnippetFile {

    // MARK: - Parse

    /// Markdown ファイルの内容を SnippetItem にパースする。
    /// `assetsDir` を指定すると、`asset` フィールドから画像/ファイルメタデータを動的に取得する。
    /// `assetsDir` が nil の場合、アセットスニペットのメタデータは最小限の情報で構築する。
    public static func parse(content: String, assetsDir: URL? = nil) -> SnippetItem? {
        let result = FrontmatterParser.parse(content)

        // id: なければ自動生成
        let id: UUID
        if let idStr = result.fields["id"], let parsed = UUID(uuidString: idStr) {
            id = parsed
        } else {
            id = UUID()
        }

        let title = result.fields["title"] ?? ""
        let tags = result.fields["tags"].map { FrontmatterParser.parseTags($0) } ?? []

        let createdAt: Date
        if let dateStr = result.fields["created"] {
            createdAt = parseISO8601(dateStr) ?? Date()
        } else {
            createdAt = Date()
        }

        // asset フィールドがあれば画像/ファイルスニペット、なければテキスト
        let snippetContent: SnippetContent
        if let assetFileName = result.fields["asset"] {
            if let dir = assetsDir {
                guard let resolved = resolveAsset(fileName: assetFileName, assetsDir: dir) else {
                    // アセットファイルが存在しない → テキストとして扱う
                    snippetContent = .text(result.body)
                    return SnippetItem(id: id, title: title, content: snippetContent, tags: tags, createdAt: createdAt)
                }
                snippetContent = resolved
            } else {
                // assetsDir 未指定 → 最小限のメタデータで構築（テスト用）
                snippetContent = buildMinimalAsset(fileName: assetFileName)
            }
        } else {
            snippetContent = .text(result.body)
        }

        return SnippetItem(id: id, title: title, content: snippetContent, tags: tags, createdAt: createdAt)
    }

    // MARK: - Serialize

    /// SnippetItem を Markdown + frontmatter 文字列にシリアライズする。
    public static func serialize(item: SnippetItem) -> String {
        var fields: [String: String] = [
            "id": item.id.uuidString,
            "title": item.title,
            "tags": FrontmatterParser.serializeTags(item.tags),
            "created": formatISO8601(item.createdAt),
        ]

        let body: String
        switch item.content {
        case .text(let text):
            body = text
        case .image(let meta):
            fields["asset"] = meta.fileName
            body = ""
        case .file(let meta):
            fields["asset"] = meta.fileName
            body = ""
        }

        return FrontmatterParser.serialize(fields: fields, body: body)
    }

    // MARK: - Filename

    /// SnippetItem からファイル名を生成する。
    /// 形式: `{タイトルslug}.md`
    public static func fileName(for item: SnippetItem) -> String {
        let slug = FrontmatterParser.slug(from: item.title)
        return "\(slug).md"
    }

    /// 指定ディレクトリ内で衝突しないファイル名を生成する。
    /// 衝突時は `-2`, `-3` ... のサフィックスを付与する。
    /// `excluding` を指定すると、そのファイルは衝突対象から除外する（リネーム時に自分自身を除外するため）。
    public static func uniqueFileName(for item: SnippetItem, in directory: URL, excluding: URL? = nil) -> String {
        let slug = FrontmatterParser.slug(from: item.title)
        let base = "\(slug).md"
        let fm = FileManager.default

        if !isCollision(name: base, in: directory, excluding: excluding, fm: fm) {
            return base
        }

        var counter = 2
        while true {
            let candidate = "\(slug)-\(counter).md"
            if !isCollision(name: candidate, in: directory, excluding: excluding, fm: fm) {
                return candidate
            }
            counter += 1
        }
    }

    private static func isCollision(name: String, in directory: URL, excluding: URL?, fm: FileManager) -> Bool {
        let url = directory.appendingPathComponent(name)
        guard fm.fileExists(atPath: url.path) else { return false }
        // excluding と同じパスなら衝突ではない（自分自身）
        if let excluding, url.path == excluding.path { return false }
        return true
    }

    // MARK: - Asset Resolution

    /// アセットファイルから SnippetContent を構築する。
    /// UTType が image に適合すれば `.image`、それ以外は `.file`。
    public static func resolveAsset(fileName: String, assetsDir: URL) -> SnippetContent? {
        let fileURL = assetsDir.appendingPathComponent(fileName)
        let fm = FileManager.default

        guard fm.fileExists(atPath: fileURL.path) else { return nil }

        let ext = fileURL.pathExtension.lowercased()
        let utType = UTType(filenameExtension: ext)
        let isImage = utType?.conforms(to: .image) ?? false

        if isImage {
            return resolveImageAsset(fileURL: fileURL, fileName: fileName, ext: ext)
        } else {
            return resolveFileAsset(fileURL: fileURL, fileName: fileName, ext: ext)
        }
    }

    // MARK: - Private

    private static func resolveImageAsset(fileURL: URL, fileName: String, ext: String) -> SnippetContent? {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attrs?[.size] as? Int64) ?? 0

        let utType = UTType(filenameExtension: ext)?.identifier ?? "public.image"

        // ImageIO でピクセルサイズ取得（ヘッダのみ読取）
        var width = 0
        var height = 0
        if let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) {
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
            height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        }

        let meta = ImageMetadata(
            fileName: fileName,
            originalUTType: utType,
            originalFileName: nil,
            pixelWidth: width,
            pixelHeight: height,
            fileSizeBytes: fileSize
        )
        return .image(meta)
    }

    private static func resolveFileAsset(fileURL: URL, fileName: String, ext: String) -> SnippetContent? {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attrs?[.size] as? Int64) ?? 0

        let utType = UTType(filenameExtension: ext)?.identifier ?? "public.data"

        let meta = FileMetadata(
            fileName: fileName,
            originalFileName: fileName,
            fileExtension: ext,
            utType: utType,
            fileSizeBytes: fileSize
        )
        return .file(meta)
    }

    /// assetsDir 未指定時の最小限アセット構築（テスト用）。
    private static func buildMinimalAsset(fileName: String) -> SnippetContent {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let utType = UTType(filenameExtension: ext)
        let isImage = utType?.conforms(to: .image) ?? false

        if isImage {
            return .image(ImageMetadata(
                fileName: fileName,
                originalUTType: utType?.identifier ?? "public.image",
                originalFileName: nil,
                pixelWidth: 0,
                pixelHeight: 0,
                fileSizeBytes: 0
            ))
        } else {
            return .file(FileMetadata(
                fileName: fileName,
                originalFileName: fileName,
                fileExtension: ext,
                utType: utType?.identifier ?? "public.data",
                fileSizeBytes: 0
            ))
        }
    }

    /// ISO8601DateFormatter は Sendable ではないが、初期化後は読み取り専用で使用するため安全。
    nonisolated(unsafe) private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseISO8601(_ string: String) -> Date? {
        iso8601Formatter.date(from: string)
    }

    private static func formatISO8601(_ date: Date) -> String {
        iso8601Formatter.string(from: date)
    }
}
