import Foundation

/// スニペットのコンテンツ種別。テキスト・画像・ファイルの3タイプ。
public enum SnippetContent: Sendable, Equatable {
    case text(String)
    case image(ImageMetadata)
    case file(FileMetadata)
}

extension SnippetContent: Codable {
    private enum CodingKeys: String, CodingKey {
        case text, image, file
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.text) {
            self = .text(try container.decode(String.self, forKey: .text))
        } else if container.contains(.image) {
            self = .image(try container.decode(ImageMetadata.self, forKey: .image))
        } else if container.contains(.file) {
            self = .file(try container.decode(FileMetadata.self, forKey: .file))
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "SnippetContent: no known key (text/image/file)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode(value, forKey: .text)
        case .image(let meta):
            try container.encode(meta, forKey: .image)
        case .file(let meta):
            try container.encode(meta, forKey: .file)
        }
    }
}

extension SnippetContent {
    /// コンテンツ種別から自動付与されるタグ。テキストは空。
    public var autoTags: [String] {
        switch self {
        case .text: return []
        case .image: return [AutoTag.imageTag]
        case .file(let meta): return AutoTag.tags(forExtension: meta.fileExtension)
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

/// スニペットの永続化ストア。
/// 保存先: ~/.config/fuzzy-paste/snippets/ (1スニペット = 1 .md ファイル)
@MainActor
public final class SnippetStore {
    public private(set) var items: [SnippetItem] = []
    private let snippetsDir: URL
    private let assetsDir: URL
    /// スニペット ID → .md ファイルパスのマッピング
    private var fileMap: [UUID: URL] = [:]

    public init() {
        snippetsDir = AppPaths.snippetsDir
        assetsDir = AppPaths.assetsDir
        let isFirstLaunch = isDirectoryEmpty(snippetsDir)
        loadAll()
        if isFirstLaunch && items.isEmpty {
            seedDefaults()
        }
    }

    /// テスト用: 任意のディレクトリで初期化
    public init(snippetsDir: URL, assetsDir: URL) {
        self.snippetsDir = snippetsDir
        self.assetsDir = assetsDir
        loadAll()
    }

    /// 画像ファイル削除用コールバック。AppDelegate が設定する。
    public var onImageDelete: ((String) -> Void)?
    /// ファイル削除用コールバック。AppDelegate が設定する。
    public var onFileDelete: ((String) -> Void)?

    public func add(title: String, content: SnippetContent, tags: [String] = []) {
        let item = SnippetItem(title: title, content: content, tags: tags)
        items.insert(item, at: 0)
        saveItem(item)
    }

    public func update(id: UUID, title: String, content: SnippetContent, tags: [String] = []) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let old = items[index]
        let updated = SnippetItem(id: old.id, title: title, content: content, tags: tags, createdAt: old.createdAt)
        items[index] = updated
        saveItem(updated)
    }

    /// 全スニペットのタグ（ユーザータグ + autoTags）を重複排除・ソートして返す
    public var allTags: [String] {
        Array(Set(items.flatMap { $0.tags + $0.content.autoTags })).sorted()
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
        // .md ファイルを削除
        if let fileURL = fileMap[id] {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileMap.removeValue(forKey: id)
        items.remove(at: index)
        lastSaveDate = Date()
    }

    // MARK: - Import / Export

    /// snippets ディレクトリを ZIP にエクスポートする。
    /// .md ファイルと assets/ を含む。
    public func exportToZip(url: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-c", "-k", "--sequesterRsrc", snippetsDir.path, url.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "SnippetStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "ZIP ファイルの作成に失敗しました"])
        }
    }

    /// ZIP ファイルからスニペットをインポートする。
    /// .md ファイルと assets/ をマージ。ID 重複はスキップ。
    public func importFromZip(url: URL) throws -> (imported: Int, skipped: Int) {
        let (newItems, duplicates, tempDir) = try extractAndClassify(zipURL: url)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tempAssetsDir = tempDir.appendingPathComponent("assets")
        let fm = FileManager.default

        for item in newItems {
            // アセットをコピー
            if let assetName = assetFileName(for: item) {
                let src = tempAssetsDir.appendingPathComponent(assetName)
                let dst = assetsDir.appendingPathComponent(assetName)
                if fm.fileExists(atPath: src.path) && !fm.fileExists(atPath: dst.path) {
                    try? fm.copyItem(at: src, to: dst)
                }
            }

            // .md ファイルを保存
            let destName = SnippetFile.uniqueFileName(for: item, in: snippetsDir)
            let destURL = snippetsDir.appendingPathComponent(destName)
            let serialized = SnippetFile.serialize(item: item)
            try? serialized.write(to: destURL, atomically: true, encoding: .utf8)
            fileMap[item.id] = destURL
            items.insert(item, at: 0)
        }

        if !newItems.isEmpty {
            lastSaveDate = Date()
        }
        return (imported: newItems.count, skipped: duplicates.count)
    }

    /// ZIP を展開してスニペットを読み取り、新規と重複に分類する。
    public func parseImportZip(url: URL) throws -> (new: [SnippetItem], duplicates: [SnippetItem]) {
        let (newItems, duplicates, tempDir) = try extractAndClassify(zipURL: url)
        try? FileManager.default.removeItem(at: tempDir)
        return (new: newItems, duplicates: duplicates)
    }

    /// ZIP を展開し、新規/重複を分類して返す。tempDir は呼び出し側が削除する。
    private func extractAndClassify(zipURL: URL) throws -> (new: [SnippetItem], duplicates: [SnippetItem], tempDir: URL) {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("FuzzyPaste-import-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", zipURL.path, tempDir.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            try? fm.removeItem(at: tempDir)
            throw NSError(domain: "SnippetStore", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "ZIP ファイルの展開に失敗しました"])
        }

        let tempAssetsDir = tempDir.appendingPathComponent("assets")
        let existingIDs = Set(items.map { $0.id })
        var newItems: [SnippetItem] = []
        var duplicates: [SnippetItem] = []

        let mdFiles = (try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil))?.filter {
            $0.pathExtension.lowercased() == "md"
        } ?? []

        for mdURL in mdFiles {
            guard let content = try? String(contentsOf: mdURL, encoding: .utf8),
                  let item = SnippetFile.parse(content: content, assetsDir: tempAssetsDir) else {
                continue
            }
            if existingIDs.contains(item.id) {
                duplicates.append(item)
            } else {
                newItems.append(item)
            }
        }

        return (new: newItems, duplicates: duplicates, tempDir: tempDir)
    }

    /// SnippetContent からアセットファイル名を取得する。テキストの場合は nil。
    private func assetFileName(for item: SnippetItem) -> String? {
        switch item.content {
        case .image(let meta): return meta.fileName
        case .file(let meta): return meta.fileName
        case .text: return nil
        }
    }

    /// ディレクトリ内の .md ファイルからスニペットを読み込み直す。
    /// 外部プロセス（CLI、テキストエディタ等）による変更を反映するために公開している。
    public func reload() {
        loadAll()
    }

    /// 監視対象のディレクトリパスを返す。
    public var monitoredFileURL: URL { snippetsDir }

    /// 自分自身の save による変更を無視するためのタイムスタンプ。
    public private(set) var lastSaveDate: Date = .distantPast

    // MARK: - Private

    private func loadAll() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: snippetsDir, includingPropertiesForKeys: nil) else {
            items = []
            fileMap = [:]
            return
        }

        var loaded: [SnippetItem] = []
        var map: [UUID: URL] = [:]
        var needsIdAssignment: [(SnippetItem, URL)] = []

        for fileURL in files where fileURL.pathExtension.lowercased() == "md" {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8),
                  let item = SnippetFile.parse(content: content, assetsDir: assetsDir) else {
                continue
            }

            // frontmatter に id がなかったファイルには UUID を書き戻す
            let hasId = content.contains("\nid:") || content.hasPrefix("---\nid:")
            if !hasId {
                needsIdAssignment.append((item, fileURL))
            }

            loaded.append(item)
            map[item.id] = fileURL
        }

        // id がないファイルに UUID を書き戻し
        for (item, fileURL) in needsIdAssignment {
            let serialized = SnippetFile.serialize(item: item)
            try? serialized.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        // createdAt 降順（新しい順）でソート
        items = loaded.sorted { $0.createdAt > $1.createdAt }
        fileMap = map
    }

    private func saveItem(_ item: SnippetItem) {
        let serialized = SnippetFile.serialize(item: item)

        if let existingURL = fileMap[item.id] {
            // タイトル変更でファイル名が変わる場合はリネーム
            let desiredName = SnippetFile.uniqueFileName(for: item, in: snippetsDir, excluding: existingURL)
            let desiredURL = snippetsDir.appendingPathComponent(desiredName)

            if existingURL.lastPathComponent != desiredName {
                try? FileManager.default.removeItem(at: existingURL)
                try? serialized.write(to: desiredURL, atomically: true, encoding: .utf8)
                fileMap[item.id] = desiredURL
            } else {
                try? serialized.write(to: existingURL, atomically: true, encoding: .utf8)
            }
        } else {
            // 新規ファイル作成
            let name = SnippetFile.uniqueFileName(for: item, in: snippetsDir)
            let fileURL = snippetsDir.appendingPathComponent(name)
            try? serialized.write(to: fileURL, atomically: true, encoding: .utf8)
            fileMap[item.id] = fileURL
        }
        lastSaveDate = Date()
    }

    private func seedDefaults() {
        let item = SnippetItem(
            title: "メール返信テンプレート",
            content: .text("{{相手の名前}}様\n\nお世話になっております。\nよろしくお願いいたします。"),
            tags: ["first snippet", "mail"]
        )
        items = [item]
        saveItem(item)
    }

    private func isDirectoryEmpty(_ url: URL) -> Bool {
        let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        // assets ディレクトリのみの場合も空とみなす
        let mdFiles = contents?.filter { $0.pathExtension.lowercased() == "md" }
        return mdFiles?.isEmpty ?? true
    }
}
