import SwiftUI

/// 除外アプリ設定ビュー。
/// 除外リストの表示・削除・追加（実行中アプリから選択）を行う。
struct ExcludedAppsView: View {
    @ObservedObject var store: PreferencesStore
    @State private var showingAppPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("除外アプリ")
                .font(.headline)

            Text("以下のアプリからのコピーはクリップボード履歴に記録されません。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if store.excludedApps.isEmpty {
                emptyState
            } else {
                excludedAppsList
            }

            HStack {
                Button("実行中のアプリから追加...") {
                    showingAppPicker = true
                }
                Spacer()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showingAppPicker) {
            AppPickerSheet(store: store)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "shield.slash")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("除外アプリはありません")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }

    private var excludedAppsList: some View {
        List {
            ForEach(store.excludedApps) { app in
                HStack {
                    AppIconView(bundleIdentifier: app.bundleIdentifier)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.appName)
                            .font(.body)
                        Text(app.bundleIdentifier)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(role: .destructive) {
                        store.removeExcludedApp(id: app.id)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .cornerRadius(8)
    }
}

/// bundleIdentifier からアプリアイコンを表示するビュー。
private struct AppIconView: View {
    let bundleIdentifier: String
    private static let iconSize: CGFloat = 24

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: Self.iconSize, height: Self.iconSize)
        } else {
            Image(systemName: "app")
                .frame(width: Self.iconSize, height: Self.iconSize)
        }
    }
}

// MARK: - アプリ選択シート

/// 実行中のアプリ一覧から除外アプリを選択するシート。
/// 複数アプリを連続で追加できる。
struct AppPickerSheet: View {
    @ObservedObject var store: PreferencesStore
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var runningApps: [RunningAppInfo] = []

    private var filteredApps: [RunningAppInfo] {
        if searchText.isEmpty { return runningApps }
        let query = searchText.lowercased()
        return runningApps.filter {
            $0.name.lowercased().contains(query) || $0.id.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("実行中のアプリから追加")
                    .font(.headline)
                Spacer()
                Button("閉じる") {
                    dismiss()
                }
            }
            .padding()

            // 検索フィールド
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("アプリ名で検索...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(.quaternary)
            .cornerRadius(8)
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            List(filteredApps) { app in
                HStack {
                    Image(nsImage: app.icon)
                        .resizable()
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                            .font(.body)
                        Text(app.id)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if store.isExcluded(bundleIdentifier: app.id) {
                        Text("追加済み")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("追加") {
                            store.addExcludedApp(bundleIdentifier: app.id, appName: app.name)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.plain)
        }
        .frame(width: 440, height: 420)
        .onAppear {
            runningApps = RunningAppInfo.runningApps()
        }
    }
}
