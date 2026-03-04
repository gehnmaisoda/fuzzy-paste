import AppKit
import Carbon
import Combine

/// ホットキーの設定。キーコードと修飾キーの組み合わせを保持する。
struct HotkeyConfig: Codable, Sendable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// デフォルト: Cmd+Shift+V
    static let `default` = HotkeyConfig(keyCode: 9, carbonModifiers: UInt32(cmdKey | shiftKey))

    /// 修飾キー記号 + キー名の配列。例: ["⇧", "⌘", "V"]
    var keyParts: [String] {
        var parts: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0  { parts.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0   { parts.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0     { parts.append("⌘") }
        parts.append(KeyCodeMap.name(for: keyCode))
        return parts
    }

    /// "⇧⌘V" のような表示用文字列。
    var displayString: String { keyParts.joined() }
}

/// Carbon 仮想キーコードから表示用キー名への変換。
enum KeyCodeMap {
    private static let map: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 10: "§", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
        32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L", 38: "J",
        39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
        47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete",
        // JIS キーボード
        93: "¥", 94: "_", 102: "英数", 104: "かな",
        // ファンクションキー・ナビゲーション
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 105: "F13", 107: "F14", 109: "F10", 111: "F12",
        113: "F15", 115: "Home", 116: "PageUp", 117: "⌦", 118: "F4",
        119: "End", 120: "F2", 121: "PageDown", 122: "F1", 123: "←",
        124: "→", 125: "↓", 126: "↑",
    ]

    static func name(for keyCode: UInt32) -> String {
        map[keyCode] ?? "Key\(keyCode)"
    }
}

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
    let cornerRadius: CGFloat = 14
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
                hintFontSize: 10, searchHeight: 32, hintBarHeight: 28
            )
        case .medium:
            return LayoutConfig(
                windowSize: NSSize(width: 600, height: 420),
                rowHeight: 36, snippetRowHeight: 56, imageRowHeight: 80,
                thumbSize: 64, searchFontSize: 18, cellFontSize: 13,
                hintFontSize: 11, searchHeight: 36, hintBarHeight: 32
            )
        case .large:
            return LayoutConfig(
                windowSize: NSSize(width: 760, height: 540),
                rowHeight: 42, snippetRowHeight: 66, imageRowHeight: 100,
                thumbSize: 84, searchFontSize: 20, cellFontSize: 14,
                hintFontSize: 12, searchHeight: 40, hintBarHeight: 36
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
    var hotkeyConfig: HotkeyConfig = .default
    var hasCompletedOnboarding: Bool = false

    init(excludedApps: [ExcludedApp] = [], windowSizePreset: WindowSizePreset = .medium, maxHistoryCount: Int = PreferencesStore.defaultMaxHistoryCount, hotkeyConfig: HotkeyConfig = .default, hasCompletedOnboarding: Bool = false) {
        self.excludedApps = excludedApps
        self.windowSizePreset = windowSizePreset
        self.maxHistoryCount = maxHistoryCount
        self.hotkeyConfig = hotkeyConfig
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        excludedApps = try container.decodeIfPresent([ExcludedApp].self, forKey: .excludedApps) ?? []
        windowSizePreset = try container.decodeIfPresent(WindowSizePreset.self, forKey: .windowSizePreset) ?? .medium
        maxHistoryCount = try container.decodeIfPresent(Int.self, forKey: .maxHistoryCount) ?? PreferencesStore.defaultMaxHistoryCount
        hotkeyConfig = try container.decodeIfPresent(HotkeyConfig.self, forKey: .hotkeyConfig) ?? .default
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
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
    @Published private(set) var hotkeyConfig: HotkeyConfig = .default
    @Published private(set) var hasCompletedOnboarding: Bool = false
    /// ホットキー録音中フラグ。
    var isRecordingHotkey = false
    /// ホットキー一時停止・再開コールバック。AppDelegate が設定する。
    var onPauseHotkey: (() -> Void)?
    var onResumeHotkey: (() -> Void)?
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

    func setHotkeyConfig(_ config: HotkeyConfig) {
        guard hotkeyConfig != config else { return }
        hotkeyConfig = config
        save()
    }

    func completeOnboarding() {
        guard !hasCompletedOnboarding else { return }
        hasCompletedOnboarding = true
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
            hotkeyConfig = prefs.hotkeyConfig
            hasCompletedOnboarding = prefs.hasCompletedOnboarding
        }
    }

    private func save() {
        let prefs = Preferences(excludedApps: excludedApps, windowSizePreset: windowSizePreset, maxHistoryCount: maxHistoryCount, hotkeyConfig: hotkeyConfig, hasCompletedOnboarding: hasCompletedOnboarding)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(prefs) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
