import AppKit
import ApplicationServices

/// アクセシビリティ権限の確認・リクエストを担当するユーティリティ。
///
/// FuzzyPaste は以下の機能でアクセシビリティ権限が必須:
/// - PasteHelper: CGEvent.post(tap: .cghidEventTap) による Cmd+V シミュレート
/// - HotkeyManager: Carbon RegisterEventHotKey によるグローバルホットキー登録
///
/// macOS にはアクセシビリティ権限の変更を通知するコールバック API がないため、
/// 権限付与までポーリングで監視する。
@MainActor
enum AccessibilityChecker {

    /// アクセシビリティ権限が付与されているかどうか。
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// システムダイアログを表示してアクセシビリティ権限をリクエストする。
    static func requestAccess() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// システム設定のアクセシビリティページを直接開く。
    static func openSystemPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 権限が付与されるまでポーリングし、付与されたらコールバックを実行する。
    /// ポーリング間隔は 1 秒。権限が既に付与済みの場合は即座にコールバックを呼ぶ。
    private static var pollTimer: Timer?

    static func pollUntilTrusted(then callback: @escaping @MainActor @Sendable () -> Void) {
        if isTrusted {
            callback()
            return
        }

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                if AXIsProcessTrusted() {
                    pollTimer?.invalidate()
                    pollTimer = nil
                    callback()
                }
            }
        }
    }
}
