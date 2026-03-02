import AppKit
import SwiftUI

/// 設定ウィンドウ。NSHostingView で SwiftUI の PreferencesView をホストする。
/// SnippetManagerWindow と同じパターン (styleMask, NSVisualEffectView, isReleasedWhenClosed = false)。
@MainActor
final class PreferencesWindow: NSWindow {

    private enum Layout {
        static let windowSize = NSSize(width: 640, height: 440)
        static let cornerRadius: CGFloat = 14
    }

    private enum KeyCode {
        static let w: UInt16 = 13
    }

    init(store: PreferencesStore) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Layout.windowSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "設定"
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        minSize = NSSize(width: 480, height: 320)

        let bg = NSVisualEffectView()
        bg.material = .sheet
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = Layout.cornerRadius
        bg.layer?.masksToBounds = true
        contentView = bg

        let hostingView = NSHostingView(rootView: PreferencesView(store: store))
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
        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            setFrameOrigin(NSPoint(x: sf.midX - frame.width / 2, y: sf.midY - frame.height / 2))
        }

        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == KeyCode.w && flags == .command {
            orderOut(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
