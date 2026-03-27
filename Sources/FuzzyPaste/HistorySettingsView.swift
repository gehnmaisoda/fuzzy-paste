import FuzzyPasteCore
import SwiftUI

/// 履歴設定ビュー。最大保持件数の変更と履歴の全削除ができる。
struct HistorySettingsView: View {
    @ObservedObject var store: PreferencesStore
    let historyStore: HistoryStore
    @State private var showClearConfirm = false
    @State private var historyCount = 0

    var body: some View {
        VStack(spacing: 24) {
            Text("履歴")
                .font(.headline)

            // 最大保持件数
            VStack(alignment: .leading, spacing: 8) {
                Text("最大保持件数")
                    .font(.subheadline)
                Picker("最大保持件数", selection: Binding(
                    get: { store.maxHistoryCount },
                    set: { store.setMaxHistoryCount($0) }
                )) {
                    ForEach(PreferencesStore.maxHistoryCountOptions, id: \.self) { count in
                        Text(count == PreferencesStore.defaultMaxHistoryCount ? "\(count) 件（推奨）" : "\(count) 件").tag(count)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                Text("現在 \(historyCount) 件の履歴があります")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()
                .padding(.horizontal)

            // 履歴の全削除
            VStack(spacing: 8) {
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label("すべての履歴を削除", systemImage: "trash")
                }
                .disabled(historyCount == 0)
                .alert("履歴をすべて削除しますか？", isPresented: $showClearConfirm) {
                    Button("削除", role: .destructive) {
                        historyStore.clearAll()
                        historyCount = 0
                    }
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("この操作は取り消せません。\(historyCount) 件の履歴がすべて削除されます。")
                }
                Text("スニペットは削除されません")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { historyCount = historyStore.items.count }
    }
}
