import AppKit
import FuzzyPasteCore

/// 動的スニペットのプレースホルダーに値を入力するモーダルダイアログ。
/// 左ペイン: ヘッダー + 入力フィールド、右ペイン: リアルタイムプレビュー の2面構成。
@MainActor
final class DynamicSnippetWindow: NSPanel {
    private let snippet: SnippetItem
    private let placeholderNames: [String]
    private var inputFields: [String: NSTextField] = [:]
    private let previewTextView = NSTextView()

    var onPaste: ((String) -> Void)?
    var onCopy: ((String) -> Void)?
    var onCancel: (() -> Void)?

    // MARK: - デザイン定数

    private enum Design {
        static let windowWidth: CGFloat = 720
        static let windowHeight: CGFloat = 420
        static let cornerRadius: CGFloat = 14
        static let padding: CGFloat = 24
        static let sectionSpacing: CGFloat = 18
        static let fieldSpacing: CGFloat = 6
        static let fieldCornerRadius: CGFloat = 8
        static let fieldHeight: CGFloat = 36
        static let hintBarHeight: CGFloat = 36
        static let hintFontSize: CGFloat = 11
        static let titleFontSize: CGFloat = 16
        static let labelFontSize: CGFloat = 12
        static let fieldFontSize: CGFloat = 14
        static let previewFontSize: CGFloat = 13
        static let fieldGroupSpacing: CGFloat = 14
        static let dividerWidth: CGFloat = 0.5
        static let panelSplitRatio: CGFloat = 0.45 // 左ペインの幅割合
    }

    init(snippet: SnippetItem, placeholderNames: [String]) {
        self.snippet = snippet
        self.placeholderNames = placeholderNames
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Design.windowWidth, height: Design.windowHeight),
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
        isOpaque = false
        backgroundColor = .clear
        setupUI()
    }

    // MARK: - UI

    private func setupUI() {
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .sheet
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = Design.cornerRadius
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 0.5
        visualEffect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        contentView = visualEffect

        // ヒントバー（最下部）
        let hintBar = makeHintBar()
        visualEffect.addSubview(hintBar)

        // 左右2ペインの親コンテナ
        let splitContainer = NSView()
        splitContainer.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(splitContainer)

        // 左ペイン: 入力
        let leftPane = makeLeftPane()
        splitContainer.addSubview(leftPane)

        // 縦ディバイダー
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        splitContainer.addSubview(divider)

        // 右ペイン: プレビュー
        let rightPane = makeRightPane()
        splitContainer.addSubview(rightPane)

        NSLayoutConstraint.activate([
            // splitContainer はヒントバーの上に配置
            splitContainer.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            splitContainer.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            splitContainer.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            splitContainer.bottomAnchor.constraint(equalTo: hintBar.topAnchor),

            // ヒントバー
            hintBar.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hintBar.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            hintBar.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            hintBar.heightAnchor.constraint(equalToConstant: Design.hintBarHeight),

            // 左ペイン
            leftPane.topAnchor.constraint(equalTo: splitContainer.topAnchor),
            leftPane.leadingAnchor.constraint(equalTo: splitContainer.leadingAnchor),
            leftPane.bottomAnchor.constraint(equalTo: splitContainer.bottomAnchor),
            leftPane.widthAnchor.constraint(equalTo: splitContainer.widthAnchor, multiplier: Design.panelSplitRatio),

            // ディバイダー
            divider.topAnchor.constraint(equalTo: splitContainer.topAnchor, constant: Design.padding),
            divider.bottomAnchor.constraint(equalTo: splitContainer.bottomAnchor, constant: -Design.padding),
            divider.leadingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: Design.dividerWidth),

            // 右ペイン
            rightPane.topAnchor.constraint(equalTo: splitContainer.topAnchor),
            rightPane.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            rightPane.trailingAnchor.constraint(equalTo: splitContainer.trailingAnchor),
            rightPane.bottomAnchor.constraint(equalTo: splitContainer.bottomAnchor),
        ])

        updatePreview()
    }

    // MARK: - Left Pane (ヘッダー + 入力フィールド)

    private func makeLeftPane() -> NSView {
        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false

        // スクロール対応（フィールドが多い場合）
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(scrollView)

        // FlippedView で上からレイアウト
        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: pane.topAnchor, constant: Design.padding),
            scrollView.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: pane.bottomAnchor),

            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        // コンテンツスタック
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.sectionSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: Design.padding),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -Design.padding),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor, constant: -Design.padding),
        ])

        // ヘッダー
        let header = makeHeaderSection()
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // 入力フィールド群
        let fieldsStack = NSStackView()
        fieldsStack.orientation = .vertical
        fieldsStack.alignment = .leading
        fieldsStack.spacing = Design.fieldGroupSpacing
        fieldsStack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(fieldsStack)
        fieldsStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        for name in placeholderNames {
            let group = makeFieldGroup(name: name)
            fieldsStack.addArrangedSubview(group)
            group.widthAnchor.constraint(equalTo: fieldsStack.widthAnchor).isActive = true
        }

        return pane
    }

    // MARK: - Right Pane (プレビュー)

    private func makeRightPane() -> NSView {
        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "プレビュー")
        label.font = .systemFont(ofSize: Design.labelFontSize, weight: .medium)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(label)

        // プレビューコンテナ
        let previewContainer = NSView()
        previewContainer.wantsLayer = true
        previewContainer.layer?.cornerRadius = Design.fieldCornerRadius
        previewContainer.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.03).cgColor
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(previewContainer)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        previewTextView.isEditable = false
        previewTextView.isSelectable = true
        previewTextView.font = .monospacedSystemFont(ofSize: Design.previewFontSize, weight: .regular)
        previewTextView.textColor = .labelColor
        previewTextView.drawsBackground = false
        previewTextView.textContainerInset = NSSize(width: 8, height: 8)
        previewTextView.isVerticallyResizable = true
        previewTextView.isHorizontallyResizable = false
        previewTextView.autoresizingMask = [.width]
        previewTextView.textContainer?.widthTracksTextView = true

        scrollView.documentView = previewTextView
        previewContainer.addSubview(scrollView)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: pane.topAnchor, constant: Design.padding),
            label.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: Design.padding),

            previewContainer.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            previewContainer.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: Design.padding),
            previewContainer.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -Design.padding),
            previewContainer.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -Design.padding),

            scrollView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
        ])

        return pane
    }

    // MARK: - UI Components

    private func makeHeaderSection() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: nil)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        container.addSubview(icon)

        let titleLabel = NSTextField(labelWithString: snippet.title)
        titleLabel.font = .systemFont(ofSize: Design.titleFontSize, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: "\(placeholderNames.count) 個の入力項目")
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            icon.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    private func makeFieldGroup(name: String) -> NSView {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = Design.fieldSpacing
        group.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: Design.labelFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        group.addArrangedSubview(label)

        let fieldContainer = NSView()
        fieldContainer.wantsLayer = true
        fieldContainer.layer?.cornerRadius = Design.fieldCornerRadius
        fieldContainer.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
        fieldContainer.layer?.borderWidth = 0.5
        fieldContainer.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        fieldContainer.translatesAutoresizingMaskIntoConstraints = false

        let field = NSTextField()
        field.font = .systemFont(ofSize: Design.fieldFontSize)
        field.focusRingType = .none
        field.isBordered = false
        field.drawsBackground = false
        field.placeholderString = "\(name) を入力..."
        field.target = self
        field.action = #selector(handlePaste)
        field.translatesAutoresizingMaskIntoConstraints = false
        fieldContainer.addSubview(field)

        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: fieldContainer.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: fieldContainer.trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: fieldContainer.centerYAnchor),
        ])

        group.addArrangedSubview(fieldContainer)
        fieldContainer.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        fieldContainer.heightAnchor.constraint(equalToConstant: Design.fieldHeight).isActive = true

        inputFields[name] = field

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChangeNotification(_:)),
            name: NSControl.textDidChangeNotification,
            object: field
        )

        return group
    }

    // MARK: - Hint Bar (SearchWindow 統一スタイル)

    private func makeHintBar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.03).cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(divider)

        let hintStack = NSStackView()
        hintStack.orientation = .horizontal
        hintStack.spacing = 12
        hintStack.alignment = .centerY
        hintStack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(hintStack)

        let actions: [(key: String, label: String)] = [
            ("⏎", "ペースト"),
            ("⌘\u{2009}C", "コピー"),
            ("esc", "閉じる"),
        ]
        for action in actions {
            hintStack.addArrangedSubview(makeActionChip(keycap: action.key, label: action.label))
        }

        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: bar.topAnchor),
            divider.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: Design.padding),
            divider.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -Design.padding),
            divider.heightAnchor.constraint(equalToConstant: 0.5),

            hintStack.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            hintStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])

        return bar
    }

    private func makeActionChip(keycap: String, label: String) -> NSView {
        let chip = NSView()
        chip.translatesAutoresizingMaskIntoConstraints = false

        let key = makeKeycap(text: keycap)
        chip.addSubview(key)

        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: Design.hintFontSize)
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

    private func makeKeycap(text: String) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 5
        container.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: Design.hintFontSize - 1, weight: .medium)
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

    // MARK: - Actions

    @objc private func textDidChangeNotification(_ notification: Notification) {
        updatePreview()
    }

    private func updatePreview() {
        let values = currentValues()
        let resolved = PlaceholderParser.resolve(template: snippet.content, values: values)
        previewTextView.string = resolved
    }

    private func currentValues() -> [String: String] {
        var values: [String: String] = [:]
        for (name, field) in inputFields {
            let text = field.stringValue
            if !text.isEmpty {
                values[name] = text
            }
        }
        return values
    }

    private func resolvedText() -> String {
        PlaceholderParser.resolve(template: snippet.content, values: currentValues())
    }

    @objc private func handlePaste() {
        let text = resolvedText()
        dismiss()
        onPaste?(text)
    }

    private func handleCopy() {
        let text = resolvedText()
        dismiss()
        onCopy?(text)
    }

    @objc private func handleCancel() {
        dismiss()
        onCancel?()
    }

    // MARK: - Show / Dismiss

    func showCentered() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let windowSize = frame.size
        let x = screenFrame.midX - windowSize.width / 2
        let y = screenFrame.midY - windowSize.height / 2
        setFrameOrigin(NSPoint(x: x, y: y))
        makeKeyAndOrderFront(nil)
        if let firstName = placeholderNames.first, let field = inputFields[firstName] {
            makeFirstResponder(field)
        }
    }

    private func dismiss() {
        NotificationCenter.default.removeObserver(self)
        orderOut(nil)
    }

    // MARK: - Key Handling

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""

        if flags == .command {
            switch chars {
            case "c":
                handleCopy()
                return true
            case "w":
                handleCancel()
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        handleCancel()
    }
}

// MARK: - FlippedView

/// NSScrollView 内で上からレイアウトするための flipped ビュー。
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
