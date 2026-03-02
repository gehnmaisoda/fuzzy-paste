import SwiftUI

/// 設定画面のタブ。将来「一般」等を追加する場合は case を追加するだけ。
private enum PreferencesTab: String, CaseIterable, Identifiable {
    case excludedApps = "除外アプリ"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .excludedApps: return "hand.raised"
        }
    }
}

/// 設定ウィンドウのルートビュー。
/// 左サイドバー (タブリスト) + 右コンテンツ のレイアウト。
struct PreferencesView: View {
    let store: PreferencesStore
    @State private var selectedTab: PreferencesTab = .excludedApps

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
            case .excludedApps:
                ExcludedAppsView(store: store)
            }
        }
    }
}
