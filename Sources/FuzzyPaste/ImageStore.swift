import AppKit
import ImageIO

/// 画像ファイルの保存・読み込み・サムネイル生成を担当するストア。
///
/// 保存先: ~/Library/Application Support/FuzzyPaste/images/
/// サムネイル: ~/Library/Application Support/FuzzyPaste/images/thumbs/
@MainActor
final class ImageStore {
    private let imagesDir: URL
    private let thumbsDir: URL
    /// サムネイルのメモリキャッシュ。頻繁にスクロールされる検索ウィンドウ向け。
    private let thumbCache = NSCache<NSString, NSImage>()
    /// サムネイルサイズ (128x128 @2x = 256px)
    private static let thumbMaxPixels = 256

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let base = appSupport.appendingPathComponent("FuzzyPaste")
        imagesDir = base.appendingPathComponent("images")
        thumbsDir = imagesDir.appendingPathComponent("thumbs")
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        thumbCache.countLimit = 200
    }

    /// 画像データを保存し、メタデータを返す。失敗時は nil。
    func save(data: Data, utType: String, originalFileName: String? = nil) -> ImageMetadata? {
        let fileName = "\(UUID().uuidString).png"
        let fileURL = imagesDir.appendingPathComponent(fileName)

        // PNG に変換して保存
        guard let pngData = convertToPNG(data: data) else { return nil }
        do {
            try pngData.write(to: fileURL, options: .atomic)
        } catch {
            return nil
        }

        // 画像サイズを取得
        let (width, height) = imagePixelSize(data: pngData) ?? (0, 0)

        // サムネイル生成
        generateThumbnail(fileName: fileName, sourceData: pngData)

        return ImageMetadata(
            fileName: fileName,
            originalUTType: utType,
            originalFileName: originalFileName,
            pixelWidth: width,
            pixelHeight: height,
            fileSizeBytes: Int64(pngData.count)
        )
    }

    /// サムネイル画像を返す。キャッシュ → ディスク → nil の順で探索。
    func thumbnail(for fileName: String) -> NSImage? {
        let key = fileName as NSString
        if let cached = thumbCache.object(forKey: key) {
            return cached
        }

        let thumbURL = thumbsDir.appendingPathComponent(fileName)
        guard let image = NSImage(contentsOf: thumbURL) else { return nil }
        thumbCache.setObject(image, forKey: key)
        return image
    }

    /// 画像ファイルのフルパスを返す。
    func imageURL(for fileName: String) -> URL {
        imagesDir.appendingPathComponent(fileName)
    }

    /// 画像ファイルとサムネイルを削除する。
    func delete(fileName: String) {
        let fileURL = imagesDir.appendingPathComponent(fileName)
        let thumbURL = thumbsDir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: thumbURL)
        thumbCache.removeObject(forKey: fileName as NSString)
    }

    // MARK: - Private

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
    private func generateThumbnail(fileName: String, sourceData: Data) {
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
