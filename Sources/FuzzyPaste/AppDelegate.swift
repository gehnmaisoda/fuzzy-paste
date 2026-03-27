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
    private var dynamicSnippetWindow: DynamicSnippetWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var fileWatchTimer: Timer?
    private var lastKnownModDates: [String: Date] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupStores()
        setupExcludedApps()
        startClipboardMonitor()
        setupHotkeyOrShowOnboarding()
        observeWindowSizePreset()
        observeMaxHistoryCount()
        observeHotkeyConfig()
        startFileWatchers()
        backfillOCR()
    }

    // MARK: - ストア初期化

    private func setupStores() {
        historyStore.onImageDelete = { [weak self] fileName in
            self?.imageStore.delete(fileName: fileName)
        }
        historyStore.onFileDelete = { [weak self] fileName in
            self?.fileStore.delete(fileName: fileName)
        }
        snippetStore.onImageDelete = { [weak self] fileName in
            self?.imageStore.delete(fileName: fileName)
        }
        snippetStore.onFileDelete = { [weak self] fileName in
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
                    self.runOCR(for: metadata)
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
        // スニペットのタグ + クリップの autoTags を統合してサジェスト候補にする
        let clipAutoTags = historyStore.items.flatMap { $0.content.autoTags }
        let allTags = Array(Set(snippetStore.allTags + clipAutoTags)).sorted()
        window.show(clips: historyStore.items, snippets: snippetStore.items, imageStore: imageStore, fileStore: fileStore, allTags: allTags)
    }

    private func createSearchWindow() -> SearchWindow {
        let window = SearchWindow(layout: preferencesStore.layoutConfig)
        window.onPaste = { [weak self] item, previousApp, snippetId in
            guard let self else { return }
            self.clipboardMonitor.ignoreNextChange()
            self.historyStore.recordUse(id: item.id)
            if let snippetId {
                self.historyStore.addSnippetUse(snippetId: snippetId)
            }
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
            self.historyStore.recordUses(ids: items.map(\.id))
            // テキストアイテムのみ抽出し、選択順に改行で結合してペースト
            let texts = items.compactMap { item -> String? in
                if case .text(let text) = item.content { return text }
                return nil
            }
            guard !texts.isEmpty else { return }
            PasteHelper.paste(texts, previousApp: previousApp)
        }
        window.onCopy = { [weak self] item, snippetId in
            guard let self else { return }
            self.clipboardMonitor.ignoreNextChange()
            self.historyStore.recordUse(id: item.id)
            if let snippetId {
                self.historyStore.addSnippetUse(snippetId: snippetId)
            }
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
        window.onSaveAsSnippet = { [weak self] content in
            self?.saveAsSnippet(content: content)
        }
        window.onOpenPreferences = { [weak self] in
            self?.showPreferences()
        }
        window.onDynamicSnippetPaste = { [weak self] snippet, previousApp in
            self?.showDynamicSnippetDialog(snippet: snippet, previousApp: previousApp)
        }
        return window
    }

    // MARK: - 動的スニペット

    private func showDynamicSnippetDialog(snippet: SnippetItem, previousApp: NSRunningApplication?) {
        guard let text = snippet.text else { return }
        let placeholders = PlaceholderParser.extractPlaceholders(from: text)
        guard !placeholders.isEmpty else { return }

        let window = DynamicSnippetWindow(snippet: snippet, placeholders: placeholders)
        window.onPaste = { [weak self] resolvedText in
            guard let self else { return }
            self.clipboardMonitor.ignoreNextChange()
            self.historyStore.add(resolvedText)
            self.historyStore.addSnippetUse(snippetId: snippet.id)
            PasteHelper.paste(resolvedText, previousApp: previousApp)
            self.dynamicSnippetWindow = nil
        }
        window.onCopy = { [weak self] resolvedText in
            guard let self else { return }
            self.clipboardMonitor.ignoreNextChange()
            self.historyStore.add(resolvedText)
            self.historyStore.addSnippetUse(snippetId: snippet.id)
            PasteHelper.copyToClipboard(resolvedText)
            self.dynamicSnippetWindow = nil
        }
        window.onCancel = { [weak self] in
            guard let self else { return }
            self.dynamicSnippetWindow = nil
            // 検索ウィンドウを再表示し、previousApp を復元
            self.toggleSearchWindow()
            self.searchWindow?.restorePreviousApp(previousApp)
        }
        dynamicSnippetWindow = window
        window.showCentered()
    }

    // MARK: - スニペット管理

    /// SnippetManagerWindow を取得（なければ生成）。オンボーディング未完了なら nil。
    private func ensureSnippetManager() -> SnippetManagerWindow? {
        if !preferencesStore.hasCompletedOnboarding {
            showOnboarding()
            return nil
        }
        let window = snippetManagerWindow ?? SnippetManagerWindow(store: snippetStore, imageStore: imageStore, fileStore: fileStore)
        snippetManagerWindow = window
        return window
    }

    private func saveAsSnippet(content: SnippetContent) {
        ensureSnippetManager()?.addSnippetWithContent(content)
    }

    private func showSnippetManager() {
        ensureSnippetManager()?.showWindow()
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

    // MARK: - ファイル変更監視

    /// ファイル/ディレクトリの変更を定期チェックし、外部プロセス（CLI 等）による変更を自動リロードする。
    /// 更新日時を比較し、自分の save 以外の変更のみリロードする。
    private func startFileWatchers() {
        fileWatchTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.checkFileChanges()
            }
        }
    }

    private func checkFileChanges() {
        let fm = FileManager.default

        // 履歴・設定: 単一ファイルの mod date を監視
        let fileTargets: [(url: URL, lastSave: Date, reload: () -> Void)] = [
            (historyStore.monitoredFileURL, historyStore.lastSaveDate, { [weak self] in self?.historyStore.reload() }),
            (preferencesStore.monitoredFileURL, preferencesStore.lastSaveDate, { [weak self] in self?.preferencesStore.reload() }),
        ]

        for target in fileTargets {
            let key = target.url.lastPathComponent
            guard let attrs = try? fm.attributesOfItem(atPath: target.url.path),
                  let modDate = attrs[.modificationDate] as? Date else { continue }
            let lastKnown = lastKnownModDates[key] ?? .distantPast
            if modDate > lastKnown {
                lastKnownModDates[key] = modDate
                if Date().timeIntervalSince(target.lastSave) > 1 {
                    target.reload()
                }
            }
        }

        // スニペット: ディレクトリ内の .md ファイルを個別に mod date チェック
        // ディレクトリの mod date はファイル追加/削除時のみ変わり、
        // 既存ファイルの編集では変わらないため、各ファイルを個別に確認する。
        if Date().timeIntervalSince(snippetStore.lastSaveDate) > 1 {
            checkSnippetFileChanges(fm: fm)
        }
    }

    /// snippets ディレクトリ内の .md ファイルの mod date を個別チェックし、
    /// 変更があれば reload する。
    private func checkSnippetFileChanges(fm: FileManager) {
        let dir = snippetStore.monitoredFileURL
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }

        let mdFiles = files.filter { $0.pathExtension.lowercased() == "md" }

        // ファイル数の変化（追加/削除）を検出
        let currentCount = mdFiles.count
        let lastCount = lastKnownModDates["snippets-count"].flatMap { Int($0.timeIntervalSince1970) } ?? -1
        if currentCount != lastCount {
            lastKnownModDates["snippets-count"] = Date(timeIntervalSince1970: Double(currentCount))
            snippetStore.reload()
            // reload 後に全ファイルの mod date を更新
            updateSnippetModDates(mdFiles, fm: fm)
            return
        }

        // 各ファイルの mod date をチェック
        for fileURL in mdFiles {
            let key = "snippet:\(fileURL.lastPathComponent)"
            guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                  let modDate = attrs[.modificationDate] as? Date else { continue }
            let lastKnown = lastKnownModDates[key] ?? .distantPast
            if modDate > lastKnown {
                lastKnownModDates[key] = modDate
                snippetStore.reload()
                updateSnippetModDates(mdFiles, fm: fm)
                return
            }
        }
    }

    /// 全 .md ファイルの mod date をキャッシュに記録する。
    private func updateSnippetModDates(_ files: [URL], fm: FileManager) {
        for fileURL in files {
            let key = "snippet:\(fileURL.lastPathComponent)"
            if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
               let modDate = attrs[.modificationDate] as? Date {
                lastKnownModDates[key] = modDate
            }
        }
    }

    // MARK: - OCR

    /// 画像に対してバックグラウンドで OCR を実行し、結果を HistoryStore に保存する。
    private func runOCR(for metadata: ImageMetadata) {
        let imageURL = imageStore.imageURL(for: metadata.fileName)
        let fileName = metadata.fileName
        Task.detached {
            guard let text = await OCRService.recognizeText(from: imageURL) else { return }
            await MainActor.run { [weak self] in
                self?.historyStore.updateOCRText(text, forImageFileName: fileName)
            }
        }
    }

    /// 起動時に ocrText が未設定の画像に対してバックグラウンドで OCR をバックフィルする。
    private func backfillOCR() {
        let pending = historyStore.items.compactMap { item -> ImageMetadata? in
            guard case .image(let meta) = item.content, meta.ocrText == nil else { return nil }
            return meta
        }
        guard !pending.isEmpty else { return }
        let imageStore = self.imageStore
        let fileNames = pending.map(\.fileName)
        let imageURLs = fileNames.map { imageStore.imageURL(for: $0) }
        Task.detached {
            for (fileName, url) in zip(fileNames, imageURLs) {
                guard let text = await OCRService.recognizeText(from: url) else { continue }
                await MainActor.run { [weak self] in
                    self?.historyStore.updateOCRText(text, forImageFileName: fileName)
                }
            }
        }
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
