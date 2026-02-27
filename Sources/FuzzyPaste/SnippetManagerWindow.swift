import AppKit

/// クリックを透過するプレースホルダーラベル。
/// テキストビューの上に重ねてもクリックがテキストビューに到達する。
@MainActor
private final class PlaceholderLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// スニペット管理ウィンドウ。
/// メニューバーの「スニペット管理...」から開く。
///
/// 2カラムレイアウト:
/// ┌────────────────────────────────────────────────────────────────┐
/// │  ★ スニペット管理                                              │
/// │  登録したスニペットは検索結果に表示されます                        │
/// │  ┌──────────────────┐  ┌──────────────────────────────────┐   │
/// │  │ ★ メールテンプレ  │  │ スニペット名                      │   │
/// │  │   user@exampl... │  │ ┌──────────────────────────────┐ │   │
/// │  ├──────────────────┤  │ │ メールテンプレート            │ │   │
/// │  │ ★ 住所           │  │ └──────────────────────────────┘ │   │
/// │  │   東京都渋谷区... │  │ 内容                             │   │
/// │  └──────────────────┘  │ ┌──────────────────────────────┐ │   │
/// │  [＋ 追加]      [削除]  │ │ user@example.com is my ...   │ │   │
/// │                        │ └──────────────────────────────┘ │   │
/// │                        └──────────────────────────────────┘   │
/// └────────────────────────────────────────────────────────────────┘
@MainActor
final class SnippetManagerWindow: NSWindow, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate {

    // MARK: - 定数

    private enum Layout {
        static let windowSize = NSSize(width: 700, height: 480)
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
        static let inputBorderWidth: CGFloat = 0.5
        static let inputPadding: CGFloat = 8
    }

    private enum KeyCode {
        static let w: UInt16 = 13
        static let n: UInt16 = 45
        static let a: UInt16 = 0
    }

    /// セル内の 2 つの NSTextField を識別するタグ
    private enum CellTag {
        static let title = 1
        static let preview = 2
    }

    // MARK: - UI パーツ

    private let tableView = NSTableView()
    private let tableScrollView = NSScrollView()
    private let emptyStateLabel = NSTextField(labelWithString: "")
    private let titleField = NSTextField()
    private let contentTextView = NSTextView(frame: .zero)
    private let contentScrollView = NSScrollView()
    private let contentPlaceholder = PlaceholderLabel(labelWithString: "内容を入力...")
    private let addButton = NSButton(frame: .zero)
    private let removeButton = NSButton(frame: .zero)

    // MARK: - 状態

    private let store: SnippetStore
    /// フィールド更新中のフラグ。変更通知の再帰を防ぐ。
    private var isUpdatingFields = false

    // MARK: - 初期化

    init(store: SnippetStore) {
        self.store = store
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
        let titleStr = NSMutableAttributedString()
        titleStr.append(NSAttributedString(string: "★ ", attributes: [
            .foregroundColor: NSColor.systemOrange,
            .font: NSFont.systemFont(ofSize: Layout.headerFontSize, weight: .bold),
        ]))
        titleStr.append(NSAttributedString(string: "スニペット管理", attributes: [
            .font: NSFont.systemFont(ofSize: Layout.headerFontSize, weight: .bold),
        ]))
        let titleLabel = NSTextField(labelWithAttributedString: titleStr)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        let subtitle = NSTextField(labelWithString: "登録したスニペットは検索結果に表示されます")
        subtitle.font = .systemFont(ofSize: Layout.subtitleFontSize, weight: .light)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subtitle)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: Layout.padding + 8),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Layout.padding),

            subtitle.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Layout.padding),
        ])
        return subtitle
    }

    // MARK: 左パネル（リスト + ボタン）

    private func buildLeftPanel(in panel: NSView) {
        // ── テーブルの角丸ラッパー ──
        let tableWrapper = NSView()
        tableWrapper.wantsLayer = true
        tableWrapper.layer?.cornerRadius = 8
        tableWrapper.layer?.borderWidth = Layout.inputBorderWidth
        tableWrapper.layer?.borderColor = NSColor.separatorColor.cgColor
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
        tableView.selectionHighlightStyle = .regular
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.style = .inset

        tableScrollView.documentView = tableView
        tableScrollView.hasVerticalScroller = true
        tableScrollView.scrollerStyle = .overlay
        tableScrollView.drawsBackground = false
        tableScrollView.borderType = .noBorder
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
        tableWrapper.addSubview(tableScrollView)

        // ── 空状態メッセージ ──
        let emptyStr = NSMutableAttributedString()
        let pStyle = NSMutableParagraphStyle()
        pStyle.alignment = .center
        pStyle.lineSpacing = 4

        emptyStr.append(NSAttributedString(string: "★\n", attributes: [
            .foregroundColor: NSColor.systemOrange.withAlphaComponent(0.25),
            .font: NSFont.systemFont(ofSize: 36, weight: .light),
            .paragraphStyle: pStyle,
        ]))
        emptyStr.append(NSAttributedString(string: "スニペットはまだありません\n", attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor,
            .font: NSFont.systemFont(ofSize: 12, weight: .light),
            .paragraphStyle: pStyle,
        ]))
        emptyStr.append(NSAttributedString(string: "「＋ 追加」で登録", attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor,
            .font: NSFont.systemFont(ofSize: 11),
            .paragraphStyle: pStyle,
        ]))

        emptyStateLabel.attributedStringValue = emptyStr
        emptyStateLabel.alignment = .center
        emptyStateLabel.maximumNumberOfLines = 0
        emptyStateLabel.lineBreakMode = .byWordWrapping
        emptyStateLabel.isHidden = true
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(emptyStateLabel)

        // ── ボタン ──
        addButton.title = "＋ 追加"
        addButton.bezelStyle = .rounded
        addButton.controlSize = .regular
        addButton.font = .systemFont(ofSize: 12, weight: .medium)
        addButton.target = self
        addButton.action = #selector(addClicked)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(addButton)

        removeButton.title = "削除"
        removeButton.bezelStyle = .rounded
        removeButton.controlSize = .regular
        removeButton.font = .systemFont(ofSize: 12)
        removeButton.target = self
        removeButton.action = #selector(removeClicked)
        removeButton.isEnabled = false
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(removeButton)

        NSLayoutConstraint.activate([
            tableWrapper.topAnchor.constraint(equalTo: panel.topAnchor),
            tableWrapper.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            tableWrapper.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            tableWrapper.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -8),

            tableScrollView.topAnchor.constraint(equalTo: tableWrapper.topAnchor),
            tableScrollView.leadingAnchor.constraint(equalTo: tableWrapper.leadingAnchor),
            tableScrollView.trailingAnchor.constraint(equalTo: tableWrapper.trailingAnchor),
            tableScrollView.bottomAnchor.constraint(equalTo: tableWrapper.bottomAnchor),

            emptyStateLabel.centerXAnchor.constraint(equalTo: tableWrapper.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: tableWrapper.centerYAnchor),
            emptyStateLabel.widthAnchor.constraint(lessThanOrEqualTo: tableWrapper.widthAnchor, constant: -16),

            addButton.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            addButton.bottomAnchor.constraint(equalTo: panel.bottomAnchor),

            removeButton.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            removeButton.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
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

        // ── 内容 ──
        let contentLabel = makeLabel("内容")
        panel.addSubview(contentLabel)

        let contentWrapper = makeStyledWrapper()
        contentWrapper.layer?.masksToBounds = true
        panel.addSubview(contentWrapper)

        // プレースホルダー（スクロールビューの下に配置し透過背景で見えるようにする）
        contentPlaceholder.font = .monospacedSystemFont(ofSize: Layout.fieldFontSize, weight: .regular)
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

            contentLabel.topAnchor.constraint(equalTo: titleWrapper.bottomAnchor, constant: Layout.sectionSpacing),
            contentLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor),

            contentWrapper.topAnchor.constraint(equalTo: contentLabel.bottomAnchor, constant: Layout.spacing),
            contentWrapper.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            contentWrapper.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            contentWrapper.bottomAnchor.constraint(equalTo: panel.bottomAnchor),

            // プレースホルダー位置: テキストビューの textContainerInset + lineFragmentPadding に合わせる
            contentPlaceholder.topAnchor.constraint(equalTo: contentWrapper.topAnchor, constant: 8),
            contentPlaceholder.leadingAnchor.constraint(equalTo: contentWrapper.leadingAnchor, constant: 8),

            contentScrollView.topAnchor.constraint(equalTo: contentWrapper.topAnchor),
            contentScrollView.leadingAnchor.constraint(equalTo: contentWrapper.leadingAnchor),
            contentScrollView.trailingAnchor.constraint(equalTo: contentWrapper.trailingAnchor),
            contentScrollView.bottomAnchor.constraint(equalTo: contentWrapper.bottomAnchor),
        ])
    }

    // MARK: - ヘルパー

    /// 角丸 + 細い枠線 + 薄い背景色のスタイル付きコンテナ
    private func makeStyledWrapper() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = Layout.inputCornerRadius
        view.layer?.borderWidth = Layout.inputBorderWidth
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    /// セクションラベルを生成するヘルパー
    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: Layout.labelFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
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
              let previewTF = cell.viewWithTag(CellTag.preview) as? NSTextField else {
            return cell
        }

        let item = store.items[row]

        // ── 1行目: ★ タイトル ──
        let titleStr = NSMutableAttributedString()
        titleStr.append(NSAttributedString(string: "★ ", attributes: [
            .foregroundColor: NSColor.systemOrange.withAlphaComponent(0.8),
            .font: NSFont.systemFont(ofSize: Layout.cellTitleFontSize, weight: .medium),
        ]))
        let name = item.title.isEmpty ? "名称未設定" : item.title
        titleStr.append(NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: Layout.cellTitleFontSize, weight: .medium),
            .foregroundColor: item.title.isEmpty ? NSColor.tertiaryLabelColor : NSColor.labelColor,
        ]))
        titleTF.attributedStringValue = titleStr

        // ── 2行目: 内容プレビュー ──
        if item.content.isEmpty {
            previewTF.stringValue = "（内容なし）"
            previewTF.textColor = .tertiaryLabelColor
        } else {
            previewTF.stringValue = item.content
                .components(separatedBy: .newlines)
                .joined(separator: " ")
            previewTF.textColor = .secondaryLabelColor
        }

        return cell
    }

    /// 2行セルを組み立てる
    private func makeSnippetCell(identifier: NSUserInterfaceItemIdentifier) -> NSView {
        let view = NSView()
        view.identifier = identifier

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
            titleTF.topAnchor.constraint(equalTo: view.topAnchor, constant: 7),
            titleTF.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            titleTF.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            previewTF.topAnchor.constraint(equalTo: titleTF.bottomAnchor, constant: 1),
            previewTF.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            previewTF.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
        ])
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateEditFields()
    }

    // MARK: - 編集フィールド更新

    private func updateEditFields() {
        let row = tableView.selectedRow
        isUpdatingFields = true
        if row >= 0 && row < store.items.count {
            let item = store.items[row]
            titleField.stringValue = item.title
            contentTextView.string = item.content
            titleField.isEnabled = true
            contentTextView.isEditable = true
            contentTextView.isSelectable = true
            removeButton.isEnabled = true
            contentPlaceholder.isHidden = !item.content.isEmpty
        } else {
            titleField.stringValue = ""
            contentTextView.string = ""
            titleField.isEnabled = false
            contentTextView.isEditable = false
            contentTextView.isSelectable = false
            removeButton.isEnabled = false
            contentPlaceholder.isHidden = true
        }
        isUpdatingFields = false
    }

    private func saveCurrentEdits() {
        let row = tableView.selectedRow
        guard row >= 0, row < store.items.count else { return }
        store.update(
            id: store.items[row].id,
            title: titleField.stringValue,
            content: contentTextView.string
        )
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }

    private func updateEmptyState() {
        emptyStateLabel.isHidden = !store.items.isEmpty
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard !isUpdatingFields else { return }
        saveCurrentEdits()
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !isUpdatingFields else { return }
        contentPlaceholder.isHidden = !contentTextView.string.isEmpty
        saveCurrentEdits()
    }

    /// Shift+Tab で内容フィールドからタイトルフィールドにフォーカスを戻す
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            makeFirstResponder(titleField)
            return true
        }
        return false
    }

    // MARK: - アクション

    @objc private func addClicked() {
        store.add(title: "新しいスニペット", content: "")
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        updateEditFields()
        updateEmptyState()
        makeFirstResponder(titleField)
        titleField.selectText(nil)
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
        alert.buttons.first?.hasDestructiveAction = true

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
