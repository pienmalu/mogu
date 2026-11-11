import Carbon
import Foundation

/// どのアプリを使っていても効くキー。Carbon のホットキーなので、アクセシビリティの許可は要らない。
final class GlobalHotKey {
    /// 既定は ⌃⌥⌘T（上流の Thoughts と同じ）。変えるときはここだけ直す。
    static let defaultKeyCode = UInt32(kVK_ANSI_T)
    static let defaultModifiers = UInt32(controlKey | optionKey | cmdKey)
    static let defaultLabel = "⌃⌥⌘T"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: UInt32 = defaultKeyCode, modifiers: UInt32 = defaultModifiers, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &spec, me, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x4D4F_4755), id: 1)  // "MOGU"
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            NSLog("ホットキーを登録できませんでした（ほかのアプリが使っているかもしれません）: \(status)")
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
