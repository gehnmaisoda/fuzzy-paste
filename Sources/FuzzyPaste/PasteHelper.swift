import AppKit
import CoreGraphics

/// クリップボードへの書き込みと、Cmd+V シミュレートによるペースト操作を担当。
///
/// ペーストの流れ:
/// 1. テキスト/画像/ファイルをクリップボードにセット
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
    /// ファイルペースト用の一時ディレクトリ
    private static let pasteTempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("FuzzyPaste-paste", isDirectory: true)

    /// テキストをクリップボードにセットし、元アプリにフォーカスを戻してからCmd+Vをシミュレート
    static func paste(_ text: String, previousApp: NSRunningApplication?) {
        copyToClipboard(text)
        previousApp?.activate()

        Task { @MainActor in
            try? await Task.sleep(for: activationDelay)
            simulatePaste()
        }
    }

    /// 複数テキストを結合してペーストする。選択順に改行で結合して単一のペースト操作として実行。
    static func paste(_ texts: [String], previousApp: NSRunningApplication?) {
        let joined = texts.joined(separator: "\n")
        paste(joined, previousApp: previousApp)
    }

    /// 画像をクリップボードにセットし、元アプリにフォーカスを戻してからCmd+Vをシミュレート
    static func pasteImage(at fileURL: URL, previousApp: NSRunningApplication?) {
        copyImageToClipboard(at: fileURL)
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

    /// ファイルをクリップボードにセットし、元アプリにフォーカスを戻してからCmd+Vをシミュレート。
    /// 一時ディレクトリに元ファイル名でコピーし、NSURL として書き込む。
    static func pasteFile(at fileURL: URL, originalFileName: String, previousApp: NSRunningApplication?) {
        copyFileToClipboard(at: fileURL, originalFileName: originalFileName)
        previousApp?.activate()

        Task { @MainActor in
            try? await Task.sleep(for: activationDelay)
            simulatePaste()
        }
    }

    /// 画像をクリップボードにセットする（ペーストはしない）
    /// TIFF も同時に書き込むことで多くのアプリとの互換性を確保。
    static func copyImageToClipboard(at fileURL: URL) {
        guard let imageData = try? Data(contentsOf: fileURL),
              let image = NSImage(data: imageData) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    /// ファイルをクリップボードにセットする（ペーストはしない）。
    /// 一時ディレクトリに元ファイル名でコピーし、NSURL として書き込む。
    static func copyFileToClipboard(at fileURL: URL, originalFileName: String) {
        try? FileManager.default.createDirectory(at: pasteTempDir, withIntermediateDirectories: true)
        let copyURL = pasteTempDir.appendingPathComponent(originalFileName)
        try? FileManager.default.removeItem(at: copyURL)
        do {
            try FileManager.default.copyItem(at: fileURL, to: copyURL)
        } catch {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([copyURL as NSURL])
    }

    /// CGEvent を使って Cmd+V キー押下をシミュレート。
    /// これにより、アクティブなアプリにペーストが実行される。
    /// アクセシビリティ権限がない場合はアラートを表示して中断する。
    private static func simulatePaste() {
        guard AccessibilityChecker.isTrusted else {
            showAccessibilityRequiredAlert()
            return
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// アクセシビリティ権限がない状態でペーストしようとした場合のアラート。
    private static func showAccessibilityRequiredAlert() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ペーストにはアクセシビリティ権限が必要です"
        alert.informativeText = "システム設定で FuzzyPaste にアクセシビリティ権限を付与してください。"
        alert.addButton(withTitle: "システム設定を開く")
        alert.addButton(withTitle: "閉じる")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            AccessibilityChecker.openSystemPreferences()
        }
    }
}
