import AppKit

/// システムクリップボード (NSPasteboard.general) を定期的にポーリングし、
/// 新しいテキストがコピーされたことを検知するモニター。
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
    /// 自分自身がペーストしたテキストを履歴に重複登録しないために、
    /// 次に検知するテキストを一時的に無視するための値。
    private var textToIgnore: String?
    var onNewClip: ((String) -> Void)?

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

    /// 次にこのテキストが検知されたら無視する。
    /// ペースト操作で自分がクリップボードに書き込んだテキストを、
    /// 新しいコピーとして重複検知しないための仕組み。
    func ignoreNext(_ text: String) {
        textToIgnore = text
    }

    private func checkForChanges() {
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }

        // 自分がペーストしたテキストなら無視して、フラグをリセット
        if let ignore = textToIgnore, text == ignore {
            textToIgnore = nil
            return
        }
        textToIgnore = nil

        onNewClip?(text)
    }
}
