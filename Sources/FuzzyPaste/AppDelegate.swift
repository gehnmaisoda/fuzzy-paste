import AppKit

/// アプリ全体のライフサイクルを管理する司令塔。
/// メニューバー常駐、クリップボード監視、ホットキー、検索ウィンドウを統括する。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let appVersion = "0.1.0"

    private var statusItem: NSStatusItem!
    private let clipboardMonitor = ClipboardMonitor()
    private let historyStore = HistoryStore()
    private let hotkeyManager = HotkeyManager()
    private let snippetStore = SnippetStore()
    private let imageStore = ImageStore()
    private var searchWindow: SearchWindow?
    private var snippetManagerWindow: SnippetManagerWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupImageStore()
        startClipboardMonitor()
        setupHotkey()
    }

    // MARK: - 画像ストア

    private func setupImageStore() {
        historyStore.onImageDelete = { [weak self] fileName in
            self?.imageStore.delete(fileName: fileName)
        }
    }

    // MARK: - クリップボード監視

    private func startClipboardMonitor() {
        clipboardMonitor.onNewClip = { [weak self] content in
            guard let self else { return }
            switch content {
            case .text(let text):
                self.historyStore.add(text)
            case .imageData(let data, let utType, let originalFileName):
                if let metadata = self.imageStore.save(data: data, utType: utType, originalFileName: originalFileName) {
                    self.historyStore.addImage(metadata)
                }
            }
        }
        clipboardMonitor.start()
    }

    // MARK: - グローバルホットキー

    private func setupHotkey() {
        hotkeyManager.onHotkey = { [weak self] in
            self?.toggleSearchWindow()
        }
        hotkeyManager.register()
    }

    // MARK: - 検索ウィンドウ

    /// Cmd+Shift+V で呼ばれるトグル処理。
    /// 表示中なら閉じる、非表示なら開く。
    private func toggleSearchWindow() {
        if let window = searchWindow, window.isVisible {
            window.dismiss()
            return
        }

        // ウィンドウは一度作ったら再利用する（毎回生成しない）
        let window = searchWindow ?? createSearchWindow()
        searchWindow = window
        window.show(clips: historyStore.items, snippets: snippetStore.items, imageStore: imageStore)
    }

    private func createSearchWindow() -> SearchWindow {
        let window = SearchWindow()
        window.onPaste = { [weak self] item, previousApp in
            guard let self else { return }
            self.clipboardMonitor.ignoreNextChange()
            switch item.content {
            case .text(let text):
                PasteHelper.paste(text, previousApp: previousApp)
            case .image(let meta):
                let url = self.imageStore.imageURL(for: meta.fileName)
                PasteHelper.pasteImage(at: url, previousApp: previousApp)
            }
        }
        window.onCopy = { [weak self] item in
            guard let self else { return }
            self.clipboardMonitor.ignoreNextChange()
            switch item.content {
            case .text(let text):
                PasteHelper.copyToClipboard(text)
            case .image(let meta):
                let url = self.imageStore.imageURL(for: meta.fileName)
                PasteHelper.copyImageToClipboard(at: url)
            }
        }
        window.onOpenSnippetManager = { [weak self] in
            self?.showSnippetManager()
        }
        return window
    }

    // MARK: - スニペット管理

    private func showSnippetManager() {
        let window = snippetManagerWindow ?? SnippetManagerWindow(store: snippetStore)
        snippetManagerWindow = window
        window.showWindow()
    }

    @objc private func menuShowSnippetManager() {
        showSnippetManager()
    }

    // MARK: - メニューバー

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "scissors",
                accessibilityDescription: "FuzzyPaste"
            )
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "FuzzyPaste v\(Self.appVersion)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "スニペット管理...", action: #selector(menuShowSnippetManager), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }
}
