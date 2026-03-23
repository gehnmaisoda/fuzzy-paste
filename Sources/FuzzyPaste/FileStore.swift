import AppKit
import FuzzyPasteCore
import UniformTypeIdentifiers

/// ファイルの保存・アイコン取得・削除を担当するストア。
///
/// 履歴用: ~/Library/Application Support/FuzzyPaste/files/
/// スニペット用: ~/.config/fuzzy-paste/snippets/assets/
@MainActor
final class FileStore {
    /// 履歴ファイルの保存先
    private let filesDir: URL
    /// スニペットアセットの保存先
    private let snippetAssetsDir: URL
    /// ファイルタイプアイコンのメモリキャッシュ。拡張子単位でキャッシュする。
    private let iconCache = NSCache<NSString, NSImage>()

    init() {
        filesDir = AppPaths.appSupportDir.appendingPathComponent("files")
        snippetAssetsDir = AppPaths.assetsDir
        try? FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        iconCache.countLimit = 100
    }

    // MARK: - 履歴用

    /// ファイルデータを履歴ディレクトリに保存し、メタデータを返す。失敗時は nil。
    func save(data: Data, originalFileName: String) -> FileMetadata? {
        saveFile(data: data, originalFileName: originalFileName, targetDir: filesDir)
    }

    // MARK: - スニペット用

    /// ファイルデータをスニペットアセットディレクトリに保存し、メタデータを返す。失敗時は nil。
    func saveForSnippet(data: Data, originalFileName: String) -> FileMetadata? {
        saveFile(data: data, originalFileName: originalFileName, targetDir: snippetAssetsDir)
    }

    /// 外部ファイルをスニペットアセットにインポートする。
    /// 成功時は新しいファイル名を返す。
    func importFileForSnippet(from sourceURL: URL, fileExtension ext: String) -> String? {
        guard let data = try? Data(contentsOf: sourceURL) else { return nil }
        let newFileName = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        let destURL = snippetAssetsDir.appendingPathComponent(newFileName)
        do {
            try data.write(to: destURL, options: .atomic)
        } catch {
            return nil
        }
        return newFileName
    }

    // MARK: - 読み取り（履歴・スニペット両方を探索）

    /// ファイルのフルパスを返す。履歴 → スニペットアセットの順で探索。
    func fileURL(for fileName: String) -> URL {
        let historyURL = filesDir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: historyURL.path) {
            return historyURL
        }
        return snippetAssetsDir.appendingPathComponent(fileName)
    }

    // MARK: - 削除（両ディレクトリから）

    /// ファイルを削除する。
    func delete(fileName: String) {
        let fm = FileManager.default
        for dir in [filesDir, snippetAssetsDir] {
            try? fm.removeItem(at: dir.appendingPathComponent(fileName))
        }
    }

    // MARK: - アイコン

    /// ファイルタイプに対応するアイコンを返す。拡張子単位でキャッシュ。
    func icon(for metadata: FileMetadata) -> NSImage {
        let key = metadata.fileExtension as NSString
        if let cached = iconCache.object(forKey: key) {
            return cached
        }

        let icon: NSImage
        let symbolName: String
        if let type = UTType(filenameExtension: metadata.fileExtension) {
            if type.conforms(to: .image) {
                symbolName = "photo"
            } else if type.conforms(to: .pdf) {
                symbolName = "doc.richtext"
            } else if type.conforms(to: .sourceCode) || type.conforms(to: .plainText) {
                symbolName = "doc.text"
            } else if type.conforms(to: .archive) {
                symbolName = "doc.zipper"
            } else {
                symbolName = "doc"
            }
        } else {
            symbolName = "doc"
        }
        let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)!
        iconCache.setObject(icon, forKey: key)
        return icon
    }

    // MARK: - Private

    private func saveFile(data: Data, originalFileName: String, targetDir: URL) -> FileMetadata? {
        let ext = (originalFileName as NSString).pathExtension.lowercased()
        let storedName = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        let fileURL = targetDir.appendingPathComponent(storedName)

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return nil
        }

        let utType: String
        if let type = UTType(filenameExtension: ext) {
            utType = type.identifier
        } else {
            utType = "public.data"
        }

        return FileMetadata(
            fileName: storedName,
            originalFileName: originalFileName,
            fileExtension: ext,
            utType: utType,
            fileSizeBytes: Int64(data.count)
        )
    }
}
