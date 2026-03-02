import AppKit

/// 実行中アプリの情報。除外アプリ追加シートで使用する。
struct RunningAppInfo: Identifiable {
    let id: String  // bundleIdentifier
    let name: String
    let icon: NSImage

    /// 現在実行中の通常アプリ一覧を取得する。
    /// バックグラウンドプロセスや自分自身は除外する。
    static func runningApps() -> [RunningAppInfo] {
        let ownBundleId = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited && $0.bundleIdentifier != ownBundleId }
            .compactMap { app in
                guard let bundleId = app.bundleIdentifier,
                      let name = app.localizedName else { return nil }
                let icon = app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
                return RunningAppInfo(id: bundleId, name: name, icon: icon)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
