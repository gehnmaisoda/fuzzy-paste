import AppKit
import FuzzyPasteCore
import UniformTypeIdentifiers

/// ファイルの保存・アイコン取得・削除を担当するストア。
///
/// 保存先: ~/Library/Application Support/FuzzyPaste/files/
@MainActor
final class FileStore {
    private let filesDir: URL
    /// ファイルタイプアイコンのメモリキャッシュ。拡張子単位でキャッシュする。
    private let iconCache = NSCache<NSString, NSImage>()

    init() {
        filesDir = AppPaths.appSupportDir.appendingPathComponent("files")
        try? FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        iconCache.countLimit = 100
    }

    /// ファイルデータを保存し、メタデータを返す。失敗時は nil。
    func save(data: Data, originalFileName: String) -> FileMetadata? {
        let ext = (originalFileName as NSString).pathExtension.lowercased()
        let storedName = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        let fileURL = filesDir.appendingPathComponent(storedName)

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

    /// ファイルのフルパスを返す。
    func fileURL(for fileName: String) -> URL {
        filesDir.appendingPathComponent(fileName)
    }

    /// 外部ファイルを新しい UUID ファイル名でインポートする。
    /// 成功時は新しいファイル名を返す。
    func importFile(from sourceURL: URL, fileExtension ext: String) -> String? {
        guard let data = try? Data(contentsOf: sourceURL) else { return nil }
        let newFileName = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        let destURL = filesDir.appendingPathComponent(newFileName)
        do {
            try data.write(to: destURL, options: .atomic)
        } catch {
            return nil
        }
        return newFileName
    }

    /// ファイルタイプに対応するアイコンを返す。拡張子単位でキャッシュ。
    func icon(for metadata: FileMetadata) -> NSImage {
        let key = metadata.fileExtension as NSString
        if let cached = iconCache.object(forKey: key) {
            return cached
        }

        let icon: NSImage
        if let type = UTType(filenameExtension: metadata.fileExtension) {
            icon = NSWorkspace.shared.icon(for: type)
        } else {
            icon = NSWorkspace.shared.icon(for: .data)
        }
        icon.size = NSSize(width: 64, height: 64)
        iconCache.setObject(icon, forKey: key)
        return icon
    }

    /// ファイルを削除する。
    func delete(fileName: String) {
        let fileURL = filesDir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }
}
