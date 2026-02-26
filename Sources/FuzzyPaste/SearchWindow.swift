import AppKit

/// フォーカスを受け取らない NSTableView。
/// 検索フィールドに常にフォーカスを維持するために使用。
/// これにより、テーブルをクリックしてもフォーカスが移動せず、
/// キーボード操作が常に検索フィールド経由で処理される。
@MainActor
private final class NonFocusTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}

/// ポップアップ検索ウィンドウ。Cmd+Shift+V で表示される。
///
/// 構成:
/// ┌──────────────────────────┐
/// │ 🔍 検索フィールド         │ ← fuzzy search 入力
/// ├──────────────────────────┤
/// │ 履歴アイテム1             │ ← ↑↓キーで選択
/// │ 履歴アイテム2             │
/// │ ...                      │
/// ├──────────────────────────┤
/// │ ⏎ Paste  ⌘C Copy  esc   │ ← ショートカットヒント
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
    }

    /// レイアウト定数。デザイン調整はここを変えるだけでOK。
    private enum Layout {
        static let windowSize = NSSize(width: 480, height: 360)
        static let cornerRadius: CGFloat = 12
        static let searchFontSize: CGFloat = 18
        static let cellFontSize: CGFloat = 13
        static let hintFontSize: CGFloat = 11
        static let rowHeight: CGFloat = 36
        static let windowPadding: CGFloat = 12
        static let cellPadding: CGFloat = 16
        static let searchHeight: CGFloat = 36
        static let hintBarHeight: CGFloat = 28
        static let iconSize: CGFloat = 20
        static let sectionGap: CGFloat = 8
        static let iconInset: CGFloat = 4
        static let iconTextGap: CGFloat = 8
    }

    // MARK: - プロパティ

    private let searchField = NSTextField()
    private let scrollView = NSScrollView()
    private let tableView = NonFocusTableView()

    private var allItems: [ClipItem] = []
    private var filteredItems: [ClipItem] = []
    /// ウィンドウを開く直前にアクティブだったアプリ。ペースト先として使用。
    private var previousApp: NSRunningApplication?
    /// Enter で選択 → ペースト実行
    var onPaste: ((String, NSRunningApplication?) -> Void)?
    /// Cmd+C で選択 → クリップボードにコピーのみ
    var onCopy: ((String) -> Void)?

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

        let searchIcon = NSImageView()
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = .tertiaryLabelColor
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchContainer.addSubview(searchIcon)

        searchField.placeholderString = "Type to search..."
        searchField.font = .systemFont(ofSize: Layout.searchFontSize, weight: .light)
        searchField.focusRingType = .none
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchContainer.addSubview(searchField)

        NSLayoutConstraint.activate([
            searchContainer.topAnchor.constraint(equalTo: container.topAnchor, constant: Layout.sectionGap),
            searchContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Layout.windowPadding),
            searchContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Layout.windowPadding),
            searchContainer.heightAnchor.constraint(equalToConstant: Layout.searchHeight),

            searchIcon.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: Layout.iconInset),
            searchIcon.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: Layout.iconSize),
            searchIcon.heightAnchor.constraint(equalToConstant: Layout.iconSize),

            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: Layout.iconTextGap),
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor),
            searchField.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
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
        tableView.doubleAction = #selector(tableDoubleClicked)
        tableView.target = self
        tableView.style = .plain

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

        let hintLabel = NSTextField(labelWithString: "⏎ Paste    ⌘C Copy    esc Close")
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

    // MARK: - Show / Dismiss

    func show(items: [ClipItem]) {
        // ウィンドウを開く前にアクティブなアプリを記録（ペースト先として使う）
        previousApp = NSWorkspace.shared.frontmostApplication
        allItems = items
        searchField.stringValue = ""
        filteredItems = items
        tableView.reloadData()

        positionNearCursor()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        makeFirstResponder(searchField)

        // 先頭のアイテムを自動選択
        if !filteredItems.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func dismiss() {
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
    override func resignKey() {
        super.resignKey()
        dismiss()
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

        // Cmd+A → 検索フィールドの全選択
        if event.keyCode == KeyCode.a && flags == .command {
            if let editor = searchField.currentEditor() {
                editor.selectAll(nil)
                return true
            }
        }

        return super.performKeyEquivalent(with: event)
    }

    // MARK: - NSTextFieldDelegate

    /// 検索フィールドの入力が変わるたびにfuzzy searchでフィルタリング
    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue
        filteredItems = FuzzyMatcher.filter(query: query, items: allItems)
        tableView.reloadData()
        if !filteredItems.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    /// 検索フィールド内での特殊キー（Enter, Esc, ↑↓）を処理。
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
        return false
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredItems.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ClipCell")
        let cellView: NSTableCellView

        // セルの再利用（NSTableView の標準パターン）
        if let existing = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            cellView = existing
        } else {
            let view = NSTableCellView()
            view.identifier = identifier
            let tf = NSTextField(labelWithString: "")
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
            cellView = view
        }

        // 改行を半角スペースに置換して1行表示
        let item = filteredItems[row]
        cellView.textField?.stringValue = item.text
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        return cellView
    }

    // MARK: - Actions

    @objc private func tableDoubleClicked() {
        selectCurrentItem()
    }

    /// テーブルで選択中のアイテムのテキストを返す。未選択なら nil。
    private func selectedText() -> String? {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredItems.count else { return nil }
        return filteredItems[row].text
    }

    /// Enter / ダブルクリック: 選択アイテムをペースト
    private func selectCurrentItem() {
        guard let text = selectedText() else { return }
        let app = previousApp
        // dismiss() 内の previousApp?.activate() で二重に activate されるのを防ぐ
        previousApp = nil
        dismiss()
        onPaste?(text, app)
    }

    /// Cmd+C: 選択アイテムをクリップボードにコピー（ペーストはしない）
    private func copyCurrentItem() {
        guard let text = selectedText() else { return }
        dismiss()
        onCopy?(text)
    }

    private func moveSelection(by delta: Int) {
        guard !filteredItems.isEmpty else { return }
        var newRow = tableView.selectedRow + delta
        newRow = max(0, min(newRow, filteredItems.count - 1))
        tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
        tableView.scrollRowToVisible(newRow)
    }
}

// MARK: - Comparable+Clamped

private extension Comparable {
    /// 値を指定範囲内にクランプする。positionNearCursor() で画面端の制限に使用。
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
