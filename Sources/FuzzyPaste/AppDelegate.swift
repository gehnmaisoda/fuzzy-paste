import AppKit
import Combine
import FuzzyPasteCore

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
    private let fileStore = FileStore()
    private let preferencesStore = PreferencesStore()
    private var searchWindow: SearchWindow?
    private var snippetManagerWindow: SnippetManagerWindow?
    private var preferencesWindow: PreferencesWindow?
    private var onboardingWindow: OnboardingWindow?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupStores()
        setupExcludedApps()
        startClipboardMonitor()
        setupHotkeyOrShowOnboarding()
        observeWindowSizePreset()
        observeMaxHistoryCount()
        observeHotkeyConfig()
    }

    // MARK: - ストア初期化

    private func setupStores() {
        historyStore.onImageDelete = { [weak self] fileName in
            self?.imageStore.delete(fileName: fileName)
        }
        historyStore.onFileDelete = { [weak self] fileName in
            self?.fileStore.delete(fileName: fileName)
        }
        historyStore.setMaxItems(preferencesStore.maxHistoryCount)
    }

    // MARK: - 除外アプリ

    private func setupExcludedApps() {
        clipboardMonitor.shouldExclude = { [weak self] bundleId in
            self?.preferencesStore.isExcluded(bundleIdentifier: bundleId) ?? false
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
            case .fileData(let data, let originalFileName):
                if let metadata = self.fileStore.save(data: data, originalFileName: originalFileName) {
                    self.historyStore.addFile(metadata)
                }
            }
        }
        clipboardMonitor.start()
    }

    // MARK: - オンボーディング・ホットキー

    /// 起動時の初期化: オンボーディング未完了なら表示、完了済みならホットキーを登録する。
    private func setupHotkeyOrShowOnboarding() {
        if !preferencesStore.hasCompletedOnboarding {
            showOnboarding()
            return
        }
        setupHotkey()
    }

    private func setupHotkey() {
        hotkeyManager.onHotkey = { [weak self] in
            self?.toggleSearchWindow()
        }
        let config = preferencesStore.hotkeyConfig
        hotkeyManager.register(keyCode: config.keyCode, modifiers: config.carbonModifiers)
    }

    private func showOnboarding() {
        // 既に表示中ならフォーカスだけ戻す
        if let existing = onboardingWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let window = OnboardingWindow(store: preferencesStore)
        onboardingWindow = window

        // 「始める」ボタン経由 → オンボーディング完了 + ホットキー登録
        window.onDidComplete = { [weak self] in
            guard let self else { return }
            self.preferencesStore.completeOnboarding()
            self.onboardingWindow = nil
            self.setupHotkey()
        }

        // 閉じるボタン等 → 完了しない（次回また表示される）
        window.onDismissed = { [weak self] in
            self?.onboardingWindow = nil
        }

        window.showWindow()
    }

    // MARK: - 設定変更監視

    private func observeWindowSizePreset() {
        preferencesStore.$windowSizePreset
            .dropFirst()
            .sink { [weak self] _ in
                self?.searchWindow = nil
            }
            .store(in: &cancellables)
    }

    private func observeMaxHistoryCount() {
        preferencesStore.$maxHistoryCount
            .dropFirst()
            .sink { [weak self] count in
                self?.historyStore.setMaxItems(count)
            }
            .store(in: &cancellables)
    }

    private func observeHotkeyConfig() {
        preferencesStore.$hotkeyConfig
            .dropFirst()
            .sink { [weak self] config in
                guard let self else { return }
                // 録音中は再登録しない（stopRecording で再登録される）
                guard !self.preferencesStore.isRecordingHotkey else { return }
                self.hotkeyManager.unregister()
                self.hotkeyManager.register(keyCode: config.keyCode, modifiers: config.carbonModifiers)
            }
            .store(in: &cancellables)

        // 録音開始・終了時の同期コールバック（Combine 経由だとタイミング問題があるため直接呼ぶ）
        preferencesStore.onPauseHotkey = { [weak self] in
            self?.hotkeyManager.unregister()
        }
        preferencesStore.onResumeHotkey = { [weak self] in
            guard let self else { return }
            let config = self.preferencesStore.hotkeyConfig
            self.hotkeyManager.register(keyCode: config.keyCode, modifiers: config.carbonModifiers)
        }
    }

    // MARK: - 検索ウィンドウ

    /// Cmd+Shift+V で呼ばれるトグル処理。
    /// 表示中なら閉じる、非表示なら開く。
    private func toggleSearchWindow() {
        // オンボーディング未完了 → オンボーディングを表示
        if !preferencesStore.hasCompletedOnboarding {
            showOnboarding()
            return
        }

        if let window = searchWindow, window.isVisible {
            window.dismiss()
            return
        }

        // ウィンドウは一度作ったら再利用する（毎回生成しない）
        let window = searchWindow ?? createSearchWindow()
        searchWindow = window
        window.show(clips: historyStore.items, snippets: snippetStore.items, imageStore: imageStore, fileStore: fileStore, allTags: snippetStore.allTags)
    }

    private func createSearchWindow() -> SearchWindow {
        let window = SearchWindow(layout: preferencesStore.layoutConfig)
        window.onPaste = { [weak self] item, previousApp in
            guard let self else { return }
            self.clipboardMonitor.ignoreNextChange()
            switch item.content {
            case .text(let text):
                PasteHelper.paste(text, previousApp: previousApp)
            case .image(let meta):
                let url = self.imageStore.imageURL(for: meta.fileName)
                PasteHelper.pasteImage(at: url, previousApp: previousApp)
            case .file(let meta):
                let url = self.fileStore.fileURL(for: meta.fileName)
                PasteHelper.pasteFile(at: url, originalFileName: meta.originalFileName, previousApp: previousApp)
            }
        }
        window.onMultiPaste = { [weak self] items, previousApp in
            guard let self else { return }
            self.clipboardMonitor.ignoreNextChange()
            // テキストアイテムのみ抽出し、選択順に改行で結合してペースト
            let texts = items.compactMap { item -> String? in
                if case .text(let text) = item.content { return text }
                return nil
            }
            guard !texts.isEmpty else { return }
            PasteHelper.paste(texts, previousApp: previousApp)
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
            case .file(let meta):
                let url = self.fileStore.fileURL(for: meta.fileName)
                PasteHelper.copyFileToClipboard(at: url, originalFileName: meta.originalFileName)
            }
        }
        window.onOpenSnippetManager = { [weak self] in
            self?.showSnippetManager()
        }
        window.onOpenPreferences = { [weak self] in
            self?.showPreferences()
        }
        return window
    }

    // MARK: - スニペット管理

    private func showSnippetManager() {
        // オンボーディング未完了 → オンボーディングを表示
        if !preferencesStore.hasCompletedOnboarding {
            showOnboarding()
            return
        }

        let window = snippetManagerWindow ?? SnippetManagerWindow(store: snippetStore)
        snippetManagerWindow = window
        window.showWindow()
    }

    @objc private func menuShowSnippetManager() {
        showSnippetManager()
    }

    // MARK: - 設定

    private func showPreferences() {
        // オンボーディング未完了 → オンボーディングを表示
        if !preferencesStore.hasCompletedOnboarding {
            showOnboarding()
            return
        }

        let window = preferencesWindow ?? PreferencesWindow(store: preferencesStore, historyStore: historyStore)
        preferencesWindow = window
        window.showWindow()
    }

    @objc private func menuShowPreferences() {
        showPreferences()
    }

    // MARK: - メニューバー

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "doc.text.magnifyingglass",
                accessibilityDescription: "FuzzyPaste"
            )
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "FuzzyPaste v\(Self.appVersion)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let snippetItem = NSMenuItem(title: "スニペット管理", action: #selector(menuShowSnippetManager), keyEquivalent: "e")
        snippetItem.keyEquivalentModifierMask = [.command]
        menu.addItem(snippetItem)
        let prefsItem = NSMenuItem(title: "設定", action: #selector(menuShowPreferences), keyEquivalent: ",")
        prefsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(prefsItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }
}
