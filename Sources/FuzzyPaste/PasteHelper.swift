import AppKit
import CoreGraphics

/// クリップボードへの書き込みと、Cmd+V シミュレートによるペースト操作を担当。
///
/// ペーストの流れ:
/// 1. テキストをクリップボードにセット
/// 2. 元アプリをアクティブにする
/// 3. 少し待ってからCGEvent でCmd+V キー入力をシミュレート
///
/// ※ CGEvent の投稿にはアクセシビリティ権限が必要。
///   システム設定 → プライバシーとセキュリティ → アクセシビリティ で許可する。
@MainActor
enum PasteHelper {
    /// V キーの仮想キーコード。HotkeyManager でも参照するため internal アクセス。
    static let vKeyCode: CGKeyCode = 9

    /// 元アプリがアクティブになるまで待つ時間。
    /// 短すぎるとアプリ切替が完了する前にキーイベントが飛んでしまう。
    private static let activationDelay: Duration = .milliseconds(100)

    /// テキストをクリップボードにセットし、元アプリにフォーカスを戻してからCmd+Vをシミュレート
    static func paste(_ text: String, previousApp: NSRunningApplication?) {
        copyToClipboard(text)
        previousApp?.activate()

        Task { @MainActor in
            try? await Task.sleep(for: activationDelay)
            simulatePaste()
        }
    }

    /// テキストをクリップボードにセットする（ペーストはしない）
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// CGEvent を使って Cmd+V キー押下をシミュレート。
    /// これにより、アクティブなアプリにペーストが実行される。
    private static func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
