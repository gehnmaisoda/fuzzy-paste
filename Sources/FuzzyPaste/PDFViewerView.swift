import AppKit
import PDFKit

/// PDF を表示するビュー。PDFKit の PDFView をラップし、ページ送り・ズーム対応。
@MainActor
final class PDFViewerView: NSView {
    private let pdfView = PDFView()
    private let pageLabel = NSTextField(labelWithString: "")

    /// PDF ファイル拡張子
    static let fileExtensions: Set<String> = ["pdf"]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        // PDFView 設定
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .clear
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pdfView)

        // ページ数ラベル
        pageLabel.font = .systemFont(ofSize: 10, weight: .medium)
        pageLabel.textColor = .tertiaryLabelColor
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pageLabel)

        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: pageLabel.topAnchor, constant: -4),

            pageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pageLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    /// PDF ドキュメントをセットして表示する。
    func setPDF(_ document: PDFDocument) {
        pdfView.document = document
        let pageCount = document.pageCount
        pageLabel.stringValue = "\(pageCount) page\(pageCount == 1 ? "" : "s")"

        // 先頭ページに移動（レイアウト確定後に実行しないと効かない）
        if let firstPage = document.page(at: 0) {
            let bounds = firstPage.bounds(for: pdfView.displayBox)
            let dest = PDFDestination(page: firstPage, at: NSPoint(x: 0, y: bounds.maxY))
            DispatchQueue.main.async { [weak self] in
                self?.pdfView.go(to: dest)
            }
        }
    }

    /// 1ページ目のサムネイル画像を返す。ファイル名をキーにキャッシュする。
    static func thumbnail(for url: URL, size: CGFloat = 128) -> NSImage? {
        let key = url.lastPathComponent as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }
        guard let document = PDFDocument(url: url),
              let page = document.page(at: 0) else { return nil }
        let image = page.thumbnail(of: NSSize(width: size, height: size), for: .mediaBox)
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    private static let thumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 50
        return cache
    }()
}
