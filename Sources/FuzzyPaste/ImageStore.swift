import AppKit
import FuzzyPasteCore
import ImageIO

/// 画像ファイルの保存・読み込み・サムネイル生成を担当するストア。
///
/// 履歴用: ~/Library/Application Support/FuzzyPaste/images/
/// スニペット用: ~/.config/fuzzy-paste/snippets/assets/
@MainActor
final class ImageStore {
    /// 履歴画像の保存先
    private let imagesDir: URL
    private let thumbsDir: URL
    /// スニペットアセットの保存先
    private let snippetAssetsDir: URL
    private let snippetThumbsDir: URL
    /// サムネイルのメモリキャッシュ。頻繁にスクロールされる検索ウィンドウ向け。
    private let thumbCache = NSCache<NSString, NSImage>()
    /// サムネイルサイズ (256x256 @2x = 512px)
    private static let thumbMaxPixels = 512

    init() {
        imagesDir = AppPaths.appSupportDir.appendingPathComponent("images")
        thumbsDir = imagesDir.appendingPathComponent("thumbs")
        snippetAssetsDir = AppPaths.assetsDir
        snippetThumbsDir = AppPaths.thumbsDir
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        thumbCache.countLimit = 200
    }

    // MARK: - 履歴用（クリップボードモニター経由）

    /// 画像データを履歴ディレクトリに保存し、メタデータを返す。失敗時は nil。
    func save(data: Data, utType: String, originalFileName: String? = nil) -> ImageMetadata? {
        saveImage(data: data, utType: utType, originalFileName: originalFileName,
                  targetDir: imagesDir, targetThumbsDir: thumbsDir)
    }

    // MARK: - スニペット用

    /// 画像データをスニペットアセットディレクトリに保存し、メタデータを返す。失敗時は nil。
    func saveForSnippet(data: Data, utType: String, originalFileName: String? = nil) -> ImageMetadata? {
        saveImage(data: data, utType: utType, originalFileName: originalFileName,
                  targetDir: snippetAssetsDir, targetThumbsDir: snippetThumbsDir)
    }

    /// 外部ファイルをスニペットアセットにインポートし、サムネイルも生成する。
    /// 成功時は新しいファイル名を返す。
    func importImageForSnippet(from sourceURL: URL) -> String? {
        guard let data = try? Data(contentsOf: sourceURL) else { return nil }
        let newFileName = "\(UUID().uuidString).png"
        let destURL = snippetAssetsDir.appendingPathComponent(newFileName)
        do {
            try data.write(to: destURL, options: .atomic)
        } catch {
            return nil
        }
        generateThumbnail(fileName: newFileName, sourceData: data, thumbsDir: snippetThumbsDir)
        return newFileName
    }

    // MARK: - 読み取り（履歴・スニペット両方を探索）

    /// サムネイル画像を返す。キャッシュ → 履歴 → スニペットアセットの順で探索。
    func thumbnail(for fileName: String) -> NSImage? {
        let key = fileName as NSString
        if let cached = thumbCache.object(forKey: key) {
            return cached
        }

        let candidates = [
            thumbsDir.appendingPathComponent(fileName),
            snippetThumbsDir.appendingPathComponent(fileName),
        ]
        for url in candidates {
            if let image = NSImage(contentsOf: url) {
                thumbCache.setObject(image, forKey: key)
                return image
            }
        }
        return nil
    }

    /// 画像ファイルのフルパスを返す。履歴 → スニペットアセットの順で探索。
    func imageURL(for fileName: String) -> URL {
        let historyURL = imagesDir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: historyURL.path) {
            return historyURL
        }
        return snippetAssetsDir.appendingPathComponent(fileName)
    }

    // MARK: - 削除（両ディレクトリから）

    /// 画像ファイルとサムネイルを削除する。
    func delete(fileName: String) {
        let fm = FileManager.default
        for dir in [imagesDir, snippetAssetsDir] {
            try? fm.removeItem(at: dir.appendingPathComponent(fileName))
        }
        for dir in [thumbsDir, snippetThumbsDir] {
            try? fm.removeItem(at: dir.appendingPathComponent(fileName))
        }
        thumbCache.removeObject(forKey: fileName as NSString)
    }

    // MARK: - Private

    private func saveImage(data: Data, utType: String, originalFileName: String?,
                           targetDir: URL, targetThumbsDir: URL) -> ImageMetadata? {
        let fileName = "\(UUID().uuidString).png"
        let fileURL = targetDir.appendingPathComponent(fileName)

        guard let pngData = convertToPNG(data: data) else { return nil }
        do {
            try pngData.write(to: fileURL, options: .atomic)
        } catch {
            return nil
        }

        let (width, height) = imagePixelSize(data: pngData) ?? (0, 0)
        generateThumbnail(fileName: fileName, sourceData: pngData, thumbsDir: targetThumbsDir)

        return ImageMetadata(
            fileName: fileName,
            originalUTType: utType,
            originalFileName: originalFileName,
            pixelWidth: width,
            pixelHeight: height,
            fileSizeBytes: Int64(pngData.count)
        )
    }

    /// 任意の画像データを PNG に変換。
    private func convertToPNG(data: Data) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }

    /// 画像のピクセルサイズを取得。
    private func imagePixelSize(data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }

    /// CGImageSource のサムネイル生成機能を使い、効率的に縮小画像を作成。
    private func generateThumbnail(fileName: String, sourceData: Data, thumbsDir: URL) {
        let thumbURL = thumbsDir.appendingPathComponent(fileName)
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil) else { return }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.thumbMaxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]

        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return }
        let rep = NSBitmapImageRep(cgImage: cgThumb)
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return }
        try? pngData.write(to: thumbURL, options: .atomic)
    }
}
