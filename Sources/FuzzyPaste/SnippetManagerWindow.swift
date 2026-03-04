import AppKit
import FuzzyPasteCore
import UniformTypeIdentifiers

/// スニペット一覧の行ビュー。角丸選択ハイライト + ホバーエフェクト。
/// レイヤーベースで描画し、drawSelection に依存しない。
@MainActor
private final class SnippetRowView: NSTableRowView {
    private static let radius: CGFloat = 6
    private static let insetH: CGFloat = 6
    private static let hoverAlpha: CGFloat = 0.07
    private static let selectionAlpha: CGFloat = 0.15

    private let highlightLayer = CALayer()
    private let separatorLayer = CALayer()

    var isHovered = false {
        didSet { if oldValue != isHovered { updateHighlight() } }
    }

    override var isSelected: Bool {
        didSet { if oldValue != isSelected { updateHighlight() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        highlightLayer.cornerRadius = Self.radius
        layer?.addSublayer(highlightLayer)
        separatorLayer.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        layer?.addSublayer(separatorLayer)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        highlightLayer.frame = bounds.insetBy(dx: Self.insetH, dy: 1)
        separatorLayer.frame = CGRect(x: Self.insetH + 12, y: bounds.maxY - 0.5,
                                      width: bounds.width - (Self.insetH + 12) * 2, height: 0.5)
    }

    private func updateHighlight() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isSelected {
            highlightLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(Self.selectionAlpha).cgColor
        } else if isHovered {
            highlightLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(Self.hoverAlpha).cgColor
        } else {
            highlightLayer.backgroundColor = nil
        }
        CATransaction.commit()
    }

    // システムのデフォルト描画を無効化
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
}

/// マウスホバーを追跡するテーブルビュー。
@MainActor
private final class HoverTrackingTableView: NSTableView {
    private var hoveredRow: Int = -1
    private var hoverTrackingArea: NSTrackingArea?

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
           let oldRow = rowView(atRow: hoveredRow, makeIfNecessary: false) as? SnippetRowView {
            oldRow.isHovered = false
        }
        hoveredRow = row
        if row >= 0,
           let newRow = rowView(atRow: row, makeIfNecessary: false) as? SnippetRowView {
            newRow.isHovered = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    func clearHover() {
        if hoveredRow >= 0,
           let oldRow = rowView(atRow: hoveredRow, makeIfNecessary: false) as? SnippetRowView {
            oldRow.isHovered = false
        }
        hoveredRow = -1
    }
}

/// クリックを透過するプレースホルダーラベル。
/// テキストビューの上に重ねてもクリックがテキストビューに到達する。
@MainActor
private final class PlaceholderLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// ドロップゾーンビュー。画像/ファイルのドラッグ&ドロップとファイル選択ボタンを持つ。
@MainActor
private final class DropZoneView: NSView {
    enum Kind { case image, file }

    private static let iconSize: CGFloat = 28
    private static let messageFontSize: CGFloat = 12
    private static let cornerRadius: CGFloat = 8

    var onFileSelected: ((URL) -> Void)?

    private let kind: Kind
    private let dashBorder = CAShapeLayer()
    private let iconView = NSImageView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let browseButton = NSButton()
    private var isDragOver = false {
        didSet { updateAppearance() }
    }

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        setupUI()
        registerDragTypes()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // 破線ボーダー
        dashBorder.fillColor = nil
        dashBorder.strokeColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        dashBorder.lineWidth = 1.5
        dashBorder.lineDashPattern = [6, 4]
        layer?.addSublayer(dashBorder)

        // アイコン
        let symbolName = kind == .image ? "photo.badge.plus" : "doc.badge.plus"
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        iconView.contentTintColor = .tertiaryLabelColor
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Self.iconSize, weight: .light)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        // メッセージ
        let msg = kind == .image ? "ここに画像をドラッグ&ドロップ" : "ここにファイルをドラッグ&ドロップ"
        messageLabel.stringValue = msg
        messageLabel.font = .systemFont(ofSize: Self.messageFontSize, weight: .regular)
        messageLabel.textColor = .tertiaryLabelColor
        messageLabel.alignment = .center
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageLabel)

        // 選択ボタン
        let buttonTitle = kind == .image ? "画像を選択…" : "ファイルを選択…"
        browseButton.title = buttonTitle
        browseButton.bezelStyle = .rounded
        browseButton.target = self
        browseButton.action = #selector(browseClicked)
        browseButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(browseButton)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -28),

            messageLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 8),
            messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),

            browseButton.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 10),
            browseButton.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }

    private func registerDragTypes() {
        registerForDraggedTypes([.fileURL])
    }

    override func layout() {
        super.layout()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        dashBorder.path = path.cgPath
        dashBorder.frame = bounds
    }

    private func updateAppearance() {
        if isDragOver {
            dashBorder.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.06).cgColor
        } else {
            dashBorder.strokeColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
            layer?.backgroundColor = nil
        }
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard hasValidFile(sender) else { return [] }
        isDragOver = true
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard hasValidFile(sender) else { return [] }
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        isDragOver = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isDragOver = false
        guard let url = fileURL(from: sender) else { return false }
        onFileSelected?(url)
        return true
    }

    private func hasValidFile(_ info: NSDraggingInfo) -> Bool {
        guard let url = fileURL(from: info) else { return false }
        if kind == .image {
            return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
        }
        return true
    }

    private func fileURL(from info: NSDraggingInfo) -> URL? {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ])?.first as? URL
    }

    // MARK: - ファイル選択

    @objc private func browseClicked() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        if kind == .image {
            openPanel.allowedContentTypes = [.image]
            openPanel.message = "スニペットに設定する画像を選択してください"
        } else {
            openPanel.message = "スニペットに設定するファイルを選択してください"
        }
        guard openPanel.runModal() == .OK, let url = openPanel.url else { return }
        onFileSelected?(url)
    }
}

/// NSBezierPath → CGPath 変換
private extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            let type = element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo: path.move(to: points[0])
            case .lineTo: path.addLine(to: points[0])
            case .curveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath: path.closeSubpath()
            case .cubicCurveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo: path.addQuadCurve(to: points[1], control: points[0])
            @unknown default: break
            }
        }
        return path
    }
}

/// スニペット管理ウィンドウ。
/// メニューバーの「スニペット管理...」から開く。
///
/// 2カラムレイアウト:
/// ┌────────────────────────────────────────────────────────────────┐
/// │  ★ スニペット管理                                              │
/// │  登録したスニペットは検索結果に表示されます                        │
/// │                                                                │
/// │  スニペット一覧             スニペット名                         │
/// │  ┌──────────────────┐      ┌────────────────────────────────┐  │
/// │  │ ★ メールテンプレ  │      │ メールテンプレート              │  │
/// │  │   user@exampl... │      └────────────────────────────────┘  │
/// │  ├──────────────────┤      内容                                │
/// │  │ ★ 住所           │      ┌────────────────────────────────┐  │
/// │  │   東京都渋谷区... │      │ user@example.com is my ...     │  │
/// │  ├──────────────────┤      │                                │  │
/// │  │ [＋ 追加]  [削除] │      └────────────────────────────────┘  │
/// │  └──────────────────┘                                          │
/// └────────────────────────────────────────────────────────────────┘
@MainActor
final class SnippetManagerWindow: NSWindow, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate {

    // MARK: - 定数

    private enum Layout {
        static let windowSize = NSSize(width: 840, height: 576)
        static let cornerRadius: CGFloat = 14
        static let padding: CGFloat = 24
        static let listWidth: CGFloat = 240
        static let headerFontSize: CGFloat = 20
        static let subtitleFontSize: CGFloat = 12
        static let cellTitleFontSize: CGFloat = 13
        static let cellPreviewFontSize: CGFloat = 11
        static let labelFontSize: CGFloat = 11
        static let fieldFontSize: CGFloat = 13
        static let spacing: CGFloat = 4
        static let sectionSpacing: CGFloat = 16
        static let rowHeight: CGFloat = 48
        static let fieldWrapperHeight: CGFloat = 30
        static let inputCornerRadius: CGFloat = 6
        static let typeSegmentWidth: CGFloat = 240
        static let inputBorderWidth: CGFloat = 0.5
        static let inputPadding: CGFloat = 8
        static let toolbarHeight: CGFloat = 28
    }

    private enum KeyCode {
        static let w: UInt16 = 13
        static let n: UInt16 = 45
        static let a: UInt16 = 0
        static let delete: UInt16 = 51
    }

    /// セル内の 2 つの NSTextField を識別するタグ
    private enum CellTag {
        static let title = 1
        static let preview = 2
        static let icon = 3
    }

    // MARK: - UI パーツ

    private let tableView = HoverTrackingTableView()
    private let tableScrollView = NSScrollView()
    private let emptyStateView = NSView()
    private let titleField = NSTextField()
    private let contentTextView = NSTextView(frame: .zero)
    private let contentScrollView = NSScrollView()
    private let contentPlaceholder = PlaceholderLabel(labelWithString: "内容を入力...")
    private let tagContainer = TagFlowContainer()
    private let addButton = NSButton(frame: .zero)
    private let removeButton = NSButton(frame: .zero)
    private let actionButton = NSButton(frame: .zero)

    // タイプセグメントコントロール
    private let typeSegment = NSSegmentedControl()

    // 画像/ファイルコンテンツ用コンテナ
    private let textContentContainer = NSView()
    private let imageContentContainer = NSView()
    private let fileContentContainer = NSView()
    private let imagePreviewView = NSImageView()
    private let imageInfoLabel = NSTextField(labelWithString: "")
    private let fileIconView = NSImageView()
    private let fileInfoLabel = NSTextField(labelWithString: "")

    // ドロップゾーン（画像/ファイル選択用）
    private let imageDropZone = DropZoneView(kind: .image)
    private let fileDropZone = DropZoneView(kind: .file)

    // MARK: - 状態

    private let store: SnippetStore
    private let imageStore: ImageStore
    private let fileStore: FileStore
    /// フィールド更新中のフラグ。変更通知の再帰を防ぐ。
    private var isUpdatingFields = false

    // MARK: - 初期化

    init(store: SnippetStore, imageStore: ImageStore, fileStore: FileStore) {
        self.store = store
        self.imageStore = imageStore
        self.fileStore = fileStore
        super.init(
            contentRect: NSRect(origin: .zero, size: Layout.windowSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        minSize = NSSize(width: 600, height: 380)
        setupUI()
    }

    // MARK: - UI 構築

    private func setupUI() {
        let bg = NSVisualEffectView()
        bg.material = .sheet
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = Layout.cornerRadius
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 0.5
        bg.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        contentView = bg

        let header = buildHeader(in: bg)

        // ── 2カラムレイアウト ──
        let leftPanel = NSView()
        leftPanel.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(leftPanel)

        let rightPanel = NSView()
        rightPanel.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(rightPanel)

        buildLeftPanel(in: leftPanel)
        buildRightPanel(in: rightPanel)

        NSLayoutConstraint.activate([
            leftPanel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Layout.sectionSpacing),
            leftPanel.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: Layout.padding),
            leftPanel.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -Layout.padding),
            leftPanel.widthAnchor.constraint(equalToConstant: Layout.listWidth),

            rightPanel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Layout.sectionSpacing),
            rightPanel.leadingAnchor.constraint(equalTo: leftPanel.trailingAnchor, constant: Layout.sectionSpacing),
            rightPanel.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -Layout.padding),
            rightPanel.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -Layout.padding),
        ])
    }

    // MARK: ヘッダー

    private func buildHeader(in container: NSView) -> NSView {
        let headerIcon = NSImageView()
        headerIcon.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)
        headerIcon.contentTintColor = .systemOrange
        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerIcon)

        let titleLabel = NSTextField(labelWithString: "スニペット管理")
        titleLabel.font = .systemFont(ofSize: Layout.headerFontSize, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        let subtitle = NSTextField(labelWithString: "登録したスニペットは検索結果に表示されます")
        subtitle.font = .systemFont(ofSize: Layout.subtitleFontSize, weight: .light)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subtitle)

        NSLayoutConstraint.activate([
            headerIcon.topAnchor.constraint(equalTo: container.topAnchor, constant: Layout.padding + 10),
            headerIcon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Layout.padding),
            headerIcon.widthAnchor.constraint(equalToConstant: 18),
            headerIcon.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.centerYAnchor.constraint(equalTo: headerIcon.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: headerIcon.trailingAnchor, constant: 6),

            subtitle.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Layout.padding),
        ])
        return subtitle
    }

    // MARK: 左パネル（リスト + ボタン）

    private func buildLeftPanel(in panel: NSView) {
        // ── セクションラベル（右パネルの「スニペット名」ラベルと Y を揃える） ──
        let listLabel = makeLabel("スニペット一覧")
        panel.addSubview(listLabel)

        // ── テーブルの角丸ラッパー（テーブル + セパレータ + ボタンを内包） ──
        let tableWrapper = NSView()
        tableWrapper.wantsLayer = true
        tableWrapper.layer?.cornerRadius = 8
        tableWrapper.layer?.borderWidth = Layout.inputBorderWidth
        tableWrapper.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        tableWrapper.layer?.masksToBounds = true
        tableWrapper.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(tableWrapper)

        // ── テーブル ──
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Col"))
        column.title = ""
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = Layout.rowHeight
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 2)

        tableScrollView.documentView = tableView
        tableScrollView.hasVerticalScroller = true
        tableScrollView.scrollerStyle = .overlay
        tableScrollView.drawsBackground = false
        tableScrollView.borderType = .noBorder
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
        tableWrapper.addSubview(tableScrollView)

        // ── セパレータ（テーブルとツールバーの境界） ──
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        tableWrapper.addSubview(separator)

        // ── ツールバー: [+] [−]          [⋯] （macOS 標準パターン） ──
        configureToolbarButton(addButton, symbol: "plus", toolTip: "追加 (⌘N)", action: #selector(addClicked))
        tableWrapper.addSubview(addButton)

        configureToolbarButton(removeButton, symbol: "minus", toolTip: "削除 (⌘⌫)", action: #selector(removeClicked))
        removeButton.isEnabled = false
        tableWrapper.addSubview(removeButton)

        configureToolbarButton(actionButton, symbol: "ellipsis.circle", toolTip: "インポート / エクスポート", action: #selector(actionClicked))
        tableWrapper.addSubview(actionButton)

        // ── 空状態メッセージ ──
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.isHidden = true
        panel.addSubview(emptyStateView)

        let emptyIcon = NSImageView()
        emptyIcon.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)
        emptyIcon.contentTintColor = NSColor.systemOrange.withAlphaComponent(0.25)
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 32, weight: .light)
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.addSubview(emptyIcon)

        let emptyTitle = NSTextField(labelWithString: "スニペットはまだありません")
        emptyTitle.font = .systemFont(ofSize: Layout.subtitleFontSize, weight: .light)
        emptyTitle.textColor = .tertiaryLabelColor
        emptyTitle.alignment = .center
        emptyTitle.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.addSubview(emptyTitle)

        let emptyHint = NSTextField(labelWithString: "＋ ボタンで登録")
        emptyHint.font = .systemFont(ofSize: Layout.labelFontSize)
        emptyHint.textColor = .tertiaryLabelColor
        emptyHint.alignment = .center
        emptyHint.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.addSubview(emptyHint)

        NSLayoutConstraint.activate([
            emptyIcon.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            emptyIcon.topAnchor.constraint(equalTo: emptyStateView.topAnchor),

            emptyTitle.topAnchor.constraint(equalTo: emptyIcon.bottomAnchor, constant: 8),
            emptyTitle.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),

            emptyHint.topAnchor.constraint(equalTo: emptyTitle.bottomAnchor, constant: 4),
            emptyHint.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            emptyHint.bottomAnchor.constraint(equalTo: emptyStateView.bottomAnchor),
        ])

        NSLayoutConstraint.activate([
            listLabel.topAnchor.constraint(equalTo: panel.topAnchor),
            listLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor),

            tableWrapper.topAnchor.constraint(equalTo: listLabel.bottomAnchor, constant: Layout.spacing),
            tableWrapper.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            tableWrapper.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            tableWrapper.bottomAnchor.constraint(equalTo: panel.bottomAnchor),

            tableScrollView.topAnchor.constraint(equalTo: tableWrapper.topAnchor),
            tableScrollView.leadingAnchor.constraint(equalTo: tableWrapper.leadingAnchor),
            tableScrollView.trailingAnchor.constraint(equalTo: tableWrapper.trailingAnchor),
            tableScrollView.bottomAnchor.constraint(equalTo: separator.topAnchor),

            separator.leadingAnchor.constraint(equalTo: tableWrapper.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: tableWrapper.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: addButton.topAnchor),

            // ツールバー: [+] [−]          [⚙]
            addButton.leadingAnchor.constraint(equalTo: tableWrapper.leadingAnchor, constant: 4),
            addButton.bottomAnchor.constraint(equalTo: tableWrapper.bottomAnchor),
            addButton.heightAnchor.constraint(equalToConstant: Layout.toolbarHeight),
            addButton.widthAnchor.constraint(equalToConstant: Layout.toolbarHeight),

            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor),
            removeButton.bottomAnchor.constraint(equalTo: tableWrapper.bottomAnchor),
            removeButton.heightAnchor.constraint(equalToConstant: Layout.toolbarHeight),
            removeButton.widthAnchor.constraint(equalToConstant: Layout.toolbarHeight),

            actionButton.trailingAnchor.constraint(equalTo: tableWrapper.trailingAnchor, constant: -4),
            actionButton.bottomAnchor.constraint(equalTo: tableWrapper.bottomAnchor),
            actionButton.heightAnchor.constraint(equalToConstant: Layout.toolbarHeight),
            actionButton.widthAnchor.constraint(equalToConstant: Layout.toolbarHeight),

            emptyStateView.centerXAnchor.constraint(equalTo: tableScrollView.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: tableScrollView.centerYAnchor),
        ])
    }

    // MARK: 右パネル（編集エリア）

    private func buildRightPanel(in panel: NSView) {
        // ── スニペット名 ──
        let titleLabel = makeLabel("スニペット名")
        panel.addSubview(titleLabel)

        let titleWrapper = makeStyledWrapper()
        panel.addSubview(titleWrapper)

        titleField.font = .systemFont(ofSize: Layout.fieldFontSize)
        titleField.placeholderString = "スニペット名を入力..."
        titleField.isEnabled = false
        titleField.delegate = self
        titleField.focusRingType = .none
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleWrapper.addSubview(titleField)

        // ── タグ ──
        let tagLabel = makeLabel("タグ")
        panel.addSubview(tagLabel)

        tagContainer.onTagsChanged = { [weak self] _ in
            guard let self, !self.isUpdatingFields else { return }
            self.saveCurrentEdits()
        }
        tagContainer.onTabOut = { [weak self] in
            guard let self else { return }
            self.makeFirstResponder(self.contentTextView)
        }
        tagContainer.onBackTabOut = { [weak self] in
            guard let self else { return }
            self.makeFirstResponder(self.titleField)
        }
        tagContainer.setContentHuggingPriority(.required, for: .vertical)
        tagContainer.setContentCompressionResistancePriority(.required, for: .vertical)
        panel.addSubview(tagContainer)

        // ── タイプ ──
        let typeLabel = makeLabel("タイプ")
        panel.addSubview(typeLabel)

        typeSegment.segmentCount = 3
        typeSegment.setLabel("テキスト", forSegment: 0)
        typeSegment.setLabel("画像", forSegment: 1)
        typeSegment.setLabel("ファイル", forSegment: 2)
        typeSegment.setImage(NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil), forSegment: 0)
        typeSegment.setImage(NSImage(systemSymbolName: "photo", accessibilityDescription: nil), forSegment: 1)
        typeSegment.setImage(NSImage(systemSymbolName: "doc", accessibilityDescription: nil), forSegment: 2)
        typeSegment.segmentStyle = .rounded
        typeSegment.segmentDistribution = .fillEqually
        typeSegment.controlSize = .large
        typeSegment.target = self
        typeSegment.action = #selector(typeSegmentChanged)
        typeSegment.isEnabled = false
        typeSegment.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(typeSegment)

        // ── 内容ラベル ──
        let contentLabel = makeLabel("内容")
        panel.addSubview(contentLabel)

        // ── テキストコンテンツコンテナ ──
        textContentContainer.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(textContentContainer)

        let contentWrapper = makeStyledWrapper()
        contentWrapper.layer?.masksToBounds = true
        textContentContainer.addSubview(contentWrapper)

        // プレースホルダー
        contentPlaceholder.font = .systemFont(ofSize: Layout.fieldFontSize)
        contentPlaceholder.textColor = .placeholderTextColor
        contentPlaceholder.isHidden = true
        contentPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        contentWrapper.addSubview(contentPlaceholder)

        contentTextView.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        contentTextView.font = .monospacedSystemFont(ofSize: Layout.fieldFontSize, weight: .regular)
        contentTextView.isRichText = false
        contentTextView.allowsUndo = true
        contentTextView.drawsBackground = false
        contentTextView.textContainerInset = NSSize(width: 4, height: 6)
        contentTextView.textContainer?.lineFragmentPadding = 4
        contentTextView.isAutomaticQuoteSubstitutionEnabled = false
        contentTextView.isAutomaticDashSubstitutionEnabled = false
        contentTextView.isVerticallyResizable = true
        contentTextView.isHorizontallyResizable = false
        contentTextView.autoresizingMask = [.width]
        contentTextView.textContainer?.widthTracksTextView = true
        contentTextView.textContainer?.containerSize = NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
        contentTextView.isEditable = false
        contentTextView.isSelectable = false
        contentTextView.delegate = self

        contentScrollView.documentView = contentTextView
        contentScrollView.hasVerticalScroller = true
        contentScrollView.scrollerStyle = .overlay
        contentScrollView.borderType = .noBorder
        contentScrollView.drawsBackground = false
        contentScrollView.translatesAutoresizingMaskIntoConstraints = false
        contentWrapper.addSubview(contentScrollView)

        // ── 画像コンテンツコンテナ ──
        imageContentContainer.translatesAutoresizingMaskIntoConstraints = false
        imageContentContainer.isHidden = true
        panel.addSubview(imageContentContainer)

        let imageWrapper = makeStyledWrapper()
        imageContentContainer.addSubview(imageWrapper)

        imagePreviewView.imageScaling = .scaleProportionallyDown
        imagePreviewView.translatesAutoresizingMaskIntoConstraints = false
        imageWrapper.addSubview(imagePreviewView)

        imageInfoLabel.font = .systemFont(ofSize: Layout.cellPreviewFontSize)
        imageInfoLabel.textColor = .secondaryLabelColor
        imageInfoLabel.lineBreakMode = .byTruncatingTail
        imageInfoLabel.translatesAutoresizingMaskIntoConstraints = false
        imageWrapper.addSubview(imageInfoLabel)

        // ドロップゾーン（画像）
        imageDropZone.onFileSelected = { [weak self] url in
            self?.handleDroppedFile(url, forType: .image)
        }
        imageContentContainer.addSubview(imageDropZone)

        // ── ファイルコンテンツコンテナ ──
        fileContentContainer.translatesAutoresizingMaskIntoConstraints = false
        fileContentContainer.isHidden = true
        panel.addSubview(fileContentContainer)

        let fileWrapper = makeStyledWrapper()
        fileContentContainer.addSubview(fileWrapper)

        fileIconView.imageScaling = .scaleProportionallyUpOrDown
        fileIconView.translatesAutoresizingMaskIntoConstraints = false
        fileWrapper.addSubview(fileIconView)

        fileInfoLabel.font = .systemFont(ofSize: Layout.cellPreviewFontSize)
        fileInfoLabel.textColor = .secondaryLabelColor
        fileInfoLabel.lineBreakMode = .byTruncatingTail
        fileInfoLabel.maximumNumberOfLines = 3
        fileInfoLabel.translatesAutoresizingMaskIntoConstraints = false
        fileWrapper.addSubview(fileInfoLabel)

        // ドロップゾーン（ファイル）
        fileDropZone.onFileSelected = { [weak self] url in
            self?.handleDroppedFile(url, forType: .file)
        }
        fileContentContainer.addSubview(fileDropZone)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: panel.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor),

            titleWrapper.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Layout.spacing),
            titleWrapper.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            titleWrapper.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            titleWrapper.heightAnchor.constraint(equalToConstant: Layout.fieldWrapperHeight),

            titleField.leadingAnchor.constraint(equalTo: titleWrapper.leadingAnchor, constant: Layout.inputPadding),
            titleField.trailingAnchor.constraint(equalTo: titleWrapper.trailingAnchor, constant: -Layout.inputPadding),
            titleField.centerYAnchor.constraint(equalTo: titleWrapper.centerYAnchor),

            tagLabel.topAnchor.constraint(equalTo: titleWrapper.bottomAnchor, constant: Layout.sectionSpacing),
            tagLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor),

            tagContainer.topAnchor.constraint(equalTo: tagLabel.bottomAnchor, constant: Layout.spacing),
            tagContainer.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            tagContainer.trailingAnchor.constraint(equalTo: panel.trailingAnchor),

            typeLabel.topAnchor.constraint(equalTo: tagContainer.bottomAnchor, constant: Layout.sectionSpacing),
            typeLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor),

            typeSegment.topAnchor.constraint(equalTo: typeLabel.bottomAnchor, constant: Layout.spacing),
            typeSegment.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            typeSegment.widthAnchor.constraint(equalToConstant: Layout.typeSegmentWidth),

            contentLabel.topAnchor.constraint(equalTo: typeSegment.bottomAnchor, constant: Layout.sectionSpacing),
            contentLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor),

            // テキストコンテンツコンテナ
            textContentContainer.topAnchor.constraint(equalTo: contentLabel.bottomAnchor, constant: Layout.spacing),
            textContentContainer.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            textContentContainer.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            textContentContainer.bottomAnchor.constraint(equalTo: panel.bottomAnchor),

            contentWrapper.topAnchor.constraint(equalTo: textContentContainer.topAnchor),
            contentWrapper.leadingAnchor.constraint(equalTo: textContentContainer.leadingAnchor),
            contentWrapper.trailingAnchor.constraint(equalTo: textContentContainer.trailingAnchor),
            contentWrapper.bottomAnchor.constraint(equalTo: textContentContainer.bottomAnchor),

            contentPlaceholder.topAnchor.constraint(equalTo: contentWrapper.topAnchor, constant: 8),
            contentPlaceholder.leadingAnchor.constraint(equalTo: contentWrapper.leadingAnchor, constant: 8),

            contentScrollView.topAnchor.constraint(equalTo: contentWrapper.topAnchor),
            contentScrollView.leadingAnchor.constraint(equalTo: contentWrapper.leadingAnchor),
            contentScrollView.trailingAnchor.constraint(equalTo: contentWrapper.trailingAnchor),
            contentScrollView.bottomAnchor.constraint(equalTo: contentWrapper.bottomAnchor),

            // 画像コンテンツコンテナ
            imageContentContainer.topAnchor.constraint(equalTo: contentLabel.bottomAnchor, constant: Layout.spacing),
            imageContentContainer.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            imageContentContainer.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            imageContentContainer.bottomAnchor.constraint(equalTo: panel.bottomAnchor),

            imageWrapper.topAnchor.constraint(equalTo: imageContentContainer.topAnchor),
            imageWrapper.leadingAnchor.constraint(equalTo: imageContentContainer.leadingAnchor),
            imageWrapper.trailingAnchor.constraint(equalTo: imageContentContainer.trailingAnchor),
            imageWrapper.bottomAnchor.constraint(equalTo: imageContentContainer.bottomAnchor),

            imagePreviewView.topAnchor.constraint(equalTo: imageWrapper.topAnchor, constant: Layout.inputPadding),
            imagePreviewView.leadingAnchor.constraint(equalTo: imageWrapper.leadingAnchor, constant: Layout.inputPadding),
            imagePreviewView.trailingAnchor.constraint(equalTo: imageWrapper.trailingAnchor, constant: -Layout.inputPadding),
            imagePreviewView.bottomAnchor.constraint(equalTo: imageInfoLabel.topAnchor, constant: -Layout.spacing),

            imageInfoLabel.leadingAnchor.constraint(equalTo: imageWrapper.leadingAnchor, constant: Layout.inputPadding),
            imageInfoLabel.trailingAnchor.constraint(equalTo: imageWrapper.trailingAnchor, constant: -Layout.inputPadding),
            imageInfoLabel.bottomAnchor.constraint(equalTo: imageWrapper.bottomAnchor, constant: -Layout.inputPadding),

            // 画像ドロップゾーン
            imageDropZone.topAnchor.constraint(equalTo: imageContentContainer.topAnchor),
            imageDropZone.leadingAnchor.constraint(equalTo: imageContentContainer.leadingAnchor),
            imageDropZone.trailingAnchor.constraint(equalTo: imageContentContainer.trailingAnchor),
            imageDropZone.bottomAnchor.constraint(equalTo: imageContentContainer.bottomAnchor),

            // ファイルコンテンツコンテナ
            fileContentContainer.topAnchor.constraint(equalTo: contentLabel.bottomAnchor, constant: Layout.spacing),
            fileContentContainer.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            fileContentContainer.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            fileContentContainer.bottomAnchor.constraint(equalTo: panel.bottomAnchor),

            fileWrapper.topAnchor.constraint(equalTo: fileContentContainer.topAnchor),
            fileWrapper.leadingAnchor.constraint(equalTo: fileContentContainer.leadingAnchor),
            fileWrapper.trailingAnchor.constraint(equalTo: fileContentContainer.trailingAnchor),
            fileWrapper.bottomAnchor.constraint(equalTo: fileContentContainer.bottomAnchor),

            fileIconView.topAnchor.constraint(equalTo: fileWrapper.topAnchor, constant: Layout.padding),
            fileIconView.centerXAnchor.constraint(equalTo: fileWrapper.centerXAnchor),
            fileIconView.widthAnchor.constraint(equalToConstant: 64),
            fileIconView.heightAnchor.constraint(equalToConstant: 64),

            fileInfoLabel.topAnchor.constraint(equalTo: fileIconView.bottomAnchor, constant: Layout.spacing * 2),
            fileInfoLabel.leadingAnchor.constraint(equalTo: fileWrapper.leadingAnchor, constant: Layout.inputPadding),
            fileInfoLabel.trailingAnchor.constraint(equalTo: fileWrapper.trailingAnchor, constant: -Layout.inputPadding),

            // ファイルドロップゾーン
            fileDropZone.topAnchor.constraint(equalTo: fileContentContainer.topAnchor),
            fileDropZone.leadingAnchor.constraint(equalTo: fileContentContainer.leadingAnchor),
            fileDropZone.trailingAnchor.constraint(equalTo: fileContentContainer.trailingAnchor),
            fileDropZone.bottomAnchor.constraint(equalTo: fileContentContainer.bottomAnchor),
        ])
    }

    // MARK: - ヘルパー

    /// 角丸 + 細い枠線 + 薄い背景色のスタイル付きコンテナ
    private func makeStyledWrapper() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = Layout.inputCornerRadius
        view.layer?.borderWidth = Layout.inputBorderWidth
        view.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    /// ツールバー用ボーダレスアイコンボタンを設定するヘルパー
    private func configureToolbarButton(_ button: NSButton, symbol: String, toolTip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
        button.bezelStyle = .recessed
        button.showsBorderOnlyWhileMouseInside = true
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.toolTip = toolTip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    /// セクションラベルを生成するヘルパー
    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: Layout.labelFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    /// ファイルサイズを読みやすい文字列に変換する
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private func formatFileSize(_ bytes: Int64) -> String {
        Self.byteFormatter.string(fromByteCount: bytes)
    }

    /// コンテンツコンテナの表示を切り替える。3つのコンテナは排他表示。
    private enum ContentDisplay { case text, imageDropZone, imagePreview, fileDropZone, filePreview }

    private func showContentContainer(_ display: ContentDisplay) {
        textContentContainer.isHidden = true
        imageContentContainer.isHidden = true
        fileContentContainer.isHidden = true

        switch display {
        case .text:
            textContentContainer.isHidden = false
        case .imageDropZone:
            imageContentContainer.isHidden = false
            imageDropZone.isHidden = false
            imagePreviewView.isHidden = true
            imageInfoLabel.isHidden = true
        case .imagePreview:
            imageContentContainer.isHidden = false
            imageDropZone.isHidden = true
            imagePreviewView.isHidden = false
            imageInfoLabel.isHidden = false
        case .fileDropZone:
            fileContentContainer.isHidden = false
            fileDropZone.isHidden = false
            fileIconView.isHidden = true
            fileInfoLabel.isHidden = true
        case .filePreview:
            fileContentContainer.isHidden = false
            fileDropZone.isHidden = true
            fileIconView.isHidden = false
            fileInfoLabel.isHidden = false
        }
    }

    // MARK: - 表示

    func showWindow() {
        tableView.reloadData()
        if !store.items.isEmpty && tableView.selectedRow < 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateEditFields()
        updateEmptyState()

        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            setFrameOrigin(NSPoint(x: sf.midX - frame.width / 2, y: sf.midY - frame.height / 2))
        }

        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - キーボード

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == KeyCode.w && flags == .command {
            orderOut(nil)
            return true
        }
        if event.keyCode == KeyCode.n && flags == .command {
            addClicked()
            return true
        }
        // Cmd+Delete: 選択中のスニペットを削除（テキスト編集中は標準の「行頭まで削除」を優先）
        if event.keyCode == KeyCode.delete && flags == .command {
            if !(firstResponder is NSTextView) {
                removeClicked()
                return true
            }
        }
        // Cmd+A: ファーストレスポンダ（テキストフィールド/ビュー）に全選択を委譲
        if event.keyCode == KeyCode.a && flags == .command {
            firstResponder?.tryToPerform(#selector(NSText.selectAll(_:)), with: nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        store.items.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("SnippetCell")
        let cell: NSView

        if let existing = tableView.makeView(withIdentifier: id, owner: nil) {
            cell = existing
        } else {
            cell = makeSnippetCell(identifier: id)
        }

        guard let titleTF = cell.viewWithTag(CellTag.title) as? NSTextField,
              let previewTF = cell.viewWithTag(CellTag.preview) as? NSTextField,
              let iconView = cell.viewWithTag(CellTag.icon) as? NSImageView else {
            return cell
        }

        let item = store.items[row]

        // ── 1行目: タイトル ──
        let name = item.title.isEmpty ? "名称未設定" : item.title
        titleTF.stringValue = name
        titleTF.font = .systemFont(ofSize: Layout.cellTitleFontSize, weight: .medium)
        titleTF.textColor = item.title.isEmpty ? .tertiaryLabelColor : .labelColor

        // ── アイコン: コンテンツ型で切替 ──
        switch item.content {
        case .text:
            iconView.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)
            iconView.contentTintColor = NSColor.systemOrange.withAlphaComponent(0.7)
        case .image:
            iconView.image = NSImage(systemSymbolName: "photo.fill", accessibilityDescription: nil)
            iconView.contentTintColor = NSColor.systemBlue.withAlphaComponent(0.7)
        case .file:
            iconView.image = NSImage(systemSymbolName: "doc.fill", accessibilityDescription: nil)
            iconView.contentTintColor = NSColor.systemGray
        }

        // ── 2行目: 内容プレビュー ──
        switch item.content {
        case .text(let text):
            if text.isEmpty {
                previewTF.stringValue = "（内容なし）"
                previewTF.textColor = .tertiaryLabelColor
            } else {
                previewTF.stringValue = text
                    .components(separatedBy: .newlines)
                    .joined(separator: " ")
                previewTF.textColor = .secondaryLabelColor
            }
        case .image(let meta):
            let name = meta.originalFileName ?? meta.fileName
            previewTF.stringValue = "\(name)  \(meta.pixelWidth)x\(meta.pixelHeight)"
            previewTF.textColor = .secondaryLabelColor
        case .file(let meta):
            previewTF.stringValue = meta.originalFileName
            previewTF.textColor = .secondaryLabelColor
        }

        return cell
    }

    /// 2行セルを組み立てる
    private func makeSnippetCell(identifier: NSUserInterfaceItemIdentifier) -> NSView {
        let view = NSView()
        view.identifier = identifier

        let iconView = NSImageView()
        iconView.tag = CellTag.icon
        iconView.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)
        iconView.contentTintColor = NSColor.systemOrange.withAlphaComponent(0.7)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(iconView)

        let titleTF = NSTextField(labelWithString: "")
        titleTF.tag = CellTag.title
        titleTF.lineBreakMode = .byTruncatingTail
        titleTF.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleTF)

        let previewTF = NSTextField(labelWithString: "")
        previewTF.tag = CellTag.preview
        previewTF.lineBreakMode = .byTruncatingTail
        previewTF.font = .systemFont(ofSize: Layout.cellPreviewFontSize)
        previewTF.textColor = .secondaryLabelColor
        previewTF.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewTF)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            iconView.topAnchor.constraint(equalTo: view.topAnchor, constant: 9),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            titleTF.topAnchor.constraint(equalTo: view.topAnchor, constant: 7),
            titleTF.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            titleTF.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            previewTF.topAnchor.constraint(equalTo: titleTF.bottomAnchor, constant: 1),
            previewTF.leadingAnchor.constraint(equalTo: titleTF.leadingAnchor),
            previewTF.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
        ])
        return view
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("SnippetRow")
        if let existing = tableView.makeView(withIdentifier: id, owner: nil) as? SnippetRowView {
            existing.isHovered = false
            return existing
        }
        let rowView = SnippetRowView()
        rowView.identifier = id
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateEditFields()
    }

    // MARK: - 編集フィールド更新

    private func updateEditFields() {
        let row = tableView.selectedRow
        isUpdatingFields = true
        tagContainer.allKnownTags = store.allTags
        if row >= 0 && row < store.items.count {
            let item = store.items[row]
            titleField.stringValue = item.title
            tagContainer.tags = item.tags
            titleField.isEnabled = true
            removeButton.isEnabled = true
            typeSegment.isEnabled = true

            switch item.content {
            case .text(let text):
                typeSegment.selectedSegment = 0
                showContentContainer(.text)
                contentTextView.string = text
                contentTextView.isEditable = true
                contentTextView.isSelectable = true
                contentPlaceholder.isHidden = !text.isEmpty
            case .image(let meta):
                typeSegment.selectedSegment = 1
                showContentContainer(.imagePreview)
                contentTextView.isEditable = false
                contentTextView.isSelectable = false
                imagePreviewView.image = NSImage(contentsOf: imageStore.imageURL(for: meta.fileName))
                    ?? imageStore.thumbnail(for: meta.fileName)
                let name = meta.originalFileName ?? meta.fileName
                imageInfoLabel.stringValue = "\(name)  \(meta.pixelWidth)x\(meta.pixelHeight)  \(formatFileSize(meta.fileSizeBytes))"
            case .file(let meta):
                typeSegment.selectedSegment = 2
                showContentContainer(.filePreview)
                contentTextView.isEditable = false
                contentTextView.isSelectable = false
                fileIconView.image = fileStore.icon(for: meta)
                fileInfoLabel.stringValue = "\(meta.originalFileName)\n\(meta.fileExtension.uppercased())  \(formatFileSize(meta.fileSizeBytes))"
            }
        } else {
            titleField.stringValue = ""
            tagContainer.tags = []
            contentTextView.string = ""
            titleField.isEnabled = false
            contentTextView.isEditable = false
            contentTextView.isSelectable = false
            removeButton.isEnabled = false
            typeSegment.isEnabled = false
            typeSegment.selectedSegment = 0
            contentPlaceholder.isHidden = true
            showContentContainer(.text)
        }
        isUpdatingFields = false
    }

    private func saveCurrentEdits() {
        let row = tableView.selectedRow
        guard row >= 0, row < store.items.count else { return }
        let item = store.items[row]
        let content: SnippetContent
        switch item.content {
        case .text:
            content = .text(contentTextView.string)
        case .image, .file:
            content = item.content
        }
        store.update(
            id: item.id,
            title: titleField.stringValue,
            content: content,
            tags: tagContainer.tags
        )
        tagContainer.allKnownTags = store.allTags
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }

    private func updateEmptyState() {
        emptyStateView.isHidden = !store.items.isEmpty
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard !isUpdatingFields else { return }
        saveCurrentEdits()
    }

    /// titleField の Tab でタグフィールドに移動
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            tagContainer.focusInputField()
            return true
        }
        return false
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !isUpdatingFields else { return }
        contentPlaceholder.isHidden = !contentTextView.string.isEmpty
        saveCurrentEdits()
    }

    /// テキスト変更前にプレースホルダーを即座に制御する（IME 入力時の重なり防止）
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if let str = replacementString {
            let currentLength = (textView.string as NSString).length
            let willBeEmpty = currentLength - affectedCharRange.length + (str as NSString).length == 0
            contentPlaceholder.isHidden = !willBeEmpty
        }
        return true
    }

    /// Shift+Tab で内容フィールドからタグフィールドにフォーカスを戻す
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            tagContainer.focusInputField()
            return true
        }
        return false
    }

    // MARK: - アクション

    @objc private func addClicked() {
        store.add(title: "新しいスニペット", content: .text(""))
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        updateEditFields()
        updateEmptyState()
        makeFirstResponder(titleField)
        titleField.selectText(nil)
    }

    @objc private func typeSegmentChanged() {
        let row = tableView.selectedRow
        guard row >= 0, row < store.items.count else { return }

        switch typeSegment.selectedSegment {
        case 0: changeToText()
        case 1: changeToImage()
        case 2: changeToFile()
        default: break
        }
    }

    private func changeToText() {
        let row = tableView.selectedRow
        guard row >= 0, row < store.items.count else { return }
        let item = store.items[row]
        // ストアが既にテキストでもUI（ドロップゾーン）が出ている場合があるので、常にリセット
        if case .text = item.content {
            showContentContainer(.text)
            updateEditFields()
            return
        }
        store.update(id: item.id, title: item.title, content: .text(""), tags: item.tags)
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        updateEditFields()
    }

    private func changeToImage() {
        let row = tableView.selectedRow
        guard row >= 0, row < store.items.count else {
            revertTypeSegment()
            return
        }
        showContentContainer(.imageDropZone)
    }

    private func changeToFile() {
        let row = tableView.selectedRow
        guard row >= 0, row < store.items.count else {
            revertTypeSegment()
            return
        }
        showContentContainer(.fileDropZone)
    }

    /// ファイル選択キャンセル時にセグメントを現在のコンテンツ型に戻す
    private func revertTypeSegment() {
        let row = tableView.selectedRow
        guard row >= 0, row < store.items.count else { return }
        switch store.items[row].content {
        case .text: typeSegment.selectedSegment = 0
        case .image: typeSegment.selectedSegment = 1
        case .file: typeSegment.selectedSegment = 2
        }
    }

    /// ドロップゾーンからファイルが選択された時のハンドラ
    private func handleDroppedFile(_ url: URL, forType type: DropZoneView.Kind) {
        let row = tableView.selectedRow
        guard row >= 0, row < store.items.count else { return }

        guard let data = try? Data(contentsOf: url) else { return }
        let originalFileName = url.lastPathComponent
        let item = store.items[row]

        switch type {
        case .image:
            let utType = UTType(filenameExtension: url.pathExtension)?.identifier ?? "public.image"
            guard let metadata = imageStore.save(data: data, utType: utType, originalFileName: originalFileName) else { return }
            store.update(id: item.id, title: item.title, content: .image(metadata), tags: item.tags)
        case .file:
            guard let metadata = fileStore.save(data: data, originalFileName: originalFileName) else { return }
            store.update(id: item.id, title: item.title, content: .file(metadata), tags: item.tags)
        }

        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        updateEditFields()
    }

    @objc private func actionClicked() {
        let menu = NSMenu()
        let importItem = NSMenuItem(title: "インポート…", action: #selector(importClicked), keyEquivalent: "")
        importItem.target = self
        menu.addItem(importItem)
        let exportItem = NSMenuItem(title: "エクスポート…", action: #selector(exportClicked), keyEquivalent: "")
        exportItem.target = self
        menu.addItem(exportItem)

        let point = NSPoint(x: 0, y: actionButton.bounds.height)
        menu.popUp(positioning: nil, at: point, in: actionButton)
    }

    @objc private func importClicked() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.json]
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.message = "インポートする JSON ファイルを選択してください"

        guard openPanel.runModal() == .OK, let url = openPanel.url else { return }

        do {
            let result = try store.parseImportFile(url: url)
            let total = result.new.count + result.duplicates.count

            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "スニペットをインポート"

            if result.new.isEmpty {
                alert.informativeText = "ファイル内: \(total)件\n\nすべて既存のスニペットと重複しています。\nインポートする項目はありません。"
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }

            var info = "ファイル内: \(total)件\n  新規追加: \(result.new.count)件"
            if !result.duplicates.isEmpty {
                info += "\n  重複スキップ: \(result.duplicates.count)件"
            }
            info += "\n\nインポートしますか？"
            alert.informativeText = info
            alert.addButton(withTitle: "インポート")
            alert.addButton(withTitle: "キャンセル")

            guard alert.runModal() == .alertFirstButtonReturn else { return }

            store.importItems(result.new)
            tableView.reloadData()
            if !store.items.isEmpty {
                tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
            updateEditFields()
            updateEmptyState()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "インポートに失敗しました"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func exportClicked() {
        guard !store.items.isEmpty else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "エクスポートするスニペットがありません"
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "snippets.json"
        savePanel.message = "スニペットのエクスポート先を選択してください"

        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }

        do {
            try store.exportToFile(url: url)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "エクスポートに失敗しました"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func removeClicked() {
        let row = tableView.selectedRow
        guard row >= 0, row < store.items.count else { return }

        let item = store.items[row]
        let title = item.title.isEmpty ? "名称未設定" : item.title

        let alert = NSAlert()
        alert.messageText = "スニペットを削除"
        alert.informativeText = "「\(title)」を削除しますか？\nこの操作は取り消せません。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "キャンセル")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        store.remove(id: item.id)
        tableView.reloadData()
        if !store.items.isEmpty {
            let newRow = min(row, store.items.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
        }
        updateEditFields()
        updateEmptyState()
    }
}
