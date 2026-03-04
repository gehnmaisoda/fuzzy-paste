import AppKit
import SwiftUI

/// 初回起動時のオンボーディングウィンドウ。
/// PreferencesWindow と同じパターン (NSWindow + NSHostingView + NSVisualEffectView)。
@MainActor
final class OnboardingWindow: NSWindow {

    private enum Layout {
        static let windowSize = NSSize(width: 420, height: 480)
        static let cornerRadius: CGFloat = 14
    }

    /// 「始める」ボタンが押された時のコールバック（オンボーディング完了）
    var onDidComplete: (() -> Void)?
    /// 閉じるボタン等で「始める」を押さずに閉じた時のコールバック
    var onDismissed: (() -> Void)?

    /// 「始める」ボタン経由で閉じたかどうかを区別するフラグ
    private var didComplete = false

    init(store: PreferencesStore) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Layout.windowSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "FuzzyPaste"
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear

        let bg = NSVisualEffectView()
        bg.material = .sheet
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = Layout.cornerRadius
        bg.layer?.masksToBounds = true
        contentView = bg

        let hostingView = NSHostingView(
            rootView: OnboardingView(store: store) { [weak self] in
                self?.didComplete = true
                self?.orderOut(nil)
            }
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: bg.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])
    }

    func showWindow() {
        didComplete = false

        // LSUIElement アプリは通常のウィンドウ管理に参加しないため、
        // オンボーディング中だけ .regular にして Cmd+W 等で自然にフォーカスが戻るようにする。
        NSApp.setActivationPolicy(.regular)

        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            setFrameOrigin(NSPoint(x: sf.midX - frame.width / 2, y: sf.midY - frame.height / 2))
        }

        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    override func orderOut(_ sender: Any?) {
        let callback = didComplete ? onDidComplete : onDismissed
        onDidComplete = nil
        onDismissed = nil
        callback?()

        super.orderOut(sender)
        NSApp.setActivationPolicy(.accessory)
    }
}
