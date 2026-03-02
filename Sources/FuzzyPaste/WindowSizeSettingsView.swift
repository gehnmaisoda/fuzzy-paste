import SwiftUI

/// ウィンドウサイズ設定ビュー。小・中・大の3段階プリセットを選択できる。
struct WindowSizeSettingsView: View {
    @ObservedObject var store: PreferencesStore

    var body: some View {
        VStack(spacing: 20) {
            Text("ウィンドウサイズ")
                .font(.headline)

            Picker("サイズ", selection: Binding(
                get: { store.windowSizePreset },
                set: { store.setWindowSizePreset($0) }
            )) {
                ForEach(WindowSizePreset.allCases, id: \.self) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)

            // プレビュー
            let config = LayoutConfig.preset(store.windowSizePreset)
            VStack(spacing: 8) {
                previewWindow(config: config)
                Text("\(Int(config.windowSize.width)) × \(Int(config.windowSize.height))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// ウィンドウのミニチュアプレビュー
    private func previewWindow(config: LayoutConfig) -> some View {
        let scale: CGFloat = 0.3
        let w = config.windowSize.width * scale
        let h = config.windowSize.height * scale
        return RoundedRectangle(cornerRadius: config.cornerRadius * scale)
            .fill(Color.secondary.opacity(0.15))
            .overlay(
                RoundedRectangle(cornerRadius: config.cornerRadius * scale)
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
            )
            .frame(width: w, height: h)
    }
}
