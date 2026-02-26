import AppKit
import Carbon

/// グローバルホットキー (Cmd+Shift+V) の登録・管理を担当。
///
/// Carbon の RegisterEventHotKey API を使用。理由:
/// - NSEvent.addGlobalMonitorForEvents はイベントを「監視」するだけで消費しない。
///   そのため、ホットキーが元アプリにも伝わり「V」が入力されてしまう。
/// - Carbon API はイベントを横取りするため、この問題が起きない。
/// - Carbon API は deprecated だが、代替となる純 Swift API がまだ存在しない。
///
/// ※ C関数ポインタをコールバックとして使うため、static 変数でインスタンスを保持する
///   シングルトン的パターンを採用。複数インスタンスは想定しない。
@MainActor
final class HotkeyManager {
    private static let hotkeySignature = OSType(0x4650_5354) // FourCC: "FPST" (FuzzyPaSte)
    private static let hotkeyID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    var onHotkey: (() -> Void)?

    /// C コールバックからインスタンスにアクセスするための参照。
    /// Carbon API は C 関数ポインタしかコールバックに使えないため、
    /// この static 変数経由でSwiftインスタンスに到達する。
    fileprivate static var instance: HotkeyManager?

    func register() {
        HotkeyManager.instance = self

        // キーボードイベントハンドラをインストール
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(), hotKeyHandler, 1, &eventType, nil, nil
        )
        if handlerStatus != noErr {
            NSLog("[FuzzyPaste] Failed to install event handler: \(handlerStatus)")
        }

        // Cmd+Shift+V をグローバルホットキーとして登録
        let hotKeyID = EventHotKeyID(signature: Self.hotkeySignature, id: Self.hotkeyID)
        let modifiers = UInt32(cmdKey | shiftKey)
        let registerStatus = RegisterEventHotKey(
            UInt32(PasteHelper.vKeyCode), modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        if registerStatus != noErr {
            NSLog("[FuzzyPaste] Failed to register hotkey: \(registerStatus)")
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        HotkeyManager.instance = nil
    }
}

/// Carbon API から呼ばれる C 関数コールバック。
/// ホットキーが押されたときに発火し、static 変数経由でSwift側に通知する。
private func hotKeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    MainActor.assumeIsolated {
        HotkeyManager.instance?.onHotkey?()
    }
    return noErr
}
