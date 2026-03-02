import AppKit
import Combine

/// ウィンドウサイズのプリセット。小・中・大の3段階。
enum WindowSizePreset: String, Codable, CaseIterable, Sendable {
    case small
    case medium
    case large

    var label: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        }
    }
}

/// レイアウト定数。プリセットごとのサイズ依存値 + 固定値をまとめた構造体。
struct LayoutConfig: Sendable {
    // サイズ依存値
    let windowSize: NSSize
    let rowHeight: CGFloat
    let snippetRowHeight: CGFloat
    let imageRowHeight: CGFloat
    let thumbSize: CGFloat
    let searchFontSize: CGFloat
    let cellFontSize: CGFloat
    let hintFontSize: CGFloat
    let searchHeight: CGFloat
    let hintBarHeight: CGFloat

    // 固定値
    let cornerRadius: CGFloat = 12
    let windowPadding: CGFloat = 12
    let cellPadding: CGFloat = 16
    let iconSize: CGFloat = 20
    let sectionGap: CGFloat = 8
    let iconInset: CGFloat = 4
    let iconTextGap: CGFloat = 8
    let badgeGap: CGFloat = 4
    let badgeFontSize: CGFloat = 9
    let badgeHPad: CGFloat = 5
    let badgeVPad: CGFloat = 1.5
    let badgeCornerRadius: CGFloat = 4
    let selBadgeSize: CGFloat = 20
    let selBadgeFontSize: CGFloat = 11
    let selBadgeTrailing: CGFloat = 8

    static func preset(_ preset: WindowSizePreset) -> LayoutConfig {
        switch preset {
        case .small:
            return LayoutConfig(
                windowSize: NSSize(width: 480, height: 340),
                rowHeight: 30, snippetRowHeight: 46, imageRowHeight: 64,
                thumbSize: 48, searchFontSize: 16, cellFontSize: 12,
                hintFontSize: 10, searchHeight: 32, hintBarHeight: 24
            )
        case .medium:
            return LayoutConfig(
                windowSize: NSSize(width: 600, height: 420),
                rowHeight: 36, snippetRowHeight: 56, imageRowHeight: 80,
                thumbSize: 64, searchFontSize: 18, cellFontSize: 13,
                hintFontSize: 11, searchHeight: 36, hintBarHeight: 28
            )
        case .large:
            return LayoutConfig(
                windowSize: NSSize(width: 760, height: 540),
                rowHeight: 42, snippetRowHeight: 66, imageRowHeight: 100,
                thumbSize: 84, searchFontSize: 20, cellFontSize: 14,
                hintFontSize: 12, searchHeight: 40, hintBarHeight: 32
            )
        }
    }
}

/// 除外アプリの情報。
struct ExcludedApp: Codable, Identifiable, Sendable {
    let id: UUID
    let bundleIdentifier: String
    let appName: String
    let addedAt: Date
}

/// アプリ全体の設定データ。
/// 新フィールド追加時は init(from:) で decodeIfPresent を使い、
/// 既存 JSON に未知のキーがなくてもデコードが成功するようにする。
private struct Preferences: Codable, Sendable {
    var excludedApps: [ExcludedApp] = []
    var windowSizePreset: WindowSizePreset = .medium
    var maxHistoryCount: Int = PreferencesStore.defaultMaxHistoryCount

    init(excludedApps: [ExcludedApp] = [], windowSizePreset: WindowSizePreset = .medium, maxHistoryCount: Int = PreferencesStore.defaultMaxHistoryCount) {
        self.excludedApps = excludedApps
        self.windowSizePreset = windowSizePreset
        self.maxHistoryCount = maxHistoryCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        excludedApps = try container.decodeIfPresent([ExcludedApp].self, forKey: .excludedApps) ?? []
        windowSizePreset = try container.decodeIfPresent(WindowSizePreset.self, forKey: .windowSizePreset) ?? .medium
        maxHistoryCount = try container.decodeIfPresent(Int.self, forKey: .maxHistoryCount) ?? PreferencesStore.defaultMaxHistoryCount
    }
}

/// 設定の永続化を管理するストア。
/// JSON ファイルで保存し、既存の HistoryStore / SnippetStore と同じパターンに従う。
///
/// 保存先: ~/Library/Application Support/FuzzyPaste/preferences.json
@MainActor
final class PreferencesStore: ObservableObject {
    /// 履歴の最大保持件数のデフォルト値。
    nonisolated static let defaultMaxHistoryCount = 500
    /// 履歴の最大保持件数の選択肢。
    nonisolated static let maxHistoryCountOptions = [100, 300, 500, 1000, 2000]

    @Published private(set) var excludedApps: [ExcludedApp] = []
    @Published private(set) var windowSizePreset: WindowSizePreset = .medium
    @Published private(set) var maxHistoryCount: Int = PreferencesStore.defaultMaxHistoryCount
    private let fileURL: URL

    var layoutConfig: LayoutConfig {
        LayoutConfig.preset(windowSizePreset)
    }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("FuzzyPaste")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("preferences.json")
        load()
    }

    func addExcludedApp(bundleIdentifier: String, appName: String) {
        guard !excludedApps.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        let app = ExcludedApp(id: UUID(), bundleIdentifier: bundleIdentifier, appName: appName, addedAt: Date())
        excludedApps.append(app)
        save()
    }

    func removeExcludedApp(id: UUID) {
        excludedApps.removeAll { $0.id == id }
        save()
    }

    func isExcluded(bundleIdentifier: String) -> Bool {
        excludedApps.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    func setWindowSizePreset(_ preset: WindowSizePreset) {
        guard windowSizePreset != preset else { return }
        windowSizePreset = preset
        save()
    }

    func setMaxHistoryCount(_ count: Int) {
        guard maxHistoryCount != count else { return }
        maxHistoryCount = count
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let prefs = try? decoder.decode(Preferences.self, from: data) {
            excludedApps = prefs.excludedApps
            windowSizePreset = prefs.windowSizePreset
            maxHistoryCount = prefs.maxHistoryCount
        }
    }

    private func save() {
        let prefs = Preferences(excludedApps: excludedApps, windowSizePreset: windowSizePreset, maxHistoryCount: maxHistoryCount)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(prefs) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
