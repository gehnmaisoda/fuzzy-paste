import AppKit
import PDFKit

/// PDF を表示するビュー。PDFKit の PDFView をラップし、ページ送り・ズーム対応。
@MainActor
final class PDFViewerView: NSView {
    private let pdfView = PDFView()
    private let pageLabel = NSTextField(labelWithString: "")
    /// 読み込み中の PDF を識別し、完了時に別の PDF に切り替わっていたら破棄する
    private var currentLoadingKey: String?

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

    /// URL から PDF をバックグラウンドで読み込んで表示する。
    /// キャッシュ済みの場合は即座に表示する。
    func loadPDF(from url: URL) {
        let cacheKey = url.lastPathComponent
        if let cached = Self.documentCache.object(forKey: cacheKey as NSString) {
            applyDocument(cached)
            return
        }
        // 読み込み完了時に別の PDF に切り替わっていた場合は破棄する
        currentLoadingKey = cacheKey
        let path = url.path
        Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { return }
            await MainActor.run { [weak self] in
                guard let self, self.currentLoadingKey == cacheKey else { return }
                Self.documentCache.setObject(document, forKey: cacheKey as NSString)
                self.applyDocument(document)
            }
        }
    }

    /// PDF ドキュメントをセットして表示する。
    func setPDF(_ document: PDFDocument) {
        applyDocument(document)
    }

    private func applyDocument(_ document: PDFDocument) {
        pdfView.document = document
        let pageCount = document.pageCount
        pageLabel.stringValue = "\(pageCount) page\(pageCount == 1 ? "" : "s")"

        // 初期表示は 70% 縮小（プレビュー領域が限られるため全体が見えるように）
        pdfView.autoScales = false
        pdfView.scaleFactor = 0.7

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

    private static let documentCache: NSCache<NSString, PDFDocument> = {
        let cache = NSCache<NSString, PDFDocument>()
        cache.countLimit = 10
        return cache
    }()
}
