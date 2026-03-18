import AppKit

/// クリップボードから取得したコンテンツの種別。
enum ClipboardContent: Sendable {
    case text(String)
    case imageData(Data, utType: String, originalFileName: String?)
    case fileData(Data, originalFileName: String)
}

/// システムクリップボード (NSPasteboard.general) を定期的にポーリングし、
/// 新しいテキスト・画像・ファイルがコピーされたことを検知するモニター。
///
/// macOS にはクリップボード変更の通知APIがないため、
/// changeCount を定期チェックする方式を採用（Clipy等も同じ手法）。
@MainActor
final class ClipboardMonitor {
    private static let pollInterval: TimeInterval = 0.5

    private var timer: Timer?
    /// changeCount はクリップボードが更新されるたびにインクリメントされる整数。
    /// 前回の値と比較することで変更を検知する。
    private var lastChangeCount: Int
    private let pasteboard = NSPasteboard.general
    /// 次のクリップボード変更を無視するフラグ。
    private var skipNextChange = false
    var onNewClip: ((ClipboardContent) -> Void)?
    /// フロントアプリの bundleIdentifier を受け取り、除外対象なら true を返す。
    var shouldExclude: ((String) -> Bool)?

    init() {
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkForChanges()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 次に検知するクリップボード変更を1回だけ無視する。
    /// クリップボードへの書き込み前に呼ぶ。
    func ignoreNextChange() {
        skipNextChange = true
    }

    private func checkForChanges() {
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        // 自分が書き込んだ変更なら無視してリセット
        if skipNextChange {
            skipNextChange = false
            return
        }

        // フロントアプリが除外対象ならスキップ
        if let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           shouldExclude?(bundleId) == true {
            return
        }

        // Finder のファイルコピー: 画像→ファイル→テキストの優先順で検出
        if let url = fileURLFromPasteboard() {
            if let content = detectImageFromFileURL(url) {
                onNewClip?(content)
                return
            }
            if let content = detectFileFromFileURL(url) {
                onNewClip?(content)
                return
            }
        }

        // スクリーンショットや Web コピー → TIFF/PNG を直接取得
        if let imageContent = detectImageDirect() {
            onNewClip?(imageContent)
            return
        }

        // テキスト
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            onNewClip?(.text(text))
        }
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic"]
    /// ファイルサイズ上限: 50MB
    private static let maxFileSize: Int64 = 50 * 1024 * 1024

    /// ペーストボードからファイル URL を取得する。
    private func fileURLFromPasteboard() -> URL? {
        guard pasteboard.types?.contains(.fileURL) == true,
              let urlString = pasteboard.string(forType: .fileURL) else { return nil }
        return URL(string: urlString)
    }

    /// ペーストボードから直接画像データを検出する（スクリーンショットや Web コピー用）。
    private func detectImageDirect() -> ClipboardContent? {
        if let data = pasteboard.data(forType: .tiff) {
            return .imageData(data, utType: "public.tiff", originalFileName: nil)
        }
        if let data = pasteboard.data(forType: .png) {
            return .imageData(data, utType: "public.png", originalFileName: nil)
        }
        return nil
    }

    /// ファイル URL が画像ファイルなら読み込んで返す。
    private func detectImageFromFileURL(_ url: URL) -> ClipboardContent? {
        let ext = url.pathExtension.lowercased()
        guard Self.imageExtensions.contains(ext) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return .imageData(data, utType: "public.\(ext)", originalFileName: url.lastPathComponent)
    }

    /// ファイル URL が画像以外の通常ファイルなら読み込んで返す。
    private func detectFileFromFileURL(_ url: URL) -> ClipboardContent? {
        let ext = url.pathExtension.lowercased()
        // 画像は detectImageFromFileURL で処理済み
        guard !Self.imageExtensions.contains(ext) else { return nil }
        // ディレクトリはスキップ
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        // ファイルサイズチェック
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? Int64,
              fileSize <= Self.maxFileSize else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return .fileData(data, originalFileName: url.lastPathComponent)
    }
}
