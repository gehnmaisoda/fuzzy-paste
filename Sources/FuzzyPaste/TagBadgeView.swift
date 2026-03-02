import AppKit

/// 角丸四角形のタグバッジ。オプションの×ボタン付き。
@MainActor
final class TagBadge: NSView {
    private enum Const {
        static let hPad: CGFloat = 6
        static let vPad: CGFloat = 2
        static let cornerRadius: CGFloat = 4
        static let fontSize: CGFloat = 11
        static let closeSize: CGFloat = 12
        static let closeGap: CGFloat = 2
    }

    private let label = NSTextField(labelWithString: "")
    private var closeButton: NSButton?
    var onRemove: (() -> Void)?

    init(text: String, showClose: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Const.cornerRadius
        layer?.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.15).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: Const.fontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.stringValue = text
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(label)

        var constraints = [
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Const.hPad),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: label.intrinsicContentSize.height + Const.vPad * 2),
        ]

        if showClose {
            let btn = NSButton(frame: .zero)
            btn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "削除")
            btn.imageScaling = .scaleProportionallyDown
            btn.isBordered = false
            btn.target = self
            btn.action = #selector(closeTapped)
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.contentTintColor = .tertiaryLabelColor
            addSubview(btn)
            closeButton = btn

            constraints += [
                btn.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: Const.closeGap),
                btn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Const.hPad / 2),
                btn.centerYAnchor.constraint(equalTo: centerYAnchor),
                btn.widthAnchor.constraint(equalToConstant: Const.closeSize),
                btn.heightAnchor.constraint(equalToConstant: Const.closeSize),
            ]
        } else {
            constraints.append(
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Const.hPad)
            )
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func closeTapped() { onRemove?() }
}

/// タグバッジをフローレイアウトで並べ、末尾に入力フィールドを配置するコンテナ。
/// 角丸枠線で囲んだ input 風の見た目。タグ補完（サジェスト）対応。
@MainActor
final class TagFlowContainer: NSView, NSTextFieldDelegate {
    private enum Const {
        static let hGap: CGFloat = 4
        static let vGap: CGFloat = 4
        static let inset: CGFloat = 6
        static let inputMinWidth: CGFloat = 80
        static let fontSize: CGFloat = 11
        static let cornerRadius: CGFloat = 6
        static let borderWidth: CGFloat = 0.5
    }

    private let inputField = NSTextField()
    private let suggestionLabel = NSTextField(labelWithString: "")
    private var badgeViews: [TagBadge] = []
    var onTagsChanged: (([String]) -> Void)?

    /// 補完候補を提供するための全タグリスト。外部から設定する。
    var allKnownTags: [String] = []
    private var suggestedTag: String?

    var tags: [String] = [] {
        didSet { rebuildBadges() }
    }

    /// 上から下へのレイアウトに必要。NSTextField のテキスト描画位置もこれで揃う。
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Const.cornerRadius
        layer?.borderWidth = Const.borderWidth
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        setupInputField()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func setupInputField() {
        inputField.font = .systemFont(ofSize: Const.fontSize)
        inputField.placeholderString = "タグを追加..."
        inputField.isBordered = false
        inputField.drawsBackground = false
        inputField.focusRingType = .none
        inputField.delegate = self
        inputField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inputField)

        suggestionLabel.font = .systemFont(ofSize: Const.fontSize)
        suggestionLabel.textColor = .tertiaryLabelColor
        suggestionLabel.isHidden = true
        suggestionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(suggestionLabel)
    }

    private func rebuildBadges() {
        for badge in badgeViews { badge.removeFromSuperview() }
        badgeViews.removeAll()

        for tag in tags {
            let badge = TagBadge(text: tag, showClose: true)
            let tagToRemove = tag
            badge.onRemove = { [weak self] in
                guard let self else { return }
                self.tags.removeAll { $0 == tagToRemove }
                self.onTagsChanged?(self.tags)
            }
            addSubview(badge)
            badgeViews.append(badge)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()

        let maxWidth = bounds.width - Const.inset * 2
        var x: CGFloat = Const.inset
        var y: CGFloat = Const.inset
        var lineHeight: CGFloat = 0

        // バッジの高さを取得（バッジがあれば使う、なければ inputField 基準）
        let badgeHeight: CGFloat = badgeViews.first?.fittingSize.height ?? 0

        for badge in badgeViews {
            let size = badge.fittingSize
            if x - Const.inset + size.width > maxWidth && x > Const.inset {
                x = Const.inset
                y += lineHeight + Const.vGap
                lineHeight = 0
            }
            badge.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width + Const.hGap
            lineHeight = max(lineHeight, size.height)
        }

        // 入力フィールドを最後に配置（バッジと同じ高さにして揃える）
        let inputWidth = max(Const.inputMinWidth, bounds.width - x - Const.inset)
        let inputHeight = max(badgeHeight, 18 as CGFloat)
        if x - Const.inset + Const.inputMinWidth > maxWidth && x > Const.inset {
            x = Const.inset
            y += lineHeight + Const.vGap
            lineHeight = 0
        }
        // NSTextField は内部に上パディングがあるため、バッジのテキストと揃えるために 2pt 下げる
        let inputY = y + 2
        inputField.frame = NSRect(x: x, y: inputY, width: inputWidth, height: inputHeight)
        suggestionLabel.frame = NSRect(x: x, y: inputY, width: inputWidth, height: inputHeight)
        lineHeight = max(lineHeight, inputHeight)

        let totalHeight = y + lineHeight + Const.inset
        if abs(intrinsicHeight - totalHeight) > 1 {
            intrinsicHeight = totalHeight
            invalidateIntrinsicContentSize()
        }
    }

    private var intrinsicHeight: CGFloat = 30

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: intrinsicHeight)
    }

    // MARK: - Suggestion

    private func updateSuggestion() {
        let input = inputField.stringValue
        guard !input.isEmpty, !allKnownTags.isEmpty else {
            suggestedTag = nil
            suggestionLabel.isHidden = true
            return
        }
        let lower = input.lowercased()
        if let match = allKnownTags.first(where: {
            $0.lowercased().hasPrefix(lower) && !tags.contains($0)
        }) {
            suggestedTag = match
            suggestionLabel.stringValue = match
            suggestionLabel.isHidden = false
        } else {
            suggestedTag = nil
            suggestionLabel.isHidden = true
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        updateSuggestion()
    }

    /// フォーカスが外れたら入力中のテキストをタグとして確定する
    func controlTextDidEndEditing(_ obj: Notification) {
        commitTag()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            commitTag()
            return true
        }
        // Tab: サジェストがあれば補完確定
        if commandSelector == #selector(insertTab(_:)) {
            if let tag = suggestedTag {
                inputField.stringValue = tag
                commitTag()
                return true
            }
        }
        // Delete キーでフィールドが空なら最後のタグを削除
        if commandSelector == #selector(deleteBackward(_:)) {
            if inputField.stringValue.isEmpty && !tags.isEmpty {
                tags.removeLast()
                onTagsChanged?(tags)
                return true
            }
        }
        return false
    }

    private func commitTag() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty, !tags.contains(text) {
            tags.append(text)
            onTagsChanged?(tags)
        }
        inputField.stringValue = ""
        suggestedTag = nil
        suggestionLabel.isHidden = true
    }
}
