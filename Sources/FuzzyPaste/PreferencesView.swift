import SwiftUI

/// 設定画面のタブ。case を追加するだけで新しいタブが増える。
private enum PreferencesTab: String, CaseIterable, Identifiable {
    case hotkey = "ホットキー"
    case windowSize = "ウィンドウサイズ"
    case history = "履歴"
    case excludedApps = "除外アプリ"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .hotkey: return "keyboard"
        case .windowSize: return "macwindow"
        case .history: return "clock.arrow.circlepath"
        case .excludedApps: return "hand.raised"
        }
    }
}

/// 設定ウィンドウのルートビュー。
/// 左サイドバー (タブリスト) + 右コンテンツ のレイアウト。
struct PreferencesView: View {
    let store: PreferencesStore
    let historyStore: HistoryStore
    @State private var selectedTab: PreferencesTab = .hotkey

    var body: some View {
        NavigationSplitView {
            List(PreferencesTab.allCases, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            switch selectedTab {
            case .hotkey:
                HotkeySettingsView(store: store)
            case .windowSize:
                WindowSizeSettingsView(store: store)
            case .history:
                HistorySettingsView(store: store, historyStore: historyStore)
            case .excludedApps:
                ExcludedAppsView(store: store)
            }
        }
    }
}
