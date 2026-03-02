import AppKit

/// フォーカスを受け取らない NSTableView。
/// 検索フィールドに常にフォーカスを維持するために使用。
/// これにより、テーブルをクリックしてもフォーカスが移動せず、
/// キーボード操作が常に検索フィールド経由で処理される。
@MainActor
private final class NonFocusTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }

    /// Shift/Cmd+Click 時にクリックされた行を通知するコールバック。
    /// SearchWindow が orderedSelection を自前管理するために使用。
    var onMultiSelectClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Shift+Click / Cmd+Click → カスタムマルチセレクト処理
        if flags.contains(.shift) || flags.contains(.command) {
            let point = convert(event.locationInWindow, from: nil)
            let row = self.row(at: point)
            if row >= 0 { onMultiSelectClick?(row) }
            return
        }
        super.mouseDown(with: event)
    }
}

/// ポップアップ検索ウィンドウ。Cmd+Shift+V で表示される。
///
/// 構成:
/// ┌──────────────────────────┐
/// │ [tag×] 🔍 検索フィールド  │ ← タグフィルタ + fuzzy search
/// ├──────────────────────────┤
/// │ 履歴アイテム1             │ ← ↑↓キーで選択
/// │ ★ スニペット名            │ ← 2行表示（タグバッジ付き）
/// │   内容プレビュー...       │
/// │ ...                      │
/// ├──────────────────────────┤
/// │ ⏎ ペースト ⌘C コピー ... │ ← ショートカットヒント（動的）
/// └──────────────────────────┘
///
/// NSPanel を使用することで、他アプリの上にフローティング表示できる。
@MainActor
final class SearchWindow: NSPanel, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    // MARK: - 定数

    /// macOS の仮想キーコード
    private enum KeyCode {
        static let c: UInt16 = 8
        static let a: UInt16 = 0
        static let e: UInt16 = 14
        static let comma: UInt16 = 43
        static let space: UInt16 = 49
    }

    /// レイアウト定数。デザイン調整はここを変えるだけでOK。
    private enum Layout {
        static let windowSize = NSSize(width: 600, height: 420)
        static let cornerRadius: CGFloat = 12
        static let searchFontSize: CGFloat = 18
        static let cellFontSize: CGFloat = 13
        static let hintFontSize: CGFloat = 11
        static let rowHeight: CGFloat = 36
        static let snippetRowHeight: CGFloat = 56
        static let imageRowHeight: CGFloat = 80
        static let thumbSize: CGFloat = 64
        static let windowPadding: CGFloat = 12
        static let cellPadding: CGFloat = 16
        static let searchHeight: CGFloat = 36
        static let hintBarHeight: CGFloat = 28
        static let iconSize: CGFloat = 20
        static let sectionGap: CGFloat = 8
        static let iconInset: CGFloat = 4
        static let iconTextGap: CGFloat = 8
        static let badgeGap: CGFloat = 4
        static let badgeFontSize: CGFloat = 9
        static let badgeHPad: CGFloat = 5
        static let badgeVPad: CGFloat = 1.5
        static let badgeCornerRadius: CGFloat = 4
        static let selBadgeSize: CGFloat = 20
        static let selBadgeFontSize: CGFloat = 11
        static let selBadgeTrailing: CGFloat = 8
    }

    // MARK: - セル識別子

    private static let textCellID = NSUserInterfaceItemIdentifier("ClipCell")
    private static let snippetCellID = NSUserInterfaceItemIdentifier("SnippetCell")
    private static let imageCellID = NSUserInterfaceItemIdentifier("ImageClipCell")
    private static let fileCellID = NSUserInterfaceItemIdentifier("FileClipCell")

    // MARK: - プロパティ

    private let searchField = NSTextField()
    private let scrollView = NSScrollView()
    private let tableView = NonFocusTableView()
    private let hintLabel = NSTextField(labelWithString: "")
    private let suggestionLabel = NSTextField(labelWithString: "")

    /// タグフィルタバッジ（検索フィールド左に表示、複数対応）
    private var filterBadges: [TagBadge] = []
    /// 検索フィールドの leading constraint（フィルタバッジで動的調整）
    private var searchFieldLeading: NSLayoutConstraint!
    /// 検索アイコンの参照
    private var searchIcon: NSImageView!

    private var allClips: [ClipItem] = []
    private var allSnippets: [SnippetItem] = []
    private var filteredItems: [SearchResultItem] = []
    private var imageStore: ImageStore?
    private var fileStore: FileStore?
    private var quickLookPanel: QuickLookPanel?

    /// マルチセレクト: 選択された行インデックスを選択順に保持
    private var orderedSelection: [Int] = []
    /// ユーザーが明示的に Shift/Cmd+Click でマルチセレクトを開始したか
    private var isManualMultiSelect = false
    /// toggleMultiSelect 内で selectRowIndexes を呼ぶ際、delegate の二重更新を防ぐフラグ
    private var suppressSelectionChange = false
    /// マルチセレクト中のドラッグ操作を追跡（ドラッグ中はウィンドウを閉じない）
    private var isDragging = false
    /// D&D 用の一時ディレクトリ（元ファイル名でハードコピーを作成）
    private static let dragTempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("FuzzyPaste-drag", isDirectory: true)

    // タグフィルタ状態
    private var allTags: [String] = []
    private var activeTagFilters: [String] = []
    private var suggestedTag: String?

    /// ウィンドウを開く直前にアクティブだったアプリ。ペースト先として使用。
    private var previousApp: NSRunningApplication?
    /// Enter で選択 → ペースト実行（ClipItem ベース）
    var onPaste: ((ClipItem, NSRunningApplication?) -> Void)?
    /// マルチセレクト時のペースト（選択順の ClipItem 配列）
    var onMultiPaste: (([ClipItem], NSRunningApplication?) -> Void)?
    /// Cmd+C で選択 → クリップボードにコピーのみ（ClipItem ベース）
    var onCopy: ((ClipItem) -> Void)?
    /// Cmd+E でスニペット管理ウィンドウを開く
    var onOpenSnippetManager: (() -> Void)?
    /// Cmd+, で設定ウィンドウを開く
    var onOpenPreferences: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Layout.windowSize),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isMovableByWindowBackground = true
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // 角丸ウィンドウのために背景を透明にする
        isOpaque = false
        backgroundColor = .clear
        setupUI()
    }

    // MARK: - UI Setup

    private func setupUI() {
        // すりガラス効果の背景。Spotlight / Raycast 風のモダンな見た目。
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .sheet
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = Layout.cornerRadius
        visualEffect.layer?.masksToBounds = true
        contentView = visualEffect

        let searchContainer = setupSearchField(in: visualEffect)
        let separator = addSeparator(in: visualEffect, below: searchContainer)
        setupTableView(in: visualEffect, below: separator)
        setupHintBar(in: visualEffect)
    }

    private func setupSearchField(in container: NSView) -> NSView {
        let searchContainer = NSView()
        searchContainer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(searchContainer)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        icon.contentTintColor = .tertiaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        searchContainer.addSubview(icon)
        searchIcon = icon

        searchField.placeholderString = "検索..."
        searchField.font = .systemFont(ofSize: Layout.searchFontSize, weight: .light)
        searchField.focusRingType = .none
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchContainer.addSubview(searchField)

        // サジェストラベル（ゴーストテキスト）
        suggestionLabel.font = .systemFont(ofSize: Layout.searchFontSize, weight: .light)
        suggestionLabel.textColor = .tertiaryLabelColor
        suggestionLabel.isHidden = true
        suggestionLabel.translatesAutoresizingMaskIntoConstraints = false
        searchContainer.addSubview(suggestionLabel)

        searchFieldLeading = searchField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Layout.iconTextGap)

        NSLayoutConstraint.activate([
            searchContainer.topAnchor.constraint(equalTo: container.topAnchor, constant: Layout.sectionGap),
            searchContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Layout.windowPadding),
            searchContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Layout.windowPadding),
            searchContainer.heightAnchor.constraint(equalToConstant: Layout.searchHeight),

            icon.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: Layout.iconInset),
            icon.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Layout.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Layout.iconSize),

            searchFieldLeading,
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor),
            searchField.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),

            suggestionLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            suggestionLabel.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
        ])

        return searchContainer
    }

    private func addSeparator(in container: NSView, below anchor: NSView) -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: anchor.bottomAnchor, constant: Layout.sectionGap),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return separator
    }

    private func setupTableView(in container: NSView, below separator: NSBox) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ClipColumn"))
        column.title = ""
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = Layout.rowHeight
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = true
        tableView.doubleAction = #selector(tableDoubleClicked)
        tableView.target = self
        tableView.style = .plain
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.onMultiSelectClick = { [weak self] row in
            self?.toggleMultiSelect(row: row)
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }

    private func setupHintBar(in container: NSView) {
        let hintBar = NSView()
        hintBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hintBar)

        let hintSeparator = NSBox()
        hintSeparator.boxType = .separator
        hintSeparator.translatesAutoresizingMaskIntoConstraints = false
        hintBar.addSubview(hintSeparator)

        hintLabel.font = .systemFont(ofSize: Layout.hintFontSize)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintBar.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            scrollView.bottomAnchor.constraint(equalTo: hintBar.topAnchor),

            hintBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hintBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hintBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hintBar.heightAnchor.constraint(equalToConstant: Layout.hintBarHeight),

            hintSeparator.topAnchor.constraint(equalTo: hintBar.topAnchor),
            hintSeparator.leadingAnchor.constraint(equalTo: hintBar.leadingAnchor),
            hintSeparator.trailingAnchor.constraint(equalTo: hintBar.trailingAnchor),

            hintLabel.centerYAnchor.constraint(equalTo: hintBar.centerYAnchor),
            hintLabel.centerXAnchor.constraint(equalTo: hintBar.centerXAnchor),
        ])
    }

    private func updateHintLabel() {
        var parts: [String]
        if orderedSelection.count >= 2 {
            parts = ["⏎ or D&D \(orderedSelection.count)件ペースト"]
        } else {
            parts = ["⏎ ペースト", "⌘C コピー", "⌘Click 複数選択", "⇧Space プレビュー", "⌘E スニペット管理"]
        }
        if suggestedTag != nil {
            parts.insert("⇥ タグ絞り込み", at: 0)
        }
        if !activeTagFilters.isEmpty {
            parts.insert("⌫ フィルタ解除", at: 0)
        }
        hintLabel.stringValue = parts.joined(separator: "    ")
    }

    // MARK: - Show / Dismiss

    func show(clips: [ClipItem], snippets: [SnippetItem], imageStore: ImageStore, fileStore: FileStore, allTags: [String]) {
        // 前回のドラッグ用一時ファイルをクリーンアップ
        try? FileManager.default.removeItem(at: Self.dragTempDir)
        // ウィンドウを開く前にアクティブなアプリを記録（ペースト先として使う）
        previousApp = NSWorkspace.shared.frontmostApplication
        allClips = clips
        allSnippets = snippets
        self.imageStore = imageStore
        self.fileStore = fileStore
        self.allTags = allTags
        searchField.stringValue = ""
        activeTagFilters = []
        suggestedTag = nil
        suggestionLabel.isHidden = true
        removeAllFilterBadges()
        orderedSelection = []
        isManualMultiSelect = false
        isDragging = false
        filteredItems = FuzzyMatcher.filterMixed(query: "", clips: clips, snippets: snippets)
        tableView.reloadData()
        tableView.scrollRowToVisible(0)
        updateHintLabel()

        positionNearCursor()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        makeFirstResponder(searchField)

        // 先頭のアイテムを自動選択
        if !filteredItems.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            orderedSelection = [0]
        }
    }

    func dismiss() {
        dismissQuickLook()
        orderOut(nil)
        previousApp?.activate()
    }

    /// マウスカーソル付近にウィンドウを配置。画面からはみ出さないよう調整する。
    private func positionNearCursor() {
        let mouseLocation = NSEvent.mouseLocation
        let windowSize = frame.size

        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        var x = mouseLocation.x
        var y = mouseLocation.y

        // 画面端でクリッピング
        x = x.clamped(to: screenFrame.minX...(screenFrame.maxX - windowSize.width))
        // macOS の座標系は左下原点。ウィンドウ上端をカーソル位置に合わせる。
        y = (y - windowSize.height).clamped(to: screenFrame.minY...(screenFrame.maxY - windowSize.height))

        setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Window lifecycle

    /// ウィンドウからフォーカスが外れたら自動的に閉じる。
    /// 他のアプリをクリックしたり、別のウィンドウに切り替えた時に発火。
    /// ドラッグ中はウィンドウを閉じない。
    override func resignKey() {
        super.resignKey()
        if !isDragging { dismiss() }
    }

    // MARK: - Key handling

    /// performKeyEquivalent は AppKit のキーイベント処理で最初に呼ばれるため、
    /// テキストフィールドのデフォルト動作（Cmd+C でフィールド内テキストをコピー）
    /// より先に、アプリ独自のショートカットを処理できる。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd+C → 選択中のアイテムをクリップボードにコピー
        if event.keyCode == KeyCode.c && flags == .command {
            copyCurrentItem()
            return true
        }

        // Cmd+E → スニペット管理ウィンドウを開く
        // resignKey → dismiss で previousApp?.activate() が走らないよう先に nil にする
        if event.keyCode == KeyCode.e && flags == .command {
            previousApp = nil
            orderOut(nil)
            onOpenSnippetManager?()
            return true
        }

        // Cmd+, → 設定ウィンドウを開く
        if event.keyCode == KeyCode.comma && flags == .command {
            previousApp = nil
            orderOut(nil)
            onOpenPreferences?()
            return true
        }

        // Cmd+A → 検索フィールドの全選択
        if event.keyCode == KeyCode.a && flags == .command {
            if let editor = searchField.currentEditor() {
                editor.selectAll(nil)
                return true
            }
        }

        return super.performKeyEquivalent(with: event)
    }

    /// sendEvent をオーバーライドして Shift+Space を横取りする。
    /// performKeyEquivalent は Command 系以外の修飾キーだとテキストフィールドに負けるため、
    /// ここで keyDown イベントを直接フィルタする。
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown && event.keyCode == KeyCode.space
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift {
            toggleQuickLook()
            return
        }
        super.sendEvent(event)
    }

    // MARK: - Tag suggestion

    private func updateSuggestion() {
        let input = searchField.stringValue
        guard !input.isEmpty, !allTags.isEmpty else {
            suggestedTag = nil
            suggestionLabel.isHidden = true
            updateHintLabel()
            return
        }

        let lower = input.lowercased()
        // 既にフィルタ中のタグはサジェストから除外
        if let match = allTags.first(where: {
            $0.lowercased().hasPrefix(lower) && !activeTagFilters.contains($0)
        }) {
            suggestedTag = match
            suggestionLabel.stringValue = match
            suggestionLabel.isHidden = false
        } else {
            suggestedTag = nil
            suggestionLabel.isHidden = true
        }
        updateHintLabel()
    }

    // MARK: - Tag filter

    private func applyTagFilter(_ tag: String) {
        activeTagFilters.append(tag)
        suggestedTag = nil
        suggestionLabel.isHidden = true
        searchField.stringValue = ""
        refreshAfterFilterChange()
    }

    private func removeTagFilter(_ tag: String) {
        activeTagFilters.removeAll { $0 == tag }
        refreshAfterFilterChange()
    }

    private func clearLastTagFilter() {
        guard !activeTagFilters.isEmpty else { return }
        activeTagFilters.removeLast()
        refreshAfterFilterChange()
    }

    /// タグフィルタ変更後の共通リフレッシュ処理
    private func refreshAfterFilterChange() {
        rebuildFilterBadges()
        refilter()
        updateHintLabel()
    }

    private func rebuildFilterBadges() {
        removeAllFilterBadges()
        guard let container = searchField.superview else { return }

        var prevAnchor = searchIcon.trailingAnchor
        var prevGap = Layout.iconTextGap

        for tag in activeTagFilters {
            let badge = TagBadge(text: tag, showClose: true)
            let tagToRemove = tag
            badge.onRemove = { [weak self] in self?.removeTagFilter(tagToRemove) }
            container.addSubview(badge)

            NSLayoutConstraint.activate([
                badge.leadingAnchor.constraint(equalTo: prevAnchor, constant: prevGap),
                badge.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            ])
            filterBadges.append(badge)
            prevAnchor = badge.trailingAnchor
            prevGap = Layout.badgeGap
        }

        // 検索フィールドを最後のバッジの右に配置
        searchFieldLeading.isActive = false
        searchFieldLeading = searchField.leadingAnchor.constraint(equalTo: prevAnchor, constant: prevGap)
        searchFieldLeading.isActive = true
    }

    private func removeAllFilterBadges() {
        for badge in filterBadges { badge.removeFromSuperview() }
        filterBadges.removeAll()
        searchFieldLeading.isActive = false
        searchFieldLeading = searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: Layout.iconTextGap)
        searchFieldLeading.isActive = true
    }

    private func refilter() {
        let query = searchField.stringValue
        orderedSelection = []
        filteredItems = FuzzyMatcher.filterMixed(query: query, clips: allClips, snippets: allSnippets, tagFilters: activeTagFilters)
        tableView.reloadData()
        if !filteredItems.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
            orderedSelection = [0]
        }
    }

    // MARK: - NSTextFieldDelegate

    /// 検索フィールドの入力が変わるたびにfuzzy searchでフィルタリング
    func controlTextDidChange(_ obj: Notification) {
        refilter()
        updateSuggestion()
        updateQuickLookContent()
    }

    /// 検索フィールド内での特殊キー（Enter, Esc, ↑↓, Tab, Delete）を処理。
    /// true を返すと「処理済み」としてデフォルト動作を抑制する。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            selectCurrentItem()
            return true
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            dismiss()
            return true
        }
        if commandSelector == #selector(moveUp(_:)) {
            moveSelection(by: -1)
            return true
        }
        if commandSelector == #selector(moveDown(_:)) {
            moveSelection(by: 1)
            return true
        }
        // Tab: サジェストがあればタグフィルタ発動
        if commandSelector == #selector(insertTab(_:)) {
            if let tag = suggestedTag {
                applyTagFilter(tag)
                return true
            }
            return true // Tab の通常動作を抑制
        }
        // Backspace: 検索フィールドが空でフィルタ中なら最後のタグを解除
        if commandSelector == #selector(deleteBackward(_:)) {
            if searchField.stringValue.isEmpty && !activeTagFilters.isEmpty {
                clearLastTagFilter()
                return true
            }
        }
        return false
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredItems.count
    }

    // MARK: - Drag & Drop

    /// D&D: ドラッグ開始時にペーストボードにデータを書き込む。
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard row >= 0, row < filteredItems.count else { return nil }
        return pasteboardWriter(for: filteredItems[row])
    }

    /// D&D: ドラッグセッション開始時の処理。
    /// マルチセレクト時はペーストボードを選択順で書き直す。
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        isDragging = true
        guard orderedSelection.count >= 2 else { return }

        // マルチセレクト: 選択順に各アイテムを個別にペーストボードへ書き直す
        let writers = orderedSelection.compactMap { idx -> NSPasteboardWriting? in
            guard idx >= 0, idx < filteredItems.count else { return nil }
            return pasteboardWriter(for: filteredItems[idx])
        }
        let pasteboard = session.draggingPasteboard
        pasteboard.clearContents()
        pasteboard.writeObjects(writers)
    }

    /// D&D: ドラッグセッション終了時の処理。ウィンドウを閉じる。
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        dismiss()
    }

    // MARK: - NSTableViewDelegate

    /// 通常クリック / 自動選択で発火。単一選択にリセットする。
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionChange else { return }
        isManualMultiSelect = false
        let row = tableView.selectedRow
        if row >= 0 {
            orderedSelection = [row]
        } else {
            orderedSelection = []
        }
        updateSelectionBadges()
        updateHintLabel()
    }

    /// Shift/Cmd+Click: クリックされた行をマルチセレクトでトグルする。
    /// 自動選択されていたアイテムは含めず、明示的にクリックしたものだけカウント。
    private func toggleMultiSelect(row: Int) {
        if !isManualMultiSelect {
            // 初回: 通常選択状態をクリアしてマルチセレクト開始
            orderedSelection = [row]
            isManualMultiSelect = true
        } else if let idx = orderedSelection.firstIndex(of: row) {
            // マルチセレクト中に同じ行をクリック → トグル解除
            orderedSelection.remove(at: idx)
            if orderedSelection.isEmpty { isManualMultiSelect = false }
        } else {
            orderedSelection.append(row)
        }
        suppressSelectionChange = true
        tableView.selectRowIndexes(IndexSet(orderedSelection), byExtendingSelection: false)
        suppressSelectionChange = false
        updateSelectionBadges()
        updateHintLabel()
    }

    /// 可変行高: テキスト 36pt / スニペット 56pt / 画像・ファイル 80pt
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let item = filteredItems[row]
        switch item {
        case .clip(let clipItem):
            switch clipItem.content {
            case .image, .file: return Layout.imageRowHeight
            case .text: return Layout.rowHeight
            }
        case .snippet:
            return Layout.snippetRowHeight
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = filteredItems[row]

        let cellView: NSView
        switch item {
        case .clip(let clipItem):
            switch clipItem.content {
            case .text(let text):
                cellView = makeTextCell(tableView: tableView, text: text
                    .components(separatedBy: .newlines)
                    .joined(separator: " "))
            case .image(let meta):
                cellView = makeImageCell(tableView: tableView, meta: meta)
            case .file(let meta):
                cellView = makeFileCell(tableView: tableView, meta: meta)
            }
        case .snippet(let snippetItem):
            cellView = makeSnippetCell(tableView: tableView, snippet: snippetItem)
        }
        configureSelectionBadge(in: cellView, row: row)
        return cellView
    }

    // MARK: - Cell factories

    /// テキストアイテム用セル
    private func makeTextCell(tableView: NSTableView, text: String) -> NSTableCellView {
        let id = Self.textCellID
        if let existing = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            existing.textField?.stringValue = text
            // imageView を非表示に（再利用時のリセット）
            existing.imageView?.isHidden = true
            return existing
        }

        let view = NSTableCellView()
        view.identifier = id
        let tf = NSTextField(labelWithString: text)
        tf.lineBreakMode = .byTruncatingTail
        tf.font = .systemFont(ofSize: Layout.cellFontSize)
        tf.backgroundColor = .clear
        tf.drawsBackground = false
        tf.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tf)
        view.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Layout.cellPadding),
            tf.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Layout.cellPadding),
            tf.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return view
    }

    /// 画像アイテム用セル（2行レイアウト）:
    /// [thumb]  filename.png       ← 上段: 太字ファイル名（なければ空）
    ///          1920×1080  2.3 MB  ← 下段: メタデータ
    private func makeImageCell(tableView: NSTableView, meta: ImageMetadata) -> NSView {
        let id = Self.imageCellID
        let titleTag = 100
        let subtitleTag = 101

        let thumbView: NSImageView
        let titleLabel: NSTextField
        let subtitleLabel: NSTextField
        let cellView: NSTableCellView

        if let existing = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView,
           let existingThumb = existing.imageView,
           let existingTitle = existing.viewWithTag(titleTag) as? NSTextField,
           let existingSub = existing.viewWithTag(subtitleTag) as? NSTextField {
            thumbView = existingThumb
            titleLabel = existingTitle
            subtitleLabel = existingSub
            cellView = existing
        } else {
            cellView = NSTableCellView()
            cellView.identifier = id

            thumbView = NSImageView()
            thumbView.imageScaling = .scaleProportionallyUpOrDown
            thumbView.wantsLayer = true
            thumbView.layer?.cornerRadius = 4
            thumbView.layer?.masksToBounds = true
            thumbView.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(thumbView)
            cellView.imageView = thumbView

            titleLabel = NSTextField(labelWithString: "")
            titleLabel.tag = titleTag
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.font = .systemFont(ofSize: Layout.cellFontSize, weight: .semibold)
            titleLabel.backgroundColor = .clear
            titleLabel.drawsBackground = false
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(titleLabel)

            subtitleLabel = NSTextField(labelWithString: "")
            subtitleLabel.tag = subtitleTag
            subtitleLabel.lineBreakMode = .byTruncatingTail
            subtitleLabel.font = .systemFont(ofSize: Layout.cellFontSize - 1)
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.backgroundColor = .clear
            subtitleLabel.drawsBackground = false
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(subtitleLabel)

            let textLeading = thumbView.trailingAnchor.anchorWithOffset(to: titleLabel.leadingAnchor)
            NSLayoutConstraint.activate([
                thumbView.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: Layout.cellPadding),
                thumbView.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                thumbView.widthAnchor.constraint(equalToConstant: Layout.thumbSize),
                thumbView.heightAnchor.constraint(equalToConstant: Layout.thumbSize),

                textLeading.constraint(equalToConstant: 8),
                titleLabel.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -Layout.cellPadding),
                titleLabel.bottomAnchor.constraint(equalTo: cellView.centerYAnchor, constant: -1),

                subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
                subtitleLabel.topAnchor.constraint(equalTo: cellView.centerYAnchor, constant: 1),
            ])
        }

        // サムネイル設定
        thumbView.isHidden = false
        thumbView.image = imageStore?.thumbnail(for: meta.fileName)

        // 上段: ファイル名（なければ空文字）
        titleLabel.stringValue = meta.originalFileName ?? ""

        // 下段: メタデータ
        let sizeStr = formatFileSize(meta.fileSizeBytes)
        subtitleLabel.stringValue = "\(meta.pixelWidth)×\(meta.pixelHeight)  \(sizeStr)"

        return cellView
    }

    /// ファイルアイテム用セル（2行レイアウト）:
    /// [icon]  filename.pdf       <- 上段: 太字ファイル名
    ///         pdf  1.2 MB        <- 下段: 拡張子 + サイズ
    private func makeFileCell(tableView: NSTableView, meta: FileMetadata) -> NSView {
        let id = Self.fileCellID
        let titleTag = 300
        let subtitleTag = 301

        let iconView: NSImageView
        let titleLabel: NSTextField
        let subtitleLabel: NSTextField
        let cellView: NSTableCellView

        if let existing = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView,
           let existingIcon = existing.imageView,
           let existingTitle = existing.viewWithTag(titleTag) as? NSTextField,
           let existingSub = existing.viewWithTag(subtitleTag) as? NSTextField {
            iconView = existingIcon
            titleLabel = existingTitle
            subtitleLabel = existingSub
            cellView = existing
        } else {
            cellView = NSTableCellView()
            cellView.identifier = id

            iconView = NSImageView()
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(iconView)
            cellView.imageView = iconView

            titleLabel = NSTextField(labelWithString: "")
            titleLabel.tag = titleTag
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.font = .systemFont(ofSize: Layout.cellFontSize, weight: .semibold)
            titleLabel.backgroundColor = .clear
            titleLabel.drawsBackground = false
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(titleLabel)

            subtitleLabel = NSTextField(labelWithString: "")
            subtitleLabel.tag = subtitleTag
            subtitleLabel.lineBreakMode = .byTruncatingTail
            subtitleLabel.font = .systemFont(ofSize: Layout.cellFontSize - 1)
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.backgroundColor = .clear
            subtitleLabel.drawsBackground = false
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(subtitleLabel)

            let textLeading = iconView.trailingAnchor.anchorWithOffset(to: titleLabel.leadingAnchor)
            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: Layout.cellPadding),
                iconView.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: Layout.thumbSize),
                iconView.heightAnchor.constraint(equalToConstant: Layout.thumbSize),

                textLeading.constraint(equalToConstant: 8),
                titleLabel.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -Layout.cellPadding),
                titleLabel.bottomAnchor.constraint(equalTo: cellView.centerYAnchor, constant: -1),

                subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
                subtitleLabel.topAnchor.constraint(equalTo: cellView.centerYAnchor, constant: 1),
            ])
        }

        // アイコン設定
        iconView.isHidden = false
        iconView.image = fileStore?.icon(for: meta)

        // 上段: ファイル名
        titleLabel.stringValue = meta.originalFileName

        // 下段: 拡張子 + サイズ
        let sizeStr = formatFileSize(meta.fileSizeBytes)
        if meta.fileExtension.isEmpty {
            subtitleLabel.stringValue = sizeStr
        } else {
            subtitleLabel.stringValue = "\(meta.fileExtension.uppercased())  \(sizeStr)"
        }

        return cellView
    }

    /// スニペット用セル（2行レイアウト）:
    /// 上段: ★ タイトル [tag1] [tag2]
    /// 下段:   内容プレビュー...
    private func makeSnippetCell(tableView: NSTableView, snippet: SnippetItem) -> NSView {
        let id = Self.snippetCellID
        let topTag = 200  // セル内ラベル識別用
        let bottomTag = 201  // セル内ラベル識別用

        let topLabel: NSTextField
        let bottomLabel: NSTextField
        let cellView: NSView

        if let existing = tableView.makeView(withIdentifier: id, owner: nil),
           let existingTop = existing.viewWithTag(topTag) as? NSTextField,
           let existingBottom = existing.viewWithTag(bottomTag) as? NSTextField {
            topLabel = existingTop
            bottomLabel = existingBottom
            cellView = existing
        } else {
            cellView = NSView()
            cellView.identifier = id

            topLabel = NSTextField(labelWithString: "")
            topLabel.tag = topTag
            topLabel.lineBreakMode = .byTruncatingTail
            topLabel.backgroundColor = .clear
            topLabel.drawsBackground = false
            topLabel.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(topLabel)

            bottomLabel = NSTextField(labelWithString: "")
            bottomLabel.tag = bottomTag
            bottomLabel.lineBreakMode = .byTruncatingTail
            bottomLabel.font = .systemFont(ofSize: Layout.cellFontSize - 1)
            bottomLabel.textColor = .secondaryLabelColor
            bottomLabel.backgroundColor = .clear
            bottomLabel.drawsBackground = false
            bottomLabel.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(bottomLabel)

            NSLayoutConstraint.activate([
                topLabel.topAnchor.constraint(equalTo: cellView.topAnchor, constant: 8),
                topLabel.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: Layout.cellPadding),
                topLabel.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -Layout.cellPadding),

                bottomLabel.topAnchor.constraint(equalTo: topLabel.bottomAnchor, constant: 2),
                bottomLabel.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: Layout.cellPadding + 12),
                bottomLabel.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -Layout.cellPadding),
            ])
        }

        // 上段: ★ タイトル + タグバッジ
        let attrStr = NSMutableAttributedString()
        attrStr.append(NSAttributedString(string: "★ ", attributes: [
            .foregroundColor: NSColor.systemOrange.withAlphaComponent(0.7),
            .font: NSFont.systemFont(ofSize: Layout.cellFontSize),
        ]))
        attrStr.append(NSAttributedString(string: snippet.title, attributes: [
            .font: NSFont.systemFont(ofSize: Layout.cellFontSize, weight: .medium),
        ]))
        for tag in snippet.tags {
            attrStr.append(NSAttributedString(string: " "))
            attrStr.append(Self.tagBadgeAttachment(text: tag))
        }
        topLabel.attributedStringValue = attrStr

        // 下段: 内容プレビュー
        let preview = snippet.content
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        bottomLabel.stringValue = preview

        return cellView
    }

    /// タグのピル型バッジを NSTextAttachment として生成する。
    /// NSAttributedString にインラインで埋め込める画像を返す。
    private static func tagBadgeAttachment(text: String) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: Layout.badgeFontSize, weight: .medium)
        let textColor = NSColor.secondaryLabelColor
        let bgColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.2)

        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let badgeSize = NSSize(
            width: textSize.width + Layout.badgeHPad * 2,
            height: textSize.height + Layout.badgeVPad * 2
        )

        let image = NSImage(size: badgeSize, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: Layout.badgeCornerRadius, yRadius: Layout.badgeCornerRadius)
            bgColor.setFill()
            path.fill()
            let textRect = NSRect(x: Layout.badgeHPad, y: Layout.badgeVPad, width: textSize.width, height: textSize.height)
            (text as NSString).draw(in: textRect, withAttributes: attrs)
            return true
        }

        let attachment = NSTextAttachment()
        attachment.image = image
        // ベースラインを調整して文字と揃える
        let baselineOffset = (Layout.cellFontSize - badgeSize.height) / 2 - 1
        attachment.bounds = NSRect(x: 0, y: baselineOffset, width: badgeSize.width, height: badgeSize.height)
        return NSAttributedString(attachment: attachment)
    }

    // MARK: - Actions

    @objc private func tableDoubleClicked() {
        selectCurrentItem()
    }

    /// テーブルで選択中のアイテムを ClipItem として返す。
    /// スニペットの場合はテキストの ClipItem を生成して返す。
    private func selectedClipItem() -> ClipItem? {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredItems.count else { return nil }
        let item = filteredItems[row]
        switch item {
        case .clip(let clipItem):
            return clipItem
        case .snippet(let snippet):
            return ClipItem(text: snippet.content)
        }
    }

    /// Enter / ダブルクリック: 選択アイテムをペースト
    /// マルチセレクト時は選択順にテキストを結合してペーストする。
    private func selectCurrentItem() {
        let app = previousApp
        previousApp = nil

        if orderedSelection.count >= 2 {
            // マルチセレクト: 選択順に ClipItem を収集
            let items: [ClipItem] = orderedSelection.compactMap { idx in
                guard idx >= 0, idx < filteredItems.count else { return nil }
                switch filteredItems[idx] {
                case .clip(let clipItem): return clipItem
                case .snippet(let snippet): return ClipItem(text: snippet.content)
                }
            }
            guard !items.isEmpty else { return }
            dismiss()
            onMultiPaste?(items, app)
        } else {
            guard let clipItem = selectedClipItem() else { return }
            dismiss()
            onPaste?(clipItem, app)
        }
    }

    /// Cmd+C: 選択アイテムをクリップボードにコピー（ペーストはしない）
    private func copyCurrentItem() {
        guard let clipItem = selectedClipItem() else { return }
        dismiss()
        onCopy?(clipItem)
    }

    private func moveSelection(by delta: Int) {
        guard !filteredItems.isEmpty else { return }
        let baseRow = orderedSelection.last ?? tableView.selectedRow
        var newRow = baseRow + delta
        newRow = max(0, min(newRow, filteredItems.count - 1))
        orderedSelection = [newRow]
        tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
        tableView.scrollRowToVisible(newRow)
        updateQuickLookContent()
    }

    // MARK: - Quick Look

    /// Shift+Space で Quick Look パネルをトグルする。
    private func toggleQuickLook() {
        if let panel = quickLookPanel, panel.isVisible {
            dismissQuickLook()
        } else {
            showQuickLook()
        }
    }

    private func showQuickLook() {
        let panel = quickLookPanel ?? QuickLookPanel()
        quickLookPanel = panel
        setQuickLookContent(panel)
        panel.show(relativeTo: frame, pointingAt: selectedRowScreenRect())
        panel.finalizeTextLayout()
    }

    private func dismissQuickLook() {
        guard let panel = quickLookPanel, panel.isVisible else { return }
        panel.dismissAnimated()
    }

    /// 選択中のアイテムに応じて Quick Look パネルの表示内容と位置を更新する。
    private func updateQuickLookContent() {
        guard let panel = quickLookPanel, panel.isVisible else { return }
        setQuickLookContent(panel)
        panel.updatePosition(relativeTo: frame, pointingAt: selectedRowScreenRect())
        panel.finalizeTextLayout()
    }

    /// Quick Look パネルに表示する内容を設定する。
    /// マルチセレクト時は最後に選択したアイテムをプレビューする。
    private func setQuickLookContent(_ panel: QuickLookPanel) {
        let row = orderedSelection.last ?? tableView.selectedRow
        guard row >= 0, row < filteredItems.count else { return }

        let item = filteredItems[row]
        switch item {
        case .clip(let clipItem):
            switch clipItem.content {
            case .text(let text):
                panel.showText(text)
            case .image(let meta):
                if let store = imageStore,
                   let image = NSImage(contentsOf: store.imageURL(for: meta.fileName)) {
                    panel.showImage(image)
                } else if let thumb = imageStore?.thumbnail(for: meta.fileName) {
                    panel.showImage(thumb)
                }
            case .file(let meta):
                if let store = fileStore {
                    panel.showImage(store.icon(for: meta))
                }
            }
        case .snippet(let snippet):
            panel.showText(snippet.content)
        }
    }

    /// 選択中のテーブル行のスクリーン座標を返す。
    ///
    /// tableViewSelectionDidChange → scrollRowToVisible の順で処理されるため、
    /// この時点でクリップビューの bounds が未更新の場合がある。
    /// 行が可視範囲外にある場合は bounds を直接調整して正しい座標を得る。
    private func selectedRowScreenRect() -> NSRect {
        let row = tableView.selectedRow
        guard row >= 0 else { return .zero }
        let rowRect = tableView.rect(ofRow: row)
        ensureRowVisible(rowRect)
        let rowInWindow = tableView.convert(rowRect, to: nil)
        return convertToScreen(rowInWindow)
    }

    /// 行が可視範囲外にあればクリップビューの bounds を即座に調整する。
    private func ensureRowVisible(_ rowRect: NSRect) {
        guard let clipView = tableView.enclosingScrollView?.contentView else { return }
        var origin = clipView.bounds.origin
        let visibleMaxY = origin.y + clipView.bounds.height
        if rowRect.maxY > visibleMaxY {
            origin.y = rowRect.maxY - clipView.bounds.height
        } else if rowRect.minY < origin.y {
            origin.y = rowRect.minY
        }
        clipView.setBoundsOrigin(origin)
    }

    // MARK: - Selection badge

    private static let selBadgeTag = 999

    /// 選択順バッジの画像を生成する。円の中央に番号を描画。
    private func makeSelectionBadgeImage(number: Int) -> NSImage {
        let size = Layout.selBadgeSize
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: rect).fill()

            let text = "\(number)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: Layout.selBadgeFontSize, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let textSize = (text as NSString).size(withAttributes: attrs)
            let textRect = NSRect(
                x: (size - textSize.width) / 2,
                y: (size - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            (text as NSString).draw(in: textRect, withAttributes: attrs)
            return true
        }
    }

    /// セルに選択順バッジを配置する。既存のバッジがあれば再利用する。
    private func configureSelectionBadge(in cellView: NSView, row: Int) {
        let badge: NSImageView
        if let existing = cellView.viewWithTag(Self.selBadgeTag) as? NSImageView {
            badge = existing
        } else {
            badge = NSImageView()
            badge.tag = Self.selBadgeTag
            badge.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -Layout.selBadgeTrailing),
                badge.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                badge.widthAnchor.constraint(equalToConstant: Layout.selBadgeSize),
                badge.heightAnchor.constraint(equalToConstant: Layout.selBadgeSize),
            ])
        }

        if isManualMultiSelect, let order = orderedSelection.firstIndex(of: row) {
            badge.image = makeSelectionBadgeImage(number: order + 1)
            badge.isHidden = false
        } else {
            badge.isHidden = true
        }
    }

    /// 可視行のバッジだけを更新する（パフォーマンス考慮）
    private func updateSelectionBadges() {
        tableView.enumerateAvailableRowViews { rowView, row in
            for col in 0..<rowView.numberOfColumns {
                if let cellView = rowView.view(atColumn: col) as? NSView {
                    self.configureSelectionBadge(in: cellView, row: row)
                }
            }
        }
    }

    // MARK: - Helpers

    /// SearchResultItem を D&D 用の NSPasteboardWriting に変換する。
    private func pasteboardWriter(for item: SearchResultItem) -> NSPasteboardWriting? {
        switch item {
        case .clip(let clipItem):
            switch clipItem.content {
            case .text(let text):
                return text as NSString
            case .image(let meta):
                guard imageStore != nil else { return nil }
                return dragURL(for: meta) as NSURL
            case .file(let meta):
                guard fileStore != nil else { return nil }
                return dragFileURL(for: meta) as NSURL
            }
        case .snippet(let snippet):
            return snippet.content as NSString
        }
    }

    /// D&D 用の URL を返す。元ファイル名がある場合は一時ディレクトリに
    /// ハードコピーを作成して元のファイル名を保持する。
    /// コピーに失敗した場合は元の UUID ファイルにフォールバックする。
    private func dragURL(for meta: ImageMetadata) -> URL {
        guard let store = imageStore else { return URL(fileURLWithPath: "/") }
        let sourceURL = store.imageURL(for: meta.fileName)
        guard let originalName = meta.originalFileName else { return sourceURL }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Self.dragTempDir, withIntermediateDirectories: true)
            let copyURL = Self.dragTempDir.appendingPathComponent(originalName)
            try? fm.removeItem(at: copyURL)
            try fm.copyItem(at: sourceURL, to: copyURL)
            return copyURL
        } catch {
            NSLog("FuzzyPaste: dragURL copy failed: \(error)")
            return sourceURL
        }
    }

    /// D&D 用の URL を返す（ファイル用）。元ファイル名で一時コピーを作成。
    private func dragFileURL(for meta: FileMetadata) -> URL {
        guard let store = fileStore else { return URL(fileURLWithPath: "/") }
        let sourceURL = store.fileURL(for: meta.fileName)

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Self.dragTempDir, withIntermediateDirectories: true)
            let copyURL = Self.dragTempDir.appendingPathComponent(meta.originalFileName)
            try? fm.removeItem(at: copyURL)
            try fm.copyItem(at: sourceURL, to: copyURL)
            return copyURL
        } catch {
            NSLog("FuzzyPaste: dragFileURL copy failed: \(error)")
            return sourceURL
        }
    }

    /// ファイルサイズを人間が読みやすい形式にフォーマット。
    private func formatFileSize(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        }
        let mb = kb / 1024
        return String(format: "%.1f MB", mb)
    }
}

// MARK: - Comparable+Clamped

private extension Comparable {
    /// 値を指定範囲内にクランプする。positionNearCursor() で画面端の制限に使用。
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
