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
/// │ [thumb] filename.png     │ ← 画像アイテム（2行）
/// │         1920×1080 2.3MB  │
/// │ ...                      │
/// ├──────────────────────────┤
/// │ ⏎ ペースト ⌘C コピー ... │ ← ショートカットヒント
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
        static let space: UInt16 = 49
    }

    /// レイアウト定数。デザイン調整はここを変えるだけでOK。
    private enum Layout {
        static let windowSize = NSSize(width: 480, height: 360)
        static let cornerRadius: CGFloat = 12
        static let searchFontSize: CGFloat = 18
        static let cellFontSize: CGFloat = 13
        static let hintFontSize: CGFloat = 11
        static let rowHeight: CGFloat = 36
        static let imageRowHeight: CGFloat = 64
        static let thumbSize: CGFloat = 52
        static let windowPadding: CGFloat = 12
        static let cellPadding: CGFloat = 16
        static let searchHeight: CGFloat = 36
        static let hintBarHeight: CGFloat = 28
        static let iconSize: CGFloat = 20
        static let sectionGap: CGFloat = 8
        static let iconInset: CGFloat = 4
        static let iconTextGap: CGFloat = 8
    }

    // MARK: - セル識別子

    private static let textCellID = NSUserInterfaceItemIdentifier("ClipCell")
    private static let imageCellID = NSUserInterfaceItemIdentifier("ImageClipCell")

    // MARK: - プロパティ

    private let searchField = NSTextField()
    private let scrollView = NSScrollView()
    private let tableView = NonFocusTableView()

    private var allClips: [ClipItem] = []
    private var allSnippets: [SnippetItem] = []
    private var filteredItems: [SearchResultItem] = []
    private var imageStore: ImageStore?
    private var quickLookPanel: QuickLookPanel?
    /// ウィンドウを開く直前にアクティブだったアプリ。ペースト先として使用。
    private var previousApp: NSRunningApplication?
    /// Enter で選択 → ペースト実行（ClipItem ベース）
    var onPaste: ((ClipItem, NSRunningApplication?) -> Void)?
    /// Cmd+C で選択 → クリップボードにコピーのみ（ClipItem ベース）
    var onCopy: ((ClipItem) -> Void)?
    /// Cmd+E でスニペット管理ウィンドウを開く
    var onOpenSnippetManager: (() -> Void)?

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

        searchField.placeholderString = "検索..."
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

        let hintLabel = NSTextField(labelWithString: "⏎ ペースト    ⌘C コピー    ⇧Space プレビュー    ⌘E スニペット管理")
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

    func show(clips: [ClipItem], snippets: [SnippetItem], imageStore: ImageStore) {
        // ウィンドウを開く前にアクティブなアプリを記録（ペースト先として使う）
        previousApp = NSWorkspace.shared.frontmostApplication
        allClips = clips
        allSnippets = snippets
        self.imageStore = imageStore
        searchField.stringValue = ""
        filteredItems = FuzzyMatcher.filterMixed(query: "", clips: clips, snippets: snippets)
        tableView.reloadData()
        tableView.scrollRowToVisible(0)

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

        // Cmd+E → スニペット管理ウィンドウを開く
        // resignKey → dismiss で previousApp?.activate() が走らないよう先に nil にする
        if event.keyCode == KeyCode.e && flags == .command {
            previousApp = nil
            orderOut(nil)
            onOpenSnippetManager?()
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

    // MARK: - NSTextFieldDelegate

    /// 検索フィールドの入力が変わるたびにfuzzy searchでフィルタリング
    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue
        filteredItems = FuzzyMatcher.filterMixed(query: query, clips: allClips, snippets: allSnippets)
        tableView.reloadData()
        if !filteredItems.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
        updateQuickLookContent()
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

    /// Quick Look の更新は moveSelection / controlTextDidChange 等から
    /// スクロール確定後に明示的に行うため、ここでは何もしない。
    func tableViewSelectionDidChange(_ notification: Notification) {}

    /// 可変行高: テキスト 36pt / 画像 64pt
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let item = filteredItems[row]
        if case .clip(let clipItem) = item, case .image = clipItem.content {
            return Layout.imageRowHeight
        }
        return Layout.rowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = filteredItems[row]

        switch item {
        case .clip(let clipItem):
            switch clipItem.content {
            case .text(let text):
                return makeTextCell(tableView: tableView, text: text
                    .components(separatedBy: .newlines)
                    .joined(separator: " "))
            case .image(let meta):
                return makeImageCell(tableView: tableView, meta: meta)
            }
        case .snippet(let snippetItem):
            return makeSnippetCell(tableView: tableView, snippet: snippetItem)
        }
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

    /// スニペット用セル
    private func makeSnippetCell(tableView: NSTableView, snippet: SnippetItem) -> NSTableCellView {
        let id = Self.textCellID
        let cellView: NSTableCellView
        if let existing = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cellView = existing
            cellView.imageView?.isHidden = true
        } else {
            cellView = NSTableCellView()
            cellView.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingTail
            tf.font = .systemFont(ofSize: Layout.cellFontSize)
            tf.backgroundColor = .clear
            tf.drawsBackground = false
            tf.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(tf)
            cellView.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: Layout.cellPadding),
                tf.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -Layout.cellPadding),
                tf.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        }

        let attrStr = NSMutableAttributedString()
        attrStr.append(NSAttributedString(string: "★ ", attributes: [
            .foregroundColor: NSColor.systemOrange.withAlphaComponent(0.7),
            .font: NSFont.systemFont(ofSize: Layout.cellFontSize),
        ]))
        attrStr.append(NSAttributedString(string: snippet.title, attributes: [
            .font: NSFont.systemFont(ofSize: Layout.cellFontSize, weight: .medium),
        ]))
        let preview = snippet.content
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        attrStr.append(NSAttributedString(string: "  \(preview)", attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: Layout.cellFontSize - 1),
        ]))
        cellView.textField?.attributedStringValue = attrStr
        return cellView
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
    private func selectCurrentItem() {
        guard let clipItem = selectedClipItem() else { return }
        let app = previousApp
        // dismiss() 内の previousApp?.activate() で二重に activate されるのを防ぐ
        previousApp = nil
        dismiss()
        onPaste?(clipItem, app)
    }

    /// Cmd+C: 選択アイテムをクリップボードにコピー（ペーストはしない）
    private func copyCurrentItem() {
        guard let clipItem = selectedClipItem() else { return }
        dismiss()
        onCopy?(clipItem)
    }

    private func moveSelection(by delta: Int) {
        guard !filteredItems.isEmpty else { return }
        var newRow = tableView.selectedRow + delta
        newRow = max(0, min(newRow, filteredItems.count - 1))
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
    private func setQuickLookContent(_ panel: QuickLookPanel) {
        let row = tableView.selectedRow
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

    // MARK: - Helpers

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
