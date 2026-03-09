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

    private static let cornerRadius: CGFloat = 12

    var onFileSelected: ((URL) -> Void)?

    private let kind: Kind
    private let dashBorder = CAShapeLayer()
    private let iconView = NSImageView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let browseButton = NSButton()
    private var isDragOver = false {
        didSet { updateAppearance(animated: true) }
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
        layer?.cornerRadius = Self.cornerRadius
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.03).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        // 破線ボーダー（アクセントカラー）
        dashBorder.fillColor = nil
        dashBorder.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        dashBorder.lineWidth = 1.5
        dashBorder.lineDashPattern = [6, 4]
        layer?.addSublayer(dashBorder)

        // アイコン
        let symbolName = kind == .image ? "photo.on.rectangle.angled" : "arrow.down.doc"
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        iconView.contentTintColor = .controlAccentColor.withAlphaComponent(0.4)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .light)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        // メッセージ
        let msg = kind == .image
            ? "画像をドラッグ&ドロップ"
            : "ファイルをドラッグ&ドロップ"
        messageLabel.stringValue = msg
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageLabel)

        // 選択ボタン（フラットなピル型）
        let buttonTitle = kind == .image ? "または選択" : "または選択"
        browseButton.title = buttonTitle
        browseButton.isBordered = false
        browseButton.font = .systemFont(ofSize: 11, weight: .medium)
        browseButton.contentTintColor = .controlAccentColor
        browseButton.target = self
        browseButton.action = #selector(browseClicked)
        browseButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(browseButton)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),

            messageLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 8),
            messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),

            browseButton.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 4),
            browseButton.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }

    private func registerDragTypes() {
        registerForDraggedTypes([.fileURL])
    }

    override func layout() {
        super.layout()
        let path = CGPath(roundedRect: bounds.insetBy(dx: 2, dy: 2),
                          cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius,
                          transform: nil)
        dashBorder.path = path
        dashBorder.frame = bounds
    }

    private func updateAppearance(animated: Bool) {
        let bgColor: CGColor
        let strokeColor: CGColor
        let iconTint: NSColor

        if isDragOver {
            bgColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
            strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
            iconTint = .controlAccentColor.withAlphaComponent(0.7)
        } else {
            bgColor = NSColor.labelColor.withAlphaComponent(0.03).cgColor
            strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
            iconTint = .controlAccentColor.withAlphaComponent(0.4)
        }

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.allowsImplicitAnimation = true
                layer?.backgroundColor = bgColor
                iconView.contentTintColor = iconTint
            }
            // CAShapeLayer の色はアニメーションブロック外で直接変更
            let anim = CABasicAnimation(keyPath: "strokeColor")
            anim.fromValue = dashBorder.strokeColor
            anim.toValue = strokeColor
            anim.duration = 0.15
            dashBorder.strokeColor = strokeColor
            dashBorder.add(anim, forKey: "strokeColor")
        } else {
            layer?.backgroundColor = bgColor
            dashBorder.strokeColor = strokeColor
            iconView.contentTintColor = iconTint
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

// MARK: - ピル型セグメントコントロール

/// モダンなピル型タイプ切替コントロール。
/// 選択中のセグメントにアクセントカラーの背景がスライドアニメーションで移動する。
@MainActor
private final class PillSegmentControl: NSView {
    struct Segment {
        let icon: String
        let label: String
    }

    var selectedSegment: Int = 0 {
        didSet {
            if oldValue != selectedSegment { updateSelection(animated: true) }
        }
    }
    var isEnabled: Bool = true {
        didSet { alphaValue = isEnabled ? 1.0 : 0.5 }
    }
    var target: AnyObject?
    var action: Selector?

    private let segments: [Segment]
    private var labels: [NSTextField] = []
    private var icons: [NSImageView] = []
    private let sliderLayer = CALayer()
    private static let inset: CGFloat = 3

    init(segments: [Segment]) {
        self.segments = segments
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor

        // スライダー（CALayer で直接制御、anchorPoint を左下に設定）
        sliderLayer.anchorPoint = .zero
        sliderLayer.cornerRadius = 8
        sliderLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        layer?.addSublayer(sliderLayer)

        // ラベル群を均等配置する NSStackView
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for seg in segments {
            // 各セグメントのコンテナ
            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false

            let iconView = NSImageView()
            iconView.image = NSImage(systemSymbolName: seg.icon, accessibilityDescription: nil)
            iconView.imageScaling = .scaleProportionallyDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(iconView)

            let lbl = NSTextField(labelWithString: seg.label)
            lbl.font = .systemFont(ofSize: 11, weight: .medium)
            lbl.alignment = .center
            lbl.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(lbl)

            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: 12),
                iconView.heightAnchor.constraint(equalToConstant: 12),
                iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                iconView.trailingAnchor.constraint(equalTo: lbl.leadingAnchor, constant: -3),

                lbl.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                lbl.centerXAnchor.constraint(equalTo: container.centerXAnchor, constant: 8),
            ])

            icons.append(iconView)
            labels.append(lbl)
            stack.addArrangedSubview(container)
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    override func layout() {
        super.layout()
        updateSliderPosition(animated: false)
        updateColors()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let segWidth = bounds.width / CGFloat(segments.count)
        let index = max(0, min(Int(loc.x / segWidth), segments.count - 1))
        guard index != selectedSegment else { return }
        selectedSegment = index
        _ = target?.perform(action, with: self)
    }

    private func updateSelection(animated: Bool) {
        updateSliderPosition(animated: animated)
        updateColors()
    }

    private func updateSliderPosition(animated: Bool) {
        guard bounds.width > 0 else { return }
        let segWidth = bounds.width / CGFloat(segments.count)
        let inset = Self.inset
        let sliderWidth = segWidth - inset * 2
        let sliderHeight = bounds.height - inset * 2
        let newX = CGFloat(selectedSegment) * segWidth + inset

        // サイズは即座に設定
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sliderLayer.bounds = CGRect(x: 0, y: 0, width: sliderWidth, height: sliderHeight)
        CATransaction.commit()

        // 位置（anchorPoint=0,0 基準）をアニメーション
        let newPosition = CGPoint(x: newX, y: inset)
        if animated {
            let anim = CABasicAnimation(keyPath: "position")
            anim.fromValue = sliderLayer.position
            anim.toValue = newPosition
            anim.duration = 0.2
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sliderLayer.position = newPosition
            sliderLayer.add(anim, forKey: "slide")
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sliderLayer.position = newPosition
            CATransaction.commit()
        }
    }

    private func updateColors() {
        for (i, lbl) in labels.enumerated() {
            let color: NSColor = i == selectedSegment ? .controlAccentColor : .secondaryLabelColor
            lbl.textColor = color
            icons[i].contentTintColor = color
        }
    }
}

@MainActor
final class SnippetManagerWindow: NSWindow, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate {

    // MARK: - 定数

    private enum Layout {
        static let windowSize = NSSize(width: 1008, height: 691)
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
        // 画像・ファイルカード共通
        static let cardHeight: CGFloat = 96
        static let cardCornerRadius: CGFloat = 10
        static let cardPadding: CGFloat = 12
        static let imageThumbSize: CGFloat = 72
        static let fileIconSize: CGFloat = 56
        static let clearButtonSize: CGFloat = 24
    }

    private enum KeyCode {
        static let a: UInt16 = 0
        static let c: UInt16 = 8
        static let v: UInt16 = 9
        static let x: UInt16 = 7
        static let z: UInt16 = 6
        static let w: UInt16 = 13
        static let n: UInt16 = 45
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
    private let typeSegment = PillSegmentControl(segments: [
        .init(icon: "text.alignleft", label: "テキスト"),
        .init(icon: "photo", label: "画像"),
        .init(icon: "doc", label: "ファイル"),
    ])

    // 編集フォームコンテナ & 未選択プレースホルダー
    private let editFormContainer = NSView()
    private let noSelectionLabel = NSTextField(labelWithString: "")

    // 画像/ファイルコンテンツ用コンテナ
    private let textContentContainer = NSView()
    private let imageContentContainer = NSView()
    private let fileContentContainer = NSView()
    private let imageCardView = NSView()
    private let imagePreviewView = NSImageView()
    private let imageNameLabel = NSTextField(labelWithString: "")
    private let imageInfoLabel = NSTextField(labelWithString: "")
    private let imageClearButton = NSButton()
    private let fileIconView = NSImageView()
    private let fileNameLabel = NSTextField(labelWithString: "")
    private let fileInfoLabel = NSTextField(labelWithString: "")
    private let fileCardView = NSView()
    private let fileClearButton = NSButton()

    // ドロップゾーン（画像/ファイル選択用）
    private let imageDropZone = DropZoneView(kind: .image)
    private let fileDropZone = DropZoneView(kind: .file)

    // MARK: - 状態

    private let store: SnippetStore
    private let imageStore: ImageStore
    private let fileStore: FileStore
    private var hasBeenShown = false
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
        collectionBehavior = [.moveToActiveSpace]
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
        emptyIcon.image = NSImage(systemSymbolName: "text.badge.plus", accessibilityDescription: nil)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .thin)
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.addSubview(emptyIcon)

        let emptyTitle = NSTextField(labelWithString: "スニペットがありません")
        emptyTitle.font = .systemFont(ofSize: Layout.fieldFontSize, weight: .medium)
        emptyTitle.textColor = .secondaryLabelColor
        emptyTitle.alignment = .center
        emptyTitle.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.addSubview(emptyTitle)

        let emptyHint = NSTextField(labelWithString: "下の + ボタンまたは ⌘N で追加")
        emptyHint.font = .systemFont(ofSize: Layout.labelFontSize)
        emptyHint.textColor = .tertiaryLabelColor
        emptyHint.alignment = .center
        emptyHint.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.addSubview(emptyHint)

        NSLayoutConstraint.activate([
            emptyIcon.topAnchor.constraint(equalTo: emptyStateView.topAnchor),
            emptyIcon.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),

            emptyTitle.topAnchor.constraint(equalTo: emptyIcon.bottomAnchor, constant: 10),
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
        // ── 未選択プレースホルダー ──
        noSelectionLabel.stringValue = "スニペットを選択してください"
        noSelectionLabel.font = .systemFont(ofSize: Layout.subtitleFontSize)
        noSelectionLabel.textColor = .tertiaryLabelColor
        noSelectionLabel.alignment = .center
        noSelectionLabel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(noSelectionLabel)
        NSLayoutConstraint.activate([
            noSelectionLabel.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            noSelectionLabel.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
        ])

        // ── 編集フォームコンテナ ──
        editFormContainer.translatesAutoresizingMaskIntoConstraints = false
        editFormContainer.isHidden = true
        panel.addSubview(editFormContainer)
        NSLayoutConstraint.activate([
            editFormContainer.topAnchor.constraint(equalTo: panel.topAnchor),
            editFormContainer.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            editFormContainer.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            editFormContainer.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])

        // ── スニペット名 ──
        let titleLabel = makeLabel("スニペット名")
        editFormContainer.addSubview(titleLabel)

        let titleWrapper = makeStyledWrapper()
        editFormContainer.addSubview(titleWrapper)

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
        editFormContainer.addSubview(tagLabel)

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
        editFormContainer.addSubview(tagContainer)

        // ── タイプ ──
        let typeLabel = makeLabel("タイプ")
        editFormContainer.addSubview(typeLabel)

        typeSegment.target = self
        typeSegment.action = #selector(typeSegmentChanged)
        typeSegment.isEnabled = false
        typeSegment.translatesAutoresizingMaskIntoConstraints = false
        editFormContainer.addSubview(typeSegment)

        // ── 内容ラベル ──
        let contentLabel = makeLabel("内容")
        editFormContainer.addSubview(contentLabel)

        // ── テキストコンテンツコンテナ ──
        textContentContainer.translatesAutoresizingMaskIntoConstraints = false
        editFormContainer.addSubview(textContentContainer)

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
        editFormContainer.addSubview(imageContentContainer)

        let imageWrapper = makeStyledWrapper()
        imageContentContainer.addSubview(imageWrapper)

        // カード型画像プレビュー（サムネイル + ファイル名 + メタ情報を横並び）
        imageCardView.wantsLayer = true
        imageCardView.layer?.cornerRadius = Layout.cardCornerRadius
        imageCardView.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
        imageCardView.translatesAutoresizingMaskIntoConstraints = false
        imageWrapper.addSubview(imageCardView)

        imagePreviewView.imageScaling = .scaleProportionallyDown
        imagePreviewView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imagePreviewView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imagePreviewView.translatesAutoresizingMaskIntoConstraints = false
        imageCardView.addSubview(imagePreviewView)

        imageNameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        imageNameLabel.textColor = .labelColor
        imageNameLabel.lineBreakMode = .byTruncatingTail
        imageNameLabel.translatesAutoresizingMaskIntoConstraints = false
        imageCardView.addSubview(imageNameLabel)

        imageInfoLabel.font = .systemFont(ofSize: 11)
        imageInfoLabel.textColor = .secondaryLabelColor
        imageInfoLabel.lineBreakMode = .byTruncatingTail
        imageInfoLabel.translatesAutoresizingMaskIntoConstraints = false
        imageCardView.addSubview(imageInfoLabel)

        configureToolbarButton(imageClearButton, symbol: "trash", toolTip: "画像を削除", action: #selector(clearImageContent))
        imageCardView.addSubview(imageClearButton)

        // ドロップゾーン（画像）
        imageDropZone.onFileSelected = { [weak self] url in
            self?.handleDroppedFile(url, forType: .image)
        }
        imageContentContainer.addSubview(imageDropZone)

        // ── ファイルコンテンツコンテナ ──
        fileContentContainer.translatesAutoresizingMaskIntoConstraints = false
        fileContentContainer.isHidden = true
        editFormContainer.addSubview(fileContentContainer)

        let fileWrapper = makeStyledWrapper()
        fileContentContainer.addSubview(fileWrapper)

        // カード型ファイルプレビュー（アイコン + ファイル名 + メタ情報を横並び）
        fileCardView.wantsLayer = true
        fileCardView.layer?.cornerRadius = Layout.cardCornerRadius
        fileCardView.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
        fileCardView.translatesAutoresizingMaskIntoConstraints = false
        fileWrapper.addSubview(fileCardView)

        fileIconView.imageScaling = .scaleProportionallyUpOrDown
        fileIconView.translatesAutoresizingMaskIntoConstraints = false
        fileCardView.addSubview(fileIconView)

        fileNameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        fileNameLabel.textColor = .labelColor
        fileNameLabel.lineBreakMode = .byTruncatingTail
        fileNameLabel.translatesAutoresizingMaskIntoConstraints = false
        fileCardView.addSubview(fileNameLabel)

        fileInfoLabel.font = .systemFont(ofSize: 11)
        fileInfoLabel.textColor = .secondaryLabelColor
        fileInfoLabel.lineBreakMode = .byTruncatingTail
        fileInfoLabel.translatesAutoresizingMaskIntoConstraints = false
        fileCardView.addSubview(fileInfoLabel)

        configureToolbarButton(fileClearButton, symbol: "trash", toolTip: "ファイルを削除", action: #selector(clearFileContent))
        fileCardView.addSubview(fileClearButton)

        // ドロップゾーン（ファイル）
        fileDropZone.onFileSelected = { [weak self] url in
            self?.handleDroppedFile(url, forType: .file)
        }
        fileContentContainer.addSubview(fileDropZone)

        let form = editFormContainer
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: form.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: form.leadingAnchor),

            titleWrapper.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Layout.spacing),
            titleWrapper.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            titleWrapper.trailingAnchor.constraint(equalTo: form.trailingAnchor),
            titleWrapper.heightAnchor.constraint(equalToConstant: Layout.fieldWrapperHeight),

            titleField.leadingAnchor.constraint(equalTo: titleWrapper.leadingAnchor, constant: Layout.inputPadding),
            titleField.trailingAnchor.constraint(equalTo: titleWrapper.trailingAnchor, constant: -Layout.inputPadding),
            titleField.centerYAnchor.constraint(equalTo: titleWrapper.centerYAnchor),

            tagLabel.topAnchor.constraint(equalTo: titleWrapper.bottomAnchor, constant: Layout.sectionSpacing),
            tagLabel.leadingAnchor.constraint(equalTo: form.leadingAnchor),

            tagContainer.topAnchor.constraint(equalTo: tagLabel.bottomAnchor, constant: Layout.spacing),
            tagContainer.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            tagContainer.trailingAnchor.constraint(equalTo: form.trailingAnchor),

            typeLabel.topAnchor.constraint(equalTo: tagContainer.bottomAnchor, constant: Layout.sectionSpacing),
            typeLabel.leadingAnchor.constraint(equalTo: form.leadingAnchor),

            typeSegment.topAnchor.constraint(equalTo: typeLabel.bottomAnchor, constant: Layout.spacing),
            typeSegment.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            typeSegment.widthAnchor.constraint(equalToConstant: Layout.typeSegmentWidth),

            contentLabel.topAnchor.constraint(equalTo: typeSegment.bottomAnchor, constant: Layout.sectionSpacing),
            contentLabel.leadingAnchor.constraint(equalTo: form.leadingAnchor),

            // テキストコンテンツコンテナ
            textContentContainer.topAnchor.constraint(equalTo: contentLabel.bottomAnchor, constant: Layout.spacing),
            textContentContainer.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            textContentContainer.trailingAnchor.constraint(equalTo: form.trailingAnchor),
            textContentContainer.bottomAnchor.constraint(equalTo: form.bottomAnchor),

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
            imageContentContainer.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            imageContentContainer.trailingAnchor.constraint(equalTo: form.trailingAnchor),
            imageContentContainer.bottomAnchor.constraint(equalTo: form.bottomAnchor),

            imageWrapper.topAnchor.constraint(equalTo: imageContentContainer.topAnchor),
            imageWrapper.leadingAnchor.constraint(equalTo: imageContentContainer.leadingAnchor),
            imageWrapper.trailingAnchor.constraint(equalTo: imageContentContainer.trailingAnchor),
            imageWrapper.bottomAnchor.constraint(equalTo: imageContentContainer.bottomAnchor),

            imageCardView.topAnchor.constraint(equalTo: imageWrapper.topAnchor, constant: Layout.inputPadding),
            imageCardView.leadingAnchor.constraint(equalTo: imageWrapper.leadingAnchor, constant: Layout.inputPadding),
            imageCardView.trailingAnchor.constraint(equalTo: imageWrapper.trailingAnchor, constant: -Layout.inputPadding),
            imageCardView.heightAnchor.constraint(equalToConstant: Layout.cardHeight),

            imagePreviewView.leadingAnchor.constraint(equalTo: imageCardView.leadingAnchor, constant: Layout.cardPadding),
            imagePreviewView.centerYAnchor.constraint(equalTo: imageCardView.centerYAnchor),
            imagePreviewView.widthAnchor.constraint(equalToConstant: Layout.imageThumbSize),
            imagePreviewView.heightAnchor.constraint(equalToConstant: Layout.imageThumbSize),

            imageNameLabel.leadingAnchor.constraint(equalTo: imagePreviewView.trailingAnchor, constant: 10),
            imageNameLabel.trailingAnchor.constraint(equalTo: imageClearButton.leadingAnchor, constant: -4),
            imageNameLabel.bottomAnchor.constraint(equalTo: imageCardView.centerYAnchor, constant: -1),

            imageInfoLabel.leadingAnchor.constraint(equalTo: imageNameLabel.leadingAnchor),
            imageInfoLabel.trailingAnchor.constraint(equalTo: imageNameLabel.trailingAnchor),
            imageInfoLabel.topAnchor.constraint(equalTo: imageCardView.centerYAnchor, constant: 1),

            imageClearButton.trailingAnchor.constraint(equalTo: imageCardView.trailingAnchor, constant: -Layout.cardPadding),
            imageClearButton.centerYAnchor.constraint(equalTo: imageCardView.centerYAnchor),
            imageClearButton.widthAnchor.constraint(equalToConstant: Layout.clearButtonSize),
            imageClearButton.heightAnchor.constraint(equalToConstant: Layout.clearButtonSize),

            // 画像ドロップゾーン
            imageDropZone.topAnchor.constraint(equalTo: imageContentContainer.topAnchor),
            imageDropZone.leadingAnchor.constraint(equalTo: imageContentContainer.leadingAnchor),
            imageDropZone.trailingAnchor.constraint(equalTo: imageContentContainer.trailingAnchor),
            imageDropZone.bottomAnchor.constraint(equalTo: imageContentContainer.bottomAnchor),

            // ファイルコンテンツコンテナ
            fileContentContainer.topAnchor.constraint(equalTo: contentLabel.bottomAnchor, constant: Layout.spacing),
            fileContentContainer.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            fileContentContainer.trailingAnchor.constraint(equalTo: form.trailingAnchor),
            fileContentContainer.bottomAnchor.constraint(equalTo: form.bottomAnchor),

            fileWrapper.topAnchor.constraint(equalTo: fileContentContainer.topAnchor),
            fileWrapper.leadingAnchor.constraint(equalTo: fileContentContainer.leadingAnchor),
            fileWrapper.trailingAnchor.constraint(equalTo: fileContentContainer.trailingAnchor),
            fileWrapper.bottomAnchor.constraint(equalTo: fileContentContainer.bottomAnchor),

            fileCardView.topAnchor.constraint(equalTo: fileWrapper.topAnchor, constant: Layout.inputPadding),
            fileCardView.leadingAnchor.constraint(equalTo: fileWrapper.leadingAnchor, constant: Layout.inputPadding),
            fileCardView.trailingAnchor.constraint(equalTo: fileWrapper.trailingAnchor, constant: -Layout.inputPadding),
            fileCardView.heightAnchor.constraint(equalToConstant: Layout.cardHeight),

            fileIconView.leadingAnchor.constraint(equalTo: fileCardView.leadingAnchor, constant: Layout.cardPadding),
            fileIconView.centerYAnchor.constraint(equalTo: fileCardView.centerYAnchor),
            fileIconView.widthAnchor.constraint(equalToConstant: Layout.fileIconSize),
            fileIconView.heightAnchor.constraint(equalToConstant: Layout.fileIconSize),

            fileNameLabel.leadingAnchor.constraint(equalTo: fileIconView.trailingAnchor, constant: 10),
            fileNameLabel.trailingAnchor.constraint(equalTo: fileClearButton.leadingAnchor, constant: -4),
            fileNameLabel.bottomAnchor.constraint(equalTo: fileCardView.centerYAnchor, constant: -1),

            fileInfoLabel.leadingAnchor.constraint(equalTo: fileNameLabel.leadingAnchor),
            fileInfoLabel.trailingAnchor.constraint(equalTo: fileNameLabel.trailingAnchor),
            fileInfoLabel.topAnchor.constraint(equalTo: fileCardView.centerYAnchor, constant: 1),

            fileClearButton.trailingAnchor.constraint(equalTo: fileCardView.trailingAnchor, constant: -Layout.cardPadding),
            fileClearButton.centerYAnchor.constraint(equalTo: fileCardView.centerYAnchor),
            fileClearButton.widthAnchor.constraint(equalToConstant: Layout.clearButtonSize),
            fileClearButton.heightAnchor.constraint(equalToConstant: Layout.clearButtonSize),

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
            imageCardView.isHidden = true
        case .imagePreview:
            imageContentContainer.isHidden = false
            imageDropZone.isHidden = true
            imageCardView.isHidden = false
        case .fileDropZone:
            fileContentContainer.isHidden = false
            fileDropZone.isHidden = false
            fileCardView.isHidden = true
        case .filePreview:
            fileContentContainer.isHidden = false
            fileDropZone.isHidden = true
            fileCardView.isHidden = false
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

        // 初回のみ画面中央に配置。以降はユーザーが移動した位置を維持。
        if !hasBeenShown {
            center()
            hasBeenShown = true
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
        // 標準の編集コマンドをファーストレスポンダに委譲
        // （メインメニューを持たない LSUIElement アプリでは自動転送されないため）
        if flags == .command {
            let action: Selector? = switch event.keyCode {
            case KeyCode.v: #selector(NSText.paste(_:))
            case KeyCode.c: #selector(NSText.copy(_:))
            case KeyCode.x: #selector(NSText.cut(_:))
            case KeyCode.a: #selector(NSText.selectAll(_:))
            case KeyCode.z: #selector(UndoManager.undo)
            default: nil
            }
            if let action, firstResponder?.tryToPerform(action, with: nil) == true {
                return true
            }
        }
        if flags == [.command, .shift] && event.keyCode == KeyCode.z {
            if firstResponder?.tryToPerform(#selector(UndoManager.redo), with: nil) == true {
                return true
            }
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
            iconView.image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil)
            iconView.contentTintColor = NSColor.secondaryLabelColor
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
        iconView.image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil)
        iconView.contentTintColor = NSColor.secondaryLabelColor
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
            iconView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
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
            editFormContainer.isHidden = false
            noSelectionLabel.isHidden = true
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
                imagePreviewView.image = imageStore.thumbnail(for: meta.fileName)
                    ?? NSImage(contentsOf: imageStore.imageURL(for: meta.fileName))
                imageNameLabel.stringValue = meta.originalFileName ?? meta.fileName
                let dims = "\(meta.pixelWidth)x\(meta.pixelHeight)"
                let size = formatFileSize(meta.fileSizeBytes)
                imageInfoLabel.stringValue = "\(dims) · \(size)"
            case .file(let meta):
                typeSegment.selectedSegment = 2
                showContentContainer(.filePreview)
                contentTextView.isEditable = false
                contentTextView.isSelectable = false
                fileIconView.image = fileStore.icon(for: meta)
                fileNameLabel.stringValue = meta.originalFileName
                let ext = meta.fileExtension.uppercased()
                let size = formatFileSize(meta.fileSizeBytes)
                fileInfoLabel.stringValue = ext.isEmpty ? size : "\(ext) · \(size)"
            }
        } else {
            editFormContainer.isHidden = true
            noSelectionLabel.isHidden = store.items.isEmpty
            removeButton.isEnabled = false
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
        let empty = store.items.isEmpty
        emptyStateView.isHidden = !empty
        // 空状態のとき右パネルのプレースホルダーも隠す
        if empty {
            noSelectionLabel.isHidden = true
        }
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
        let item = store.items[row]

        let hasContent: Bool
        switch item.content {
        case .text(let text): hasContent = !text.isEmpty
        case .image, .file: hasContent = true
        }

        // 同じタイプへの変更は確認不要
        let isSameType: Bool
        switch (item.content, typeSegment.selectedSegment) {
        case (.text, 0), (.image, 1), (.file, 2): isSameType = true
        default: isSameType = false
        }

        if hasContent && !isSameType {
            let alert = NSAlert()
            alert.messageText = "タイプを変更しますか？"
            alert.informativeText = "現在の内容は失われます。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "変更")
            alert.addButton(withTitle: "キャンセル")
            alert.beginSheetModal(for: self) { [weak self] response in
                guard let self else { return }
                if response == .alertFirstButtonReturn {
                    self.applyTypeChange()
                } else {
                    self.revertTypeSegment()
                }
            }
        } else {
            applyTypeChange()
        }
    }

    private func applyTypeChange() {
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
        cleanupContentFile(item)
        store.update(id: item.id, title: item.title, content: .text(""), tags: item.tags)
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        updateEditFields()
    }

    /// 画像・ファイルコンテンツのディスク上のファイルを削除する
    private func cleanupContentFile(_ item: SnippetItem) {
        switch item.content {
        case .image(let meta):
            store.onImageDelete?(meta.fileName)
        case .file(let meta):
            store.onFileDelete?(meta.fileName)
        case .text:
            break
        }
    }

    @objc private func clearImageContent() { confirmAndClearContent(label: "画像") }
    @objc private func clearFileContent() { confirmAndClearContent(label: "ファイル") }

    /// 確認ダイアログを出してからコンテンツをクリアする共通処理
    private func confirmAndClearContent(label: String) {
        let row = tableView.selectedRow
        guard row >= 0, row < store.items.count else { return }
        let item = store.items[row]

        let alert = NSAlert()
        alert.messageText = "\(label)を削除しますか？"
        alert.informativeText = "登録済みの\(label)が削除されます。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "キャンセル")
        alert.beginSheetModal(for: self) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.cleanupContentFile(item)
            self.store.update(id: item.id, title: item.title, content: .text(""), tags: item.tags)
            self.typeSegment.selectedSegment = 0
            self.showContentContainer(.text)
            self.tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
            self.updateEditFields()
        }
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

        // 既存の画像・ファイルをクリーンアップ
        cleanupContentFile(item)

        // ファイルタイプでも画像ファイルなら自動的に画像として処理
        let isImage = type == .image
            || (UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false)

        if isImage {
            let utType = UTType(filenameExtension: url.pathExtension)?.identifier ?? "public.image"
            guard let metadata = imageStore.save(data: data, utType: utType, originalFileName: originalFileName) else { return }
            store.update(id: item.id, title: item.title, content: .image(metadata), tags: item.tags)
            typeSegment.selectedSegment = 1
        } else {
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
        openPanel.allowedContentTypes = [.json, .zip]
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.message = "インポートするファイルを選択してください（.zip または .json）"

        guard openPanel.runModal() == .OK, let url = openPanel.url else { return }

        do {
            let ext = url.pathExtension.lowercased()
            let isBundle = ext == "zip" || ext == "fuzzypaste"

            // バンドルの場合は展開して snippets.json を取得
            let jsonData: Data
            var bundleTempDir: URL?

            if isBundle {
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("FuzzyPaste-import-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                bundleTempDir = tempDir

                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                proc.arguments = ["-x", "-k", url.path, tempDir.path]
                try proc.run()
                proc.waitUntilExit()
                guard proc.terminationStatus == 0 else {
                    throw NSError(domain: "FuzzyPaste", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "ZIP ファイルの展開に失敗しました"])
                }

                let jsonURL = tempDir.appendingPathComponent("snippets.json")
                guard FileManager.default.fileExists(atPath: jsonURL.path) else {
                    throw NSError(domain: "FuzzyPaste", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "バンドル内に snippets.json が見つかりません"])
                }
                jsonData = try Data(contentsOf: jsonURL)
            } else {
                jsonData = try Data(contentsOf: url)
            }

            defer { if let dir = bundleTempDir { try? FileManager.default.removeItem(at: dir) } }

            let result = try store.parseImportData(jsonData)
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

            if let tempDir = bundleTempDir {
                // バンドルから画像・ファイルをインポートし、ファイル名マッピングを作成
                var fileNameMapping: [String: String] = [:]
                let bundleImagesDir = tempDir.appendingPathComponent("images")
                let bundleFilesDir = tempDir.appendingPathComponent("files")

                for item in result.new {
                    switch item.content {
                    case .image(let meta):
                        let sourceURL = bundleImagesDir.appendingPathComponent(meta.fileName)
                        if FileManager.default.fileExists(atPath: sourceURL.path),
                           let newName = imageStore.importImage(from: sourceURL) {
                            fileNameMapping[meta.fileName] = newName
                        }
                    case .file(let meta):
                        let sourceURL = bundleFilesDir.appendingPathComponent(meta.fileName)
                        if FileManager.default.fileExists(atPath: sourceURL.path),
                           let newName = fileStore.importFile(from: sourceURL, fileExtension: meta.fileExtension) {
                            fileNameMapping[meta.fileName] = newName
                        }
                    case .text:
                        break
                    }
                }

                store.importItems(result.new, fileNameMapping: fileNameMapping)
            } else {
                store.importItems(result.new)
            }

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

        let hasMediaSnippets = store.items.contains {
            switch $0.content {
            case .image, .file: return true
            case .text: return false
            }
        }

        let savePanel = NSSavePanel()
        if hasMediaSnippets {
            savePanel.allowedContentTypes = [.zip]
            savePanel.nameFieldStringValue = "snippets.zip"
            savePanel.message = "スニペットをバンドル（ZIP）でエクスポートします"
        } else {
            savePanel.allowedContentTypes = [.json]
            savePanel.nameFieldStringValue = "snippets.json"
            savePanel.message = "スニペットのエクスポート先を選択してください"
        }

        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }

        do {
            if hasMediaSnippets {
                try exportBundle(to: url)
            } else {
                try store.exportToFile(url: url)
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "エクスポートに失敗しました"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// JSON + 画像/ファイルを ZIP バンドルにまとめてエクスポートする。
    private func exportBundle(to url: URL) throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FuzzyPaste-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // snippets.json を書き出し
        let jsonData = try store.exportData()
        try jsonData.write(to: tempDir.appendingPathComponent("snippets.json"), options: .atomic)

        // 画像・ファイルの実体をコピー
        let fm = FileManager.default
        let bundleImagesDir = tempDir.appendingPathComponent("images")
        let bundleFilesDir = tempDir.appendingPathComponent("files")
        try? fm.createDirectory(at: bundleImagesDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: bundleFilesDir, withIntermediateDirectories: true)

        for item in store.items {
            switch item.content {
            case .image(let meta):
                let src = imageStore.imageURL(for: meta.fileName)
                if fm.fileExists(atPath: src.path) {
                    try fm.copyItem(at: src, to: bundleImagesDir.appendingPathComponent(meta.fileName))
                }
            case .file(let meta):
                let src = fileStore.fileURL(for: meta.fileName)
                if fm.fileExists(atPath: src.path) {
                    try fm.copyItem(at: src, to: bundleFilesDir.appendingPathComponent(meta.fileName))
                }
            case .text:
                break
            }
        }

        // ditto で ZIP 作成
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-c", "-k", "--sequesterRsrc", tempDir.path, url.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "FuzzyPaste", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "ZIP ファイルの作成に失敗しました"])
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
