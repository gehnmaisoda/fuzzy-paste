import AppKit
import FuzzyPasteCore

/// CSV データをテーブル形式で表示するビュー。
/// ヘッダー行のハイライト・横スクロール・ゼブラストライプ対応。
@MainActor
final class CSVTableView: NSView {
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let rowCountLabel = NSTextField(labelWithString: "")
    private var headers: [String] = []
    private var rows: [[String]] = []

    /// セル内の左パディング
    fileprivate static let cellPaddingLeft: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        // ScrollView（縦横スクロール対応）
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // TableView
        tableView.style = .plain
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.headerView = CSVHeaderView()
        tableView.cornerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.selectionHighlightStyle = .none
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.gridColor = .separatorColor
        scrollView.documentView = tableView

        // 行数ラベル
        rowCountLabel.font = .systemFont(ofSize: 10, weight: .medium)
        rowCountLabel.textColor = .tertiaryLabelColor
        rowCountLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowCountLabel)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: rowCountLabel.topAnchor, constant: -4),

            rowCountLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            rowCountLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    /// CSV パース結果をセットして表示を更新する。
    func setCSV(_ result: CSVParser.Result) {
        headers = result.headers
        rows = result.rows

        // 既存カラムを削除
        tableView.tableColumns.forEach { tableView.removeTableColumn($0) }

        // カラムを作成
        for (i, header) in headers.enumerated() {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col_\(i)"))
            col.title = header
            col.headerToolTip = header

            let width = calculateColumnWidth(columnIndex: i, header: header)
            col.width = width
            col.minWidth = 40
            col.maxWidth = 500

            // ヘッダーセルをカスタマイズ
            let headerCell = CSVHeaderCell(textCell: header)
            headerCell.font = .systemFont(ofSize: 11, weight: .semibold)
            col.headerCell = headerCell

            tableView.addTableColumn(col)
        }

        tableView.reloadData()

        // 行数ラベル更新
        rowCountLabel.stringValue = "\(rows.count) rows × \(headers.count) cols"

        // 先頭にスクロール
        if !rows.isEmpty {
            tableView.scrollRowToVisible(0)
        }
    }

    /// カラム幅をヘッダーと先頭数行の内容から推定する。
    private func calculateColumnWidth(columnIndex: Int, header: String) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let headerAttrs: [NSAttributedString.Key: Any] = [.font: headerFont]

        var maxWidth = (header as NSString).size(withAttributes: headerAttrs).width

        for row in rows.prefix(50) {
            if columnIndex < row.count {
                let w = (row[columnIndex] as NSString).size(withAttributes: attrs).width
                maxWidth = max(maxWidth, w)
            }
        }

        // セル左パディング + 右余白を加えてクランプ
        return min(max(maxWidth + Self.cellPaddingLeft + 16, 50), 500)
    }
}

// MARK: - NSTableViewDataSource

extension CSVTableView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }
}

// MARK: - NSTableViewDelegate

extension CSVTableView: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let id = tableColumn.identifier
        let cellID = NSUserInterfaceItemIdentifier("CSVCell_\(id.rawValue)")

        // セルをラッパー NSView にして左パディングを確保
        let wrapper: NSView
        let label: NSTextField
        if let existing = tableView.makeView(withIdentifier: cellID, owner: nil) {
            wrapper = existing
            label = existing.subviews.first as! NSTextField
        } else {
            wrapper = NSView()
            wrapper.identifier = cellID

            let tf = NSTextField(labelWithString: "")
            tf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            tf.lineBreakMode = .byTruncatingTail
            tf.cell?.truncatesLastVisibleLine = true
            tf.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(tf)

            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: Self.cellPaddingLeft),
                tf.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            ])
            label = tf
        }

        guard let colIndex = tableView.tableColumns.firstIndex(of: tableColumn),
              row < rows.count, colIndex < rows[row].count else {
            label.stringValue = ""
            return wrapper
        }

        label.stringValue = rows[row][colIndex]
        label.textColor = .labelColor
        return wrapper
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("CSVRow")
        if let existing = tableView.makeView(withIdentifier: id, owner: nil) as? CSVRowView {
            existing.isEvenRow = row % 2 == 0
            return existing
        }
        let rowView = CSVRowView()
        rowView.identifier = id
        rowView.isEvenRow = row % 2 == 0
        return rowView
    }
}

// MARK: - Custom Row View (ゼブラストライプ)

@MainActor
private final class CSVRowView: NSTableRowView {
    var isEvenRow = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isEvenRow {
            NSColor.labelColor.withAlphaComponent(0.03).setFill()
        } else {
            NSColor.clear.setFill()
        }
        dirtyRect.fill()
    }
}

// MARK: - Custom Header View（不透明背景でスクロール時に行と被らない）

@MainActor
private final class CSVHeaderView: NSTableHeaderView {
    override init(frame frameRect: NSRect) {
        // ヘッダーの高さを広げる（デフォルト ~17pt → 28pt）
        var f = frameRect
        f.size.height = 28
        super.init(frame: f)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    private func configureLayer() {
        wantsLayer = true
        layer?.isOpaque = true
    }

    override var isOpaque: Bool { true }

    override func updateLayer() {
        // ダークモード切替に追従
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        // 不透明な背景で塗りつぶし（スクロール時に行が透けない）
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        // ヘッダーのティント
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        bounds.fill()

        super.draw(dirtyRect)

        // 下の境界線
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

// MARK: - Custom Header Cell

@MainActor
private final class CSVHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        // 不透明背景を描画
        NSColor.windowBackgroundColor.setFill()
        cellFrame.fill()
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        cellFrame.fill()

        // テキストを垂直中央に描画
        let textFont = font ?? .systemFont(ofSize: 11, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let textSize = (stringValue as NSString).size(withAttributes: attrs)
        let textY = cellFrame.origin.y + (cellFrame.height - textSize.height) / 2
        let textRect = NSRect(
            x: cellFrame.origin.x + CSVTableView.cellPaddingLeft,
            y: textY,
            width: cellFrame.width - CSVTableView.cellPaddingLeft - 4,
            height: textSize.height
        )
        (stringValue as NSString).draw(in: textRect, withAttributes: attrs)

        // 右の区切り線
        NSColor.separatorColor.setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.origin.y, width: 1, height: cellFrame.height).fill()
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // デフォルト描画を無効化
    }
}
