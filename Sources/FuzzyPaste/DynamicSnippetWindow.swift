import AppKit
import FuzzyPasteCore

/// 動的スニペットのプレースホルダーに値を入力するモーダルダイアログ。
/// 左ペイン: ヘッダー + 入力フィールド、右ペイン: リアルタイムプレビュー の2面構成。
/// 選択肢付きプレースホルダー `{{名前:A,B,C}}` はドロップダウンで表示する。
@MainActor
final class DynamicSnippetWindow: NSPanel {
    private let snippet: SnippetItem
    private let placeholders: [PlaceholderParser.Placeholder]
    /// 自由入力フィールド（名前 → NSTextField）
    private var inputFields: [String: NSTextField] = [:]
    /// 選択肢ドロップダウン（名前 → NSPopUpButton）
    private var popUpButtons: [String: NSPopUpButton] = [:]
    /// 全入力コントロールを出現順で保持（フォーカス制御用）
    private var orderedControls: [NSView] = []
    /// コントロール → 外枠コンテナ（フォーカスリング表示用）
    private var controlContainers: [ObjectIdentifier: NSView] = [:]
    private let previewTextView = NSTextView()

    var onPaste: ((String) -> Void)?
    var onCopy: ((String) -> Void)?
    var onCancel: (() -> Void)?

    // MARK: - デザイン定数

    private enum Design {
        static let windowWidth: CGFloat = 840
        static let windowHeight: CGFloat = 560
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

    init(snippet: SnippetItem, placeholders: [PlaceholderParser.Placeholder]) {
        self.snippet = snippet
        self.placeholders = placeholders
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

    /// フィールドエディタの undo を有効にする。
    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        let editor = super.fieldEditor(createFlag, for: object)
        if let textView = editor as? NSTextView {
            textView.allowsUndo = true
        }
        return editor
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

        for placeholder in placeholders {
            let group = makeFieldGroup(placeholder: placeholder)
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

        let subtitleLabel = NSTextField(labelWithString: "\(placeholders.count) 個の入力項目")
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

    /// プレースホルダーの種類に応じて NSTextField（自由入力）または NSPopUpButton（選択肢）を生成する。
    private func makeFieldGroup(placeholder: PlaceholderParser.Placeholder) -> NSView {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = Design.fieldSpacing
        group.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: placeholder.name)
        label.font = .systemFont(ofSize: Design.labelFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        group.addArrangedSubview(label)

        if let options = placeholder.options {
            // 選択肢付き → テキストフィールドと統一されたスタイルのドロップダウン
            let fieldContainer = NSView()
            fieldContainer.wantsLayer = true
            fieldContainer.layer?.cornerRadius = Design.fieldCornerRadius
            fieldContainer.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
            fieldContainer.layer?.borderWidth = 0.5
            fieldContainer.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
            fieldContainer.translatesAutoresizingMaskIntoConstraints = false

            let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
            popUp.addItems(withTitles: options)
            popUp.font = .systemFont(ofSize: Design.fieldFontSize)
            popUp.isBordered = false
            (popUp.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
            popUp.translatesAutoresizingMaskIntoConstraints = false
            popUp.focusRingType = .none
            popUp.target = self
            popUp.action = #selector(popUpSelectionChanged(_:))
            fieldContainer.addSubview(popUp)

            NSLayoutConstraint.activate([
                popUp.leadingAnchor.constraint(equalTo: fieldContainer.leadingAnchor, constant: 6),
                popUp.trailingAnchor.constraint(equalTo: fieldContainer.trailingAnchor, constant: -6),
                popUp.centerYAnchor.constraint(equalTo: fieldContainer.centerYAnchor),
            ])

            group.addArrangedSubview(fieldContainer)
            fieldContainer.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
            fieldContainer.heightAnchor.constraint(equalToConstant: Design.fieldHeight).isActive = true
            popUpButtons[placeholder.name] = popUp
            orderedControls.append(popUp)
            controlContainers[ObjectIdentifier(popUp)] = fieldContainer
        } else {
            // 自由入力 → NSTextField
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
            (field.cell as? NSTextFieldCell)?.allowsUndo = true
            field.placeholderString = "\(placeholder.name) を入力..."
            field.delegate = self
            field.target = self
            field.action = #selector(fieldReturnPressed(_:))
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

            inputFields[placeholder.name] = field
            orderedControls.append(field)
            controlContainers[ObjectIdentifier(field)] = fieldContainer

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(textDidChangeNotification(_:)),
                name: NSControl.textDidChangeNotification,
                object: field
            )
        }

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

    @objc private func popUpSelectionChanged(_ sender: NSPopUpButton) {
        updatePreview()
    }

    private func updatePreview() {
        let values = currentValues()
        let resolved = PlaceholderParser.resolve(template: snippet.text ?? "", values: values)
        previewTextView.string = resolved
    }

    /// 自由入力フィールドと選択肢ドロップダウンの両方から現在の値を収集する。
    private func currentValues() -> [String: String] {
        var values: [String: String] = [:]
        for (name, field) in inputFields {
            let text = field.stringValue
            if !text.isEmpty {
                values[name] = text
            }
        }
        for (name, popUp) in popUpButtons {
            if let title = popUp.selectedItem?.title {
                values[name] = title
            }
        }
        return values
    }

    private func resolvedText() -> String {
        PlaceholderParser.resolve(template: snippet.text ?? "", values: currentValues())
    }

    /// Enter キーで呼ばれる。全フィールド入力済みならペースト、そうでなければ次へ移動。
    @objc private func fieldReturnPressed(_ sender: NSTextField) {
        if allFieldsFilled() {
            handlePaste()
        } else {
            focusNextControl(after: sender)
        }
    }

    /// 指定コントロールの次の orderedControls にフォーカスを移す（ループする）。
    private func focusNextControl(after current: NSView) {
        guard let idx = orderedControls.firstIndex(of: current) else { return }
        let nextIdx = (idx + 1) % orderedControls.count
        _ = makeFirstResponder(orderedControls[nextIdx])
    }

    /// すべての自由入力フィールドが入力済みかどうかを返す。
    private func allFieldsFilled() -> Bool {
        inputFields.values.allSatisfy { !$0.stringValue.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    @objc private func handlePaste() {
        guard allFieldsFilled() else {
            focusNextEmptyField()
            return
        }
        let text = resolvedText()
        dismiss()
        onPaste?(text)
    }

    /// 最初の未入力フリーテキストフィールドにフォーカスを移す。
    private func focusNextEmptyField() {
        for control in orderedControls {
            if let field = control as? NSTextField,
               field.isEditable,
               field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
                _ = makeFirstResponder(field)
                return
            }
        }
    }

    private func handleCopy() {
        guard allFieldsFilled() else {
            focusNextEmptyField()
            return
        }
        let text = resolvedText()
        dismiss()
        onCopy?(text)
    }

    @objc private func handleCancel() {
        dismiss()
        onCancel?()
    }

    // MARK: - Focus Ring

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let result = super.makeFirstResponder(responder)
        updateFocusRing()
        return result
    }

    private func updateFocusRing() {
        let focusedControl = focusedOrderedControl()
        for control in orderedControls {
            let id = ObjectIdentifier(control)
            guard let container = controlContainers[id] else { continue }
            let isFocused = (control === focusedControl)
            container.layer?.borderColor = isFocused
                ? NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
                : NSColor.separatorColor.withAlphaComponent(0.3).cgColor
            container.layer?.borderWidth = isFocused ? 1.5 : 0.5
        }
    }

    /// 現在フォーカスされている orderedControls 内のコントロールを返す。
    private func focusedOrderedControl() -> NSView? {
        let responder = firstResponder
        // テキストフィールド編集中は field editor (NSTextView) が firstResponder
        if let textView = responder as? NSTextView,
           let field = textView.delegate as? NSTextField,
           orderedControls.contains(field) {
            return field
        }
        if let view = responder as? NSView, orderedControls.contains(view) {
            return view
        }
        return nil
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
        // 最初の入力コントロール（種類問わず）にフォーカス
        if let first = orderedControls.first {
            _ = makeFirstResponder(first)
        }
    }

    private func dismiss() {
        NotificationCenter.default.removeObserver(self)
        orderOut(nil)
    }

    // MARK: - Key Handling

    private enum KeyCode {
        static let z: UInt16 = 6
        static let a: UInt16 = 0
        static let c: UInt16 = 8
        static let w: UInt16 = 13
        static let returnKey: UInt16 = 36
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Cmd+キー: フィールドエディタへの委譲 or 独自ハンドリング
            if flags == .command {
                switch event.keyCode {
                case KeyCode.z:
                    if let textView = firstResponder as? NSTextView,
                       let undoManager = textView.undoManager,
                       undoManager.canUndo {
                        undoManager.undo()
                        return
                    }
                case KeyCode.a:
                    if firstResponder?.tryToPerform(#selector(NSText.selectAll(_:)), with: nil) == true {
                        return
                    }
                case KeyCode.c:
                    handleCopy()
                    return
                case KeyCode.w:
                    handleCancel()
                    return
                default:
                    break
                }
            }
            // Cmd+Shift+Z → Redo
            if flags == [.command, .shift] && event.keyCode == KeyCode.z {
                if let textView = firstResponder as? NSTextView,
                   let undoManager = textView.undoManager,
                   undoManager.canRedo {
                    undoManager.redo()
                    return
                }
            }
            // Return キー（テキストフィールド以外にフォーカス中）→ ペースト
            if flags.isEmpty && event.keyCode == KeyCode.returnKey && !(firstResponder is NSText) {
                handlePaste()
                return
            }
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        handleCancel()
    }
}

// MARK: - NSControlTextEditingDelegate (Tab / Shift-Tab でフォーカス移動)

extension DynamicSnippetWindow: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            focusNextControl(after: control)
            return true
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            guard let idx = orderedControls.firstIndex(of: control) else { return false }
            let prevIdx = (idx - 1 + orderedControls.count) % orderedControls.count
            _ = makeFirstResponder(orderedControls[prevIdx])
            return true
        }
        return false
    }
}

// MARK: - FlippedView

/// NSScrollView 内で上からレイアウトするための flipped ビュー。
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
