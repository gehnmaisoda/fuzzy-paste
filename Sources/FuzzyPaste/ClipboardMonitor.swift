import AppKit

/// クリップボードから取得したコンテンツの種別。
enum ClipboardContent: Sendable {
    case text(String)
    case imageData(Data, utType: String, originalFileName: String?)
}

/// システムクリップボード (NSPasteboard.general) を定期的にポーリングし、
/// 新しいテキストまたは画像がコピーされたことを検知するモニター。
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
    /// 自分自身がペースト/コピーした後の changeCount を記録し、
    /// 次のポーリングで一致したらスキップすることで重複検知を防ぐ。
    private var changeCountToIgnore: Int?
    var onNewClip: ((ClipboardContent) -> Void)?

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

    /// 次に検知する changeCount を無視する。
    /// ペースト/コピー操作で自分がクリップボードに書き込んだ後に呼び、
    /// 書き込み後の changeCount を記録する。
    func ignoreNextChange() {
        changeCountToIgnore = pasteboard.changeCount
    }

    private func checkForChanges() {
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        // 自分が書き込んだ changeCount なら無視してリセット
        if let ignoreCount = changeCountToIgnore, currentCount == ignoreCount {
            changeCountToIgnore = nil
            return
        }
        changeCountToIgnore = nil

        // 画像を先にチェック（Web コピーは画像+テキスト両方入る → 画像優先）
        if let imageContent = detectImage() {
            onNewClip?(imageContent)
            return
        }

        // テキスト
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            onNewClip?(.text(text))
        }
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic"]

    /// ペーストボードから画像データを検出する。
    /// Finder のファイルコピーの場合は実際の画像ファイルを読み込む。
    private func detectImage() -> ClipboardContent? {
        let hasFileURL = pasteboard.types?.contains(.fileURL) == true

        if hasFileURL {
            // Finder のファイルコピー → 画像ファイルなら中身を読む
            // ファイルコピー時の TIFF はファイルアイコンなので無視する
            return detectImageFromFileURL()
        }

        // スクリーンショットや Web コピー → TIFF/PNG を直接取得
        if let data = pasteboard.data(forType: .tiff) {
            return .imageData(data, utType: "public.tiff", originalFileName: nil)
        }
        if let data = pasteboard.data(forType: .png) {
            return .imageData(data, utType: "public.png", originalFileName: nil)
        }
        return nil
    }

    /// ペーストボード上のファイルURLから画像ファイルを読み込む。
    private func detectImageFromFileURL() -> ClipboardContent? {
        guard let urlString = pasteboard.string(forType: .fileURL),
              let url = URL(string: urlString) else { return nil }
        let ext = url.pathExtension.lowercased()
        guard Self.imageExtensions.contains(ext) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let originalFileName = url.lastPathComponent
        return .imageData(data, utType: "public.\(ext)", originalFileName: originalFileName)
    }
}
