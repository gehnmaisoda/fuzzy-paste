import AppKit
import FuzzyPasteCore

// MARK: - カスタム行ビュー（角丸セレクション + ホバーエフェクト）

@MainActor
private final class ModernRowView: NSTableRowView {
    private static let selectionRadius: CGFloat = 6
    private static let selectionInsetH: CGFloat = 6
    private static let hoverAlpha: CGFloat = 0.07
    private static let selectionAlpha: CGFloat = 0.15
    private static let separatorInset: CGFloat = 16

    var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }

    /// 最終行の場合 true。セパレーターを描画しない。
    var isLastRow = false

    override func drawSelection(in dirtyRect: NSRect) {
        // selectionHighlightStyle = .none のため呼ばれないが念のため空にする
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isSelected {
            let insetRect = bounds.insetBy(dx: Self.selectionInsetH, dy: 1)
            let path = NSBezierPath(roundedRect: insetRect,
                                    xRadius: Self.selectionRadius,
                                    yRadius: Self.selectionRadius)
            NSColor.controlAccentColor.withAlphaComponent(Self.selectionAlpha).setFill()
            path.fill()
        } else if isHovered {
            let insetRect = bounds.insetBy(dx: Self.selectionInsetH, dy: 1)
            let path = NSBezierPath(roundedRect: insetRect,
                                    xRadius: Self.selectionRadius,
                                    yRadius: Self.selectionRadius)
            NSColor.labelColor.withAlphaComponent(Self.hoverAlpha).setFill()
            path.fill()
        }

        // ピクセル境界にスナップしたセパレーターを描画
        guard !isLastRow else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        let lineHeight = 1.0 / scale
        let rawY = bounds.maxY - lineHeight
        let snappedY = round(rawY * scale) / scale
        NSColor.separatorColor.withAlphaComponent(0.4).setFill()
        NSRect(x: Self.separatorInset, y: snappedY,
               width: bounds.width - Self.separatorInset * 2, height: lineHeight).fill()
    }

    override func drawSeparator(in dirtyRect: NSRect) {}
}

// MARK: - フォーカスを受け取らない NSTableView

/// 検索フィールドに常にフォーカスを維持するために使用。
/// これにより、テーブルをクリックしてもフォーカスが移動せず、
/// キーボード操作が常に検索フィールド経由で処理される。
@MainActor
private final class NonFocusTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }

    /// Shift/Cmd+Click 時にクリックされた行を通知するコールバック。
    /// SearchWindow が orderedSelection を自前管理するために使用。
    var onMultiSelectClick: ((Int) -> Void)?

    private var hoveredRow: Int = -1
    private var hoverTrackingArea: NSTrackingArea?

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

    // MARK: - ホバートラッキング

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTrackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row != hoveredRow else { return }
        if hoveredRow >= 0,
           let oldRow = rowView(atRow: hoveredRow, makeIfNecessary: false) as? ModernRowView {
            oldRow.isHovered = false
        }
        hoveredRow = row
        if row >= 0,
           let newRow = rowView(atRow: row, makeIfNecessary: false) as? ModernRowView {
            newRow.isHovered = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    /// ホバー状態をリセットする。データ再読み込み時にも呼ばれる。
    func clearHover() {
        if hoveredRow >= 0,
           let oldRow = rowView(atRow: hoveredRow, makeIfNecessary: false) as? ModernRowView {
            oldRow.isHovered = false
        }
        hoveredRow = -1
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

    /// ウィンドウ開閉アニメーションの定数
    private enum Anim {
        static let showDuration: CFTimeInterval = 0.15
        static let dismissDuration: CFTimeInterval = 0.1
        static let showScale: CGFloat = 0.90
        static let dismissScale: CGFloat = 0.95
    }

    /// レイアウト定数。プリセットにより値が変わる。
    private let layout: LayoutConfig

    // MARK: - セル識別子・タグ

    private static let textCellID = NSUserInterfaceItemIdentifier("ClipCell")
    private static let snippetCellID = NSUserInterfaceItemIdentifier("SnippetCell")
    private static let imageCellID = NSUserInterfaceItemIdentifier("ImageClipCell")
    private static let fileCellID = NSUserInterfaceItemIdentifier("FileClipCell")

    private static let imageTitleTag = 100
    private static let imageSubtitleTag = 101
    private static let fileTitleTag = 300
    private static let fileSubtitleTag = 301

    // MARK: - プロパティ

    private let searchField = NSTextField()
    private let scrollView = NSScrollView()
    private let tableView = NonFocusTableView()
    private let hintStackView = NSStackView()
    private let suggestionLabel = NSTextField(labelWithString: "")

    /// タグフィルタバッジ（検索フィールド左に表示、複数対応）
    private var filterBadges: [TagBadge] = []
    /// 検索フィールドの leading constraint（フィルタバッジで動的調整）
    private var searchFieldLeading: NSLayoutConstraint!
    /// 検索アイコンの参照
    private var searchIcon: NSImageView!

    private let emptyStateView = NSView()
    private let welcomeView = NSView()

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
    /// dismiss アニメーション中の連打ガード
    private var isDismissing = false
    /// D&D 用の一時ディレクトリ（元ファイル名でハードコピーを作成）
    private static let dragTempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("FuzzyPaste-drag", isDirectory: true)

    // タグフィルタ状態
    private var allTags: [String] = []
    private var activeTagFilters: [String] = []
    private var suggestedTag: String?

    /// ウィンドウを開く直前にアクティブだったアプリ。ペースト先として使用。
    private(set) var previousApp: NSRunningApplication?
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
    /// 動的スニペット（プレースホルダー付き）選択時のコールバック
    var onDynamicSnippetPaste: ((SnippetItem, NSRunningApplication?) -> Void)?

    init(layout: LayoutConfig = .preset(.medium)) {
        self.layout = layout
        super.init(
            contentRect: NSRect(origin: .zero, size: layout.windowSize),
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
        visualEffect.layer?.cornerRadius = layout.cornerRadius
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 0.5
        visualEffect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
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
        icon.contentTintColor = .controlAccentColor.withAlphaComponent(0.6)
        icon.translatesAutoresizingMaskIntoConstraints = false
        searchContainer.addSubview(icon)
        searchIcon = icon

        searchField.placeholderString = "検索..."
        searchField.font = .systemFont(ofSize: layout.searchFontSize, weight: .light)
        searchField.focusRingType = .none
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchContainer.addSubview(searchField)

        // サジェストラベル（ゴーストテキスト）
        suggestionLabel.font = .systemFont(ofSize: layout.searchFontSize, weight: .light)
        suggestionLabel.textColor = .tertiaryLabelColor
        suggestionLabel.isHidden = true
        suggestionLabel.translatesAutoresizingMaskIntoConstraints = false
        searchContainer.addSubview(suggestionLabel)

        searchFieldLeading = searchField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: layout.iconTextGap)

        NSLayoutConstraint.activate([
            searchContainer.topAnchor.constraint(equalTo: container.topAnchor, constant: layout.sectionGap),
            searchContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: layout.windowPadding),
            searchContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -layout.windowPadding),
            searchContainer.heightAnchor.constraint(equalToConstant: layout.searchHeight),

            icon.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: layout.iconInset),
            icon.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: layout.iconSize),
            icon.heightAnchor.constraint(equalToConstant: layout.iconSize),

            searchFieldLeading,
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor),
            searchField.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),

            suggestionLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            suggestionLabel.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
        ])

        return searchContainer
    }

    /// 0.5pt の薄いディバイダビューを生成する。
    private func makeDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return divider
    }

    private func addSeparator(in container: NSView, below anchor: NSView) -> NSView {
        let divider = makeDivider()
        container.addSubview(divider)

        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: anchor.bottomAnchor, constant: layout.sectionGap),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: layout.windowPadding),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -layout.windowPadding),
        ])
        return divider
    }

    private func setupTableView(in container: NSView, below separator: NSView) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ClipColumn"))
        column.title = ""
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = layout.rowHeight
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .none
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

        // 空状態ビュー
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.isHidden = true
        container.addSubview(emptyStateView)

        let emptyIcon = NSImageView()
        emptyIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.addSubview(emptyIcon)

        let emptyLabel = NSTextField(labelWithString: "一致する項目がありません")
        emptyLabel.font = .systemFont(ofSize: layout.cellFontSize)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            emptyStateView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            emptyIcon.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            emptyIcon.topAnchor.constraint(equalTo: emptyStateView.topAnchor),
            emptyIcon.widthAnchor.constraint(equalToConstant: 32),
            emptyIcon.heightAnchor.constraint(equalToConstant: 32),

            emptyLabel.topAnchor.constraint(equalTo: emptyIcon.bottomAnchor, constant: 8),
            emptyLabel.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            emptyLabel.bottomAnchor.constraint(equalTo: emptyStateView.bottomAnchor),
        ])

        // ウェルカムビュー（クリップ履歴ゼロ時の初回ガイド用）
        welcomeView.translatesAutoresizingMaskIntoConstraints = false
        welcomeView.isHidden = true
        container.addSubview(welcomeView)

        let welcomeIcon = NSImageView()
        welcomeIcon.image = NSImage(systemSymbolName: "clipboard.fill", accessibilityDescription: nil)
        welcomeIcon.contentTintColor = .controlAccentColor
        welcomeIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 32, weight: .light)
        welcomeIcon.translatesAutoresizingMaskIntoConstraints = false
        welcomeView.addSubview(welcomeIcon)

        let welcomeTitle = NSTextField(labelWithString: "ようこそ FuzzyPaste へ")
        welcomeTitle.font = .systemFont(ofSize: layout.cellFontSize + 2, weight: .semibold)
        welcomeTitle.textColor = .labelColor
        welcomeTitle.alignment = .center
        welcomeTitle.translatesAutoresizingMaskIntoConstraints = false
        welcomeView.addSubview(welcomeTitle)

        let welcomeSub = NSTextField(labelWithString: "テキストやファイルをコピーすると、ここからすぐ呼び出せます")
        welcomeSub.font = .systemFont(ofSize: layout.cellFontSize - 1)
        welcomeSub.textColor = .secondaryLabelColor
        welcomeSub.alignment = .center
        welcomeSub.translatesAutoresizingMaskIntoConstraints = false
        welcomeView.addSubview(welcomeSub)

        NSLayoutConstraint.activate([
            welcomeView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            welcomeView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            welcomeView.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -40),

            welcomeIcon.centerXAnchor.constraint(equalTo: welcomeView.centerXAnchor),
            welcomeIcon.topAnchor.constraint(equalTo: welcomeView.topAnchor),

            welcomeTitle.topAnchor.constraint(equalTo: welcomeIcon.bottomAnchor, constant: 10),
            welcomeTitle.centerXAnchor.constraint(equalTo: welcomeView.centerXAnchor),

            welcomeSub.topAnchor.constraint(equalTo: welcomeTitle.bottomAnchor, constant: 4),
            welcomeSub.centerXAnchor.constraint(equalTo: welcomeView.centerXAnchor),
            welcomeSub.bottomAnchor.constraint(equalTo: welcomeView.bottomAnchor),
        ])
    }

    private func setupHintBar(in container: NSView) {
        let hintBar = NSView()
        hintBar.wantsLayer = true
        hintBar.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.03).cgColor
        hintBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hintBar)

        let divider = makeDivider()
        hintBar.addSubview(divider)

        hintStackView.orientation = .horizontal
        hintStackView.spacing = 12
        hintStackView.alignment = .centerY
        hintStackView.translatesAutoresizingMaskIntoConstraints = false
        hintBar.addSubview(hintStackView)

        NSLayoutConstraint.activate([
            scrollView.bottomAnchor.constraint(equalTo: hintBar.topAnchor),

            hintBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hintBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hintBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hintBar.heightAnchor.constraint(equalToConstant: layout.hintBarHeight),

            divider.topAnchor.constraint(equalTo: hintBar.topAnchor),
            divider.leadingAnchor.constraint(equalTo: hintBar.leadingAnchor, constant: layout.windowPadding),
            divider.trailingAnchor.constraint(equalTo: hintBar.trailingAnchor, constant: -layout.windowPadding),

            hintStackView.centerXAnchor.constraint(equalTo: hintBar.centerXAnchor),
            hintStackView.centerYAnchor.constraint(equalTo: hintBar.centerYAnchor),
        ])
    }

    private func updateHintLabel() {
        hintStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        var actions: [(key: String, label: String)]

        if orderedSelection.count >= 2 {
            actions = [("⏎", "\(orderedSelection.count)件ペースト")]
        } else {
            actions = [
                ("⏎", "ペースト"),
                ("⌘\u{2009}C", "コピー"),
                ("⌘\u{2009}E", "スニペット管理"),
                ("⇧\u{2009}Space", "プレビュー"),
                ("⌘\u{2009}Click", "複数選択"),
            ]
        }
        if suggestedTag != nil {
            actions.insert(("⇥", "タグ絞り込み"), at: 0)
        }
        if !activeTagFilters.isEmpty {
            actions.insert(("⌫", "フィルタ解除"), at: 0)
        }

        for action in actions {
            hintStackView.addArrangedSubview(makeActionChip(keycap: action.key, label: action.label))
        }
    }

    /// キーキャップ + ラベルのアクションチップを生成。
    private func makeActionChip(keycap: String, label: String) -> NSView {
        let chip = NSView()
        chip.translatesAutoresizingMaskIntoConstraints = false

        let key = makeKeycap(text: keycap)
        chip.addSubview(key)

        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: layout.hintFontSize)
        lbl.textColor = .tertiaryLabelColor
        lbl.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(lbl)

        NSLayoutConstraint.activate([
            key.leadingAnchor.constraint(equalTo: chip.leadingAnchor),
            key.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            lbl.leadingAnchor.constraint(equalTo: key.trailingAnchor, constant: 4),
            lbl.trailingAnchor.constraint(equalTo: chip.trailingAnchor),
            lbl.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            chip.heightAnchor.constraint(equalTo: key.heightAnchor),
        ])
        return chip
    }

    /// 角丸背景付きキーキャップビューを生成。
    private func makeKeycap(text: String) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 5
        container.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: layout.hintFontSize - 1, weight: .medium)
        label.textColor = .controlAccentColor.withAlphaComponent(0.7)
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])
        return container
    }

    // MARK: - Show / Dismiss

    /// 動的スニペットのキャンセル時に、元のペースト先アプリを復元する。
    func restorePreviousApp(_ app: NSRunningApplication?) {
        previousApp = app
    }

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
        isDismissing = false
        filteredItems = FuzzyMatcher.filterMixed(query: "", clips: clips, snippets: snippets)
        tableView.clearHover()
        tableView.reloadData()
        tableView.scrollRowToVisible(0)
        let showWelcome = filteredItems.isEmpty && clips.isEmpty
        emptyStateView.isHidden = true
        welcomeView.isHidden = !showWelcome
        scrollView.isHidden = showWelcome
        updateHintLabel()

        positionNearCursor()

        // アニメーション初期状態
        alphaValue = 0

        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        makeFirstResponder(searchField)

        // カーソル位置を起点にスケールアニメーション
        if let layer = contentView?.layer {
            let origin = cursorOriginInLayer(layer)
            let fromTransform = Self.scaleTransform(around: origin, scale: Anim.showScale)

            layer.transform = fromTransform
            let anim = CABasicAnimation(keyPath: "transform")
            anim.fromValue = fromTransform
            anim.toValue = CATransform3DIdentity
            anim.duration = Anim.showDuration
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            anim.isRemovedOnCompletion = true
            layer.transform = CATransform3DIdentity
            layer.add(anim, forKey: "showScale")
        }

        // フェードイン
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Anim.showDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }

        // 先頭のアイテムを自動選択
        if !filteredItems.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            orderedSelection = [0]
        }
    }

    func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        dismissQuickLook()
        let app = previousApp
        previousApp = nil

        // カーソル位置を起点にスケールダウン + フェードアウト
        if let layer = contentView?.layer {
            let origin = cursorOriginInLayer(layer)
            let toTransform = Self.scaleTransform(around: origin, scale: Anim.dismissScale)

            let scaleAnim = CABasicAnimation(keyPath: "transform")
            scaleAnim.fromValue = CATransform3DIdentity
            scaleAnim.toValue = toTransform
            scaleAnim.duration = Anim.dismissDuration
            scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeIn)
            scaleAnim.fillMode = .forwards
            scaleAnim.isRemovedOnCompletion = false
            layer.add(scaleAnim, forKey: "dismissScale")
        }

        // アニメーション完了前に元アプリをアクティブ化して、
        // macOS が別ウィンドウ（スニペット管理等）を一瞬前面に出すのを防ぐ
        app?.activate()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Anim.dismissDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.contentView?.layer?.removeAnimation(forKey: "dismissScale")
            self?.orderOut(nil)
            self?.alphaValue = 1
            self?.contentView?.layer?.transform = CATransform3DIdentity
            self?.isDismissing = false
        })
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

    /// カーソル位置をレイヤー座標系での起点として返す。
    private func cursorOriginInLayer(_ layer: CALayer) -> CGPoint {
        let mouseLocation = NSEvent.mouseLocation
        let windowFrame = frame
        let bounds = layer.bounds

        // カーソル位置をレイヤー内の座標に変換
        let relX = ((mouseLocation.x - windowFrame.minX) / windowFrame.width).clamped(to: 0...1)
        let relY = ((mouseLocation.y - windowFrame.minY) / windowFrame.height).clamped(to: 0...1)

        return CGPoint(x: relX * bounds.width, y: relY * bounds.height)
    }

    /// 指定した起点を中心にスケールする CATransform3D を生成。
    /// translate → scale → translate で anchorPoint を変えずに実現。
    /// Note: QuickLookPanel にも同一の実装あり（ファイル間依存を避けるため各クラスに配置）。
    private static func scaleTransform(around origin: CGPoint, scale: CGFloat) -> CATransform3D {
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, origin.x, origin.y, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        t = CATransform3DTranslate(t, -origin.x, -origin.y, 0)
        return t
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
        var prevGap = layout.iconTextGap

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
            prevGap = layout.badgeGap
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
        searchFieldLeading = searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: layout.iconTextGap)
        searchFieldLeading.isActive = true
    }

    private func refilter() {
        let query = searchField.stringValue
        orderedSelection = []
        filteredItems = FuzzyMatcher.filterMixed(query: query, clips: allClips, snippets: allSnippets, tagFilters: activeTagFilters)
        tableView.clearHover()
        tableView.reloadData()

        let isEmpty = filteredItems.isEmpty
        let isWelcome = isEmpty && allClips.isEmpty && searchField.stringValue.isEmpty && activeTagFilters.isEmpty
        welcomeView.isHidden = !isWelcome
        emptyStateView.isHidden = isWelcome || !isEmpty
        scrollView.isHidden = isEmpty

        if !isEmpty {
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
        // selectionHighlightStyle = .none では行ビューの再描画が自動で走らないため手動で促す
        tableView.enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
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

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("ModernRow")
        let rowView: ModernRowView
        if let existing = tableView.makeView(withIdentifier: id, owner: nil) as? ModernRowView {
            existing.isHovered = false
            rowView = existing
        } else {
            rowView = ModernRowView()
            rowView.identifier = id
        }
        rowView.isLastRow = (row == filteredItems.count - 1)
        return rowView
    }

    /// 可変行高: テキスト 36pt / スニペット 56pt / 画像・ファイル 80pt
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let item = filteredItems[row]
        switch item {
        case .clip(let clipItem):
            switch clipItem.content {
            case .image, .file: return layout.imageRowHeight
            case .text: return layout.rowHeight
            }
        case .snippet(let snippet):
            switch snippet.content {
            case .text: return layout.snippetRowHeight
            case .image, .file: return layout.imageRowHeight
            }
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
            switch snippetItem.content {
            case .text:
                cellView = makeSnippetCell(tableView: tableView, snippet: snippetItem)
            case .image(let meta):
                cellView = makeSnippetImageCell(tableView: tableView, snippet: snippetItem, meta: meta)
            case .file(let meta):
                cellView = makeSnippetFileCell(tableView: tableView, snippet: snippetItem, meta: meta)
            }
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
            return existing
        }

        let view = NSTableCellView()
        view.identifier = id

        let tf = NSTextField(labelWithString: text)
        tf.lineBreakMode = .byTruncatingTail
        tf.font = .systemFont(ofSize: layout.cellFontSize)
        tf.backgroundColor = .clear
        tf.drawsBackground = false
        tf.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tf)
        view.textField = tf

        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: layout.cellPadding),
            tf.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -layout.cellPadding),
            tf.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return view
    }

    /// 画像アイテム用セル（2行レイアウト）:
    /// filename.png              [thumb] ← 上段: 太字ファイル名、右端にサムネ
    /// 1920×1080  2.3 MB                 ← 下段: メタデータ
    private func makeImageCell(tableView: NSTableView, meta: ImageMetadata) -> NSView {
        let id = Self.imageCellID
        let titleTag = Self.imageTitleTag
        let subtitleTag = Self.imageSubtitleTag

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
            titleLabel.font = .systemFont(ofSize: layout.cellFontSize, weight: .semibold)
            titleLabel.backgroundColor = .clear
            titleLabel.drawsBackground = false
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(titleLabel)

            subtitleLabel = NSTextField(labelWithString: "")
            subtitleLabel.tag = subtitleTag
            subtitleLabel.lineBreakMode = .byTruncatingTail
            subtitleLabel.font = .systemFont(ofSize: layout.cellFontSize - 1)
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.backgroundColor = .clear
            subtitleLabel.drawsBackground = false
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(subtitleLabel)

            NSLayoutConstraint.activate([
                // サムネを右端に配置
                thumbView.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -layout.cellPadding),
                thumbView.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                thumbView.widthAnchor.constraint(equalToConstant: layout.thumbSize),
                thumbView.heightAnchor.constraint(equalToConstant: layout.thumbSize),

                titleLabel.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: layout.cellPadding),
                titleLabel.trailingAnchor.constraint(equalTo: thumbView.leadingAnchor, constant: -8),
                titleLabel.bottomAnchor.constraint(equalTo: cellView.centerYAnchor, constant: -1),

                subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                subtitleLabel.trailingAnchor.constraint(equalTo: thumbView.leadingAnchor, constant: -8),
                subtitleLabel.topAnchor.constraint(equalTo: cellView.centerYAnchor, constant: 1),
            ])
        }

        thumbView.isHidden = false
        thumbView.image = imageStore?.thumbnail(for: meta.fileName)
        titleLabel.stringValue = meta.originalFileName ?? ""

        let sizeStr = formatFileSize(meta.fileSizeBytes)
        subtitleLabel.stringValue = "\(meta.pixelWidth)×\(meta.pixelHeight)  \(sizeStr)"

        return cellView
    }

    /// ファイルアイテム用セル（2行レイアウト）:
    /// filename.pdf              [icon] ← 上段: 太字ファイル名、右端にアイコン
    /// PDF  1.2 MB                      ← 下段: 拡張子 + サイズ
    private func makeFileCell(tableView: NSTableView, meta: FileMetadata) -> NSView {
        let id = Self.fileCellID
        let titleTag = Self.fileTitleTag
        let subtitleTag = Self.fileSubtitleTag

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
            titleLabel.font = .systemFont(ofSize: layout.cellFontSize, weight: .semibold)
            titleLabel.backgroundColor = .clear
            titleLabel.drawsBackground = false
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(titleLabel)

            subtitleLabel = NSTextField(labelWithString: "")
            subtitleLabel.tag = subtitleTag
            subtitleLabel.lineBreakMode = .byTruncatingTail
            subtitleLabel.font = .systemFont(ofSize: layout.cellFontSize - 1)
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.backgroundColor = .clear
            subtitleLabel.drawsBackground = false
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(subtitleLabel)

            let iconSize = layout.thumbSize * 0.5
            NSLayoutConstraint.activate([
                // アイコンを右端に配置
                iconView.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -layout.cellPadding),
                iconView.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: iconSize),
                iconView.heightAnchor.constraint(equalToConstant: iconSize),

                titleLabel.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: layout.cellPadding),
                titleLabel.trailingAnchor.constraint(equalTo: iconView.leadingAnchor, constant: -8),
                titleLabel.bottomAnchor.constraint(equalTo: cellView.centerYAnchor, constant: -1),

                subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                subtitleLabel.trailingAnchor.constraint(equalTo: iconView.leadingAnchor, constant: -8),
                subtitleLabel.topAnchor.constraint(equalTo: cellView.centerYAnchor, constant: 1),
            ])
        }

        iconView.isHidden = false
        // PDF は1ページ目のサムネイルを表示（キャッシュ付き）
        if PDFViewerView.fileExtensions.contains(meta.fileExtension.lowercased()),
           let store = fileStore,
           let thumb = PDFViewerView.thumbnail(for: store.fileURL(for: meta.fileName), size: layout.thumbSize) {
            iconView.image = thumb
        } else {
            iconView.image = fileStore?.icon(for: meta)
        }
        titleLabel.stringValue = meta.originalFileName

        let sizeStr = formatFileSize(meta.fileSizeBytes)
        if meta.fileExtension.isEmpty {
            subtitleLabel.stringValue = sizeStr
        } else {
            subtitleLabel.stringValue = "\(meta.fileExtension.uppercased())  \(sizeStr)"
        }

        return cellView
    }

    /// スニペット画像セル: makeImageCell を再利用し、タイトルをスニペット名に差し替え
    private func makeSnippetImageCell(tableView: NSTableView, snippet: SnippetItem, meta: ImageMetadata) -> NSView {
        let cell = makeImageCell(tableView: tableView, meta: meta)
        if let titleLabel = cell.viewWithTag(Self.imageTitleTag) as? NSTextField {
            titleLabel.attributedStringValue = snippetTitleString(snippet)
        }
        return cell
    }

    /// スニペットファイルセル: makeFileCell を再利用し、タイトルをスニペット名に差し替え
    private func makeSnippetFileCell(tableView: NSTableView, snippet: SnippetItem, meta: FileMetadata) -> NSView {
        let cell = makeFileCell(tableView: tableView, meta: meta)
        if let titleLabel = cell.viewWithTag(Self.fileTitleTag) as? NSTextField {
            titleLabel.attributedStringValue = snippetTitleString(snippet)
        }
        return cell
    }

    /// スニペットのタイトル行用 AttributedString（★ + タイトル + 動的バッジ + タグバッジ）
    private func snippetTitleString(_ snippet: SnippetItem) -> NSAttributedString {
        let attrStr = NSMutableAttributedString()
        attrStr.append(NSAttributedString(string: "★ ", attributes: [
            .foregroundColor: NSColor.systemOrange.withAlphaComponent(0.7),
            .font: NSFont.systemFont(ofSize: layout.cellFontSize),
        ]))
        attrStr.append(NSAttributedString(string: snippet.title, attributes: [
            .font: NSFont.systemFont(ofSize: layout.cellFontSize, weight: .medium),
        ]))
        if let text = snippet.text, PlaceholderParser.hasDynamicPlaceholders(in: text) {
            attrStr.append(NSAttributedString(string: " "))
            attrStr.append(accentBadgeAttachment(text: "{ }"))
        }
        for tag in snippet.tags {
            attrStr.append(NSAttributedString(string: " "))
            attrStr.append(tagBadgeAttachment(text: tag))
        }
        return attrStr
    }

    /// スニペット用セル（2行レイアウト）:
    /// 上段: ★ タイトル [tag1] [tag2]
    /// 下段:   内容プレビュー...
    private func makeSnippetCell(tableView: NSTableView, snippet: SnippetItem) -> NSView {
        let id = Self.snippetCellID
        let topTag = 200
        let bottomTag = 201

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
            bottomLabel.font = .systemFont(ofSize: layout.cellFontSize - 1)
            bottomLabel.textColor = .secondaryLabelColor
            bottomLabel.backgroundColor = .clear
            bottomLabel.drawsBackground = false
            bottomLabel.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(bottomLabel)

            NSLayoutConstraint.activate([
                topLabel.topAnchor.constraint(equalTo: cellView.topAnchor, constant: 8),
                topLabel.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: layout.cellPadding),
                topLabel.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -layout.cellPadding),

                bottomLabel.topAnchor.constraint(equalTo: topLabel.bottomAnchor, constant: 2),
                bottomLabel.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: layout.cellPadding + 12),
                bottomLabel.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -layout.cellPadding),
            ])
        }

        topLabel.attributedStringValue = snippetTitleString(snippet)

        // 下段: 内容プレビュー
        let preview: String
        switch snippet.content {
        case .text(let text):
            preview = text.components(separatedBy: .newlines).joined(separator: " ")
        case .image(let meta):
            let name = meta.originalFileName ?? meta.fileName
            preview = "🖼 \(name)  \(meta.pixelWidth)×\(meta.pixelHeight)"
        case .file(let meta):
            preview = "📄 \(meta.originalFileName)"
        }
        bottomLabel.stringValue = preview

        return cellView
    }

    /// ピル型バッジを NSTextAttachment として生成する。
    /// NSAttributedString にインラインで埋め込める画像を返す。
    private func badgeAttachment(text: String, font: NSFont, textColor: NSColor, bgColor: NSColor) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let badgeSize = NSSize(
            width: textSize.width + layout.badgeHPad * 2,
            height: textSize.height + layout.badgeVPad * 2
        )

        let badgeCornerRadius = layout.badgeCornerRadius
        let badgeHPad = layout.badgeHPad
        let badgeVPad = layout.badgeVPad
        let image = NSImage(size: badgeSize, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: badgeCornerRadius, yRadius: badgeCornerRadius)
            bgColor.setFill()
            path.fill()
            let textRect = NSRect(x: badgeHPad, y: badgeVPad, width: textSize.width, height: textSize.height)
            (text as NSString).draw(in: textRect, withAttributes: attrs)
            return true
        }

        let attachment = NSTextAttachment()
        attachment.image = image
        // ベースラインを調整して文字と揃える
        let baselineOffset = (layout.cellFontSize - badgeSize.height) / 2 - 1
        attachment.bounds = NSRect(x: 0, y: baselineOffset, width: badgeSize.width, height: badgeSize.height)
        return NSAttributedString(attachment: attachment)
    }

    /// アクセントカラーのバッジ（動的スニペットの `{ }` 表示用）。
    private func accentBadgeAttachment(text: String) -> NSAttributedString {
        badgeAttachment(
            text: text,
            font: .systemFont(ofSize: layout.badgeFontSize, weight: .semibold),
            textColor: .controlAccentColor,
            bgColor: .controlAccentColor.withAlphaComponent(0.12)
        )
    }

    /// タグのピル型バッジ。
    private func tagBadgeAttachment(text: String) -> NSAttributedString {
        badgeAttachment(
            text: text,
            font: .systemFont(ofSize: layout.badgeFontSize, weight: .medium),
            textColor: .secondaryLabelColor,
            bgColor: .tertiaryLabelColor.withAlphaComponent(0.2)
        )
    }

    // MARK: - Actions

    @objc private func tableDoubleClicked() {
        selectCurrentItem()
    }

    /// テーブルで選択中のアイテムを ClipItem として返す。
    /// スニペットの場合はコンテンツ型に応じた ClipItem を生成して返す。
    private func selectedClipItem() -> ClipItem? {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredItems.count else { return nil }
        return clipItem(from: filteredItems[row])
    }

    /// SearchResultItem から ClipItem に変換する。
    private func clipItem(from item: SearchResultItem) -> ClipItem {
        switch item {
        case .clip(let clipItem):
            return clipItem
        case .snippet(let snippet):
            switch snippet.content {
            case .text(let text):
                return ClipItem(text: text)
            case .image(let meta):
                return ClipItem(imageMetadata: meta)
            case .file(let meta):
                return ClipItem(fileMetadata: meta)
            }
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
                return clipItem(from: filteredItems[idx])
            }
            guard !items.isEmpty else { return }
            dismiss()
            onMultiPaste?(items, app)
        } else {
            // 動的スニペット判定: テキストスニペットでプレースホルダー付きなら専用ダイアログへ
            let row = tableView.selectedRow
            if row >= 0, row < filteredItems.count,
               case .snippet(let snippet) = filteredItems[row],
               let text = snippet.text,
               PlaceholderParser.hasDynamicPlaceholders(in: text) {
                dismiss()
                onDynamicSnippetPaste?(snippet, app)
                return
            }
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
                showTextPreview(text, in: panel)
            case .image(let meta):
                if let store = imageStore,
                   let image = NSImage(contentsOf: store.imageURL(for: meta.fileName)) {
                    panel.showImage(image)
                } else if let thumb = imageStore?.thumbnail(for: meta.fileName) {
                    panel.showImage(thumb)
                }
            case .file(let meta):
                showFilePreview(meta, in: panel)
            }
        case .snippet(let snippet):
            switch snippet.content {
            case .text(let text):
                showTextPreview(text, in: panel)
            case .image(let meta):
                if let store = imageStore,
                   let image = NSImage(contentsOf: store.imageURL(for: meta.fileName)) {
                    panel.showImage(image)
                } else if let thumb = imageStore?.thumbnail(for: meta.fileName) {
                    panel.showImage(thumb)
                }
            case .file(let meta):
                showFilePreview(meta, in: panel)
            }
        }
    }

    /// テキストが CSV なら CSV ビューアー、それ以外はテキストとして表示する。
    private func showTextPreview(_ text: String, in panel: QuickLookPanel) {
        if let result = CSVParser.parseIfCSV(text) {
            panel.showCSV(result)
        } else {
            panel.showText(text)
        }
    }

    /// ファイルの種類に応じた専用ビューアーで表示する（CSV/PDF）。非対応ならアイコン表示。
    private func showFilePreview(_ meta: FileMetadata, in panel: QuickLookPanel) {
        guard let store = fileStore else { return }
        let ext = meta.fileExtension.lowercased()
        if CSVParser.fileExtensions.contains(ext),
           let text = try? String(contentsOf: store.fileURL(for: meta.fileName), encoding: .utf8),
           let result = CSVParser.parseIfCSV(text) {
            panel.showCSV(result)
        } else if PDFViewerView.fileExtensions.contains(ext) {
            panel.loadPDF(from: store.fileURL(for: meta.fileName))
        } else {
            panel.showFileIcon(store.icon(for: meta))
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
        let size = layout.selBadgeSize
        let selBadgeFontSize = layout.selBadgeFontSize
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: rect).fill()

            let text = "\(number)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: selBadgeFontSize, weight: .bold),
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
                badge.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -layout.selBadgeTrailing),
                badge.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                badge.widthAnchor.constraint(equalToConstant: layout.selBadgeSize),
                badge.heightAnchor.constraint(equalToConstant: layout.selBadgeSize),
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
            switch snippet.content {
            case .text(let text):
                return text as NSString
            case .image(let meta):
                guard imageStore != nil else { return nil }
                return dragURL(for: meta) as NSURL
            case .file(let meta):
                guard fileStore != nil else { return nil }
                return dragFileURL(for: meta) as NSURL
            }
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
