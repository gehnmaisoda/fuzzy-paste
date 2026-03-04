import SwiftUI
import Carbon
import Combine

/// 初回起動時のオンボーディング画面。
/// ホットキー設定とアクセシビリティ権限チェックを1ページでガイドする。
struct OnboardingView: View {
    @ObservedObject var store: PreferencesStore
    var onComplete: () -> Void

    @State private var isRecording = false
    @State private var liveModifiers: NSEvent.ModifierFlags = []
    @State private var keyDownMonitor: Any?
    @State private var flagsMonitor: Any?
    @State private var isTrusted = AccessibilityChecker.isTrusted
    private let pollPublisher = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private static let escapeKeyCode: UInt16 = 53
    private static let modifierOnlyKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63]

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 36)

            // ヘッダー
            VStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.linearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.6)],
                        startPoint: .top, endPoint: .bottom
                    ))

                Text("FuzzyPaste")
                    .font(.system(size: 26, weight: .bold, design: .rounded))

                Text("クリップボード履歴に素早くアクセス")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 28)

            // STEP 1: ホットキー設定
            stepCard(number: 1) {
                VStack(spacing: 14) {
                    HStack {
                        Text("起動ショートカットを設定")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("推奨: \(HotkeyConfig.default.displayString)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(Color.primary.opacity(0.05))
                            )
                    }

                    // ホットキー入力ボックス
                    Button(action: toggleRecording) {
                        HStack {
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

                            Spacer()

                            Text(isRecording ? "ESC で取消" : "クリックで変更")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(isRecording ? .accentColor : .secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    isRecording ? Color.accentColor : Color.primary.opacity(0.12),
                                    lineWidth: isRecording ? 1.5 : 0.5
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
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    }
                }
            }

            Spacer().frame(height: 12)

            // STEP 2: アクセシビリティ権限
            stepCard(number: 2) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("アクセシビリティ権限を許可")
                            .font(.system(size: 13, weight: .semibold))
                        Text("ホットキーとペースト操作に必要です")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if isTrusted {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.green)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Button("許可する") {
                            AccessibilityChecker.requestAccess()
                        }
                        .controlSize(.regular)
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            Spacer()

            // 始めるボタン
            VStack(spacing: 8) {
                Button(action: complete) {
                    Text("始める")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!isTrusted)

                if !isTrusted {
                    Text("アクセシビリティ権限を付与すると開始できます")
                        .font(.system(size: 10))
                        .foregroundColor(Color.secondary.opacity(0.7))
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .frame(width: 420, height: 480)
        .animation(.easeInOut(duration: 0.3), value: isTrusted)
        .onReceive(pollPublisher) { _ in
            if !isTrusted && AccessibilityChecker.isTrusted {
                isTrusted = true
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    // MARK: - ステップカード

    private func stepCard<Content: View>(number: Int, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // ステップ番号
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(Color.accentColor.opacity(0.85))
                )
                .padding(.top, 2)

            // コンテンツ
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .padding(.horizontal, 28)
    }

    // MARK: - バッジ表示

    private func badgeRow(parts: [String]) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                Text(part)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundColor(.primary)
                    .frame(minWidth: 28, minHeight: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
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
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else { return }

        var carbonMods: UInt32 = 0
        if flags.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if flags.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
        if flags.contains(.option)  { carbonMods |= UInt32(optionKey) }
        if flags.contains(.control) { carbonMods |= UInt32(controlKey) }

        store.setHotkeyConfig(HotkeyConfig(keyCode: UInt32(event.keyCode), carbonModifiers: carbonMods))
        stopRecording()
    }

    // MARK: - 完了

    private func complete() {
        stopRecording()
        onComplete()
    }
}
