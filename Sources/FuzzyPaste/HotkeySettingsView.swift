import SwiftUI
import Carbon

/// ホットキー設定ビュー。VSCode 風のキーバッジ表示 + リアルタイム録音。
struct HotkeySettingsView: View {
    @ObservedObject var store: PreferencesStore
    @State private var isRecording = false
    @State private var liveModifiers: NSEvent.ModifierFlags = []
    @State private var keyDownMonitor: Any?
    @State private var flagsMonitor: Any?

    private static let escapeKeyCode: UInt16 = 53
    /// 修飾キー自体のキーコード。単体押下は無視する。
    private static let modifierOnlyKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63]

    var body: some View {
        VStack(spacing: 20) {
            Text("ホットキー")
                .font(.headline)

            VStack(spacing: 4) {
                Text("FuzzyPaste を起動するキーボードショートカット")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("推奨: \(HotkeyConfig.default.displayString)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // ホットキー入力ボックス
            Button(action: toggleRecording) {
                Group {
                    if isRecording {
                        if liveModifiers.isEmpty {
                            Text("キーを入力...")
                                .font(.system(size: 13))
                                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        } else {
                            badgeRow(parts: modifierSymbols(for: liveModifiers))
                        }
                    } else {
                        badgeRow(parts: store.hotkeyConfig.keyParts)
                    }
                }
                .frame(minWidth: 160, minHeight: 36)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isRecording ? Color.accentColor : Color.primary.opacity(0.2),
                            lineWidth: isRecording ? 2 : 1
                        )
                )
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.15), value: isRecording)

            // デフォルトに戻す
            if store.hotkeyConfig != .default {
                Button("デフォルトに戻す（\(HotkeyConfig.default.displayString)）") {
                    store.setHotkeyConfig(.default)
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { stopRecording() }
    }

    // MARK: - バッジ表示

    private func badgeRow(parts: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                Text(part)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .primary.opacity(0.1), radius: 0.5, y: 0.5)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                    )
            }
        }
    }

    private func modifierSymbols(for flags: NSEvent.ModifierFlags) -> [String] {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option)  { parts.append("⌥") }
        if flags.contains(.shift)   { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        return parts
    }

    // MARK: - キー録音

    private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        // グローバルホットキーを同期的に解除してから録音を開始
        store.isRecordingHotkey = true
        store.onPauseHotkey?()
        isRecording = true
        liveModifiers = []

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            liveModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            return event
        }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleRecordedKey(event)
            return nil
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
        if let m = keyDownMonitor { NSEvent.removeMonitor(m); keyDownMonitor = nil }
        isRecording = false
        liveModifiers = []
        store.isRecordingHotkey = false
        store.onResumeHotkey?()
    }

    private func handleRecordedKey(_ event: NSEvent) {
        if event.keyCode == Self.escapeKeyCode { stopRecording(); return }
        guard !Self.modifierOnlyKeyCodes.contains(event.keyCode) else { return }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // 修飾キー（Cmd / Ctrl / Option）を1つ以上含むこと（Shift 単体は不可）
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else { return }

        var carbonMods: UInt32 = 0
        if flags.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if flags.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
        if flags.contains(.option)  { carbonMods |= UInt32(optionKey) }
        if flags.contains(.control) { carbonMods |= UInt32(controlKey) }

        store.setHotkeyConfig(HotkeyConfig(keyCode: UInt32(event.keyCode), carbonModifiers: carbonMods))
        stopRecording()
    }
}
