import Carbon
import Foundation

/// どのアプリを使っていても効くキー。Carbon のホットキーなので、アクセシビリティの許可は要らない。
final class GlobalHotKey {
    struct Key {
        let code: UInt32
        let modifiers: UInt32
        let label: String
    }

    /// キーを変えるときはここだけ直す。
    static let newNote = Key(code: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey | cmdKey), label: "⌃⌥⌘T")
    static let meeting = Key(code: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey | cmdKey), label: "⌃⌥⌘R")

    /// 登録したキーごとの動き。押されたキーの番号で振り分ける。
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerRef: EventHandlerRef?
    private static var lastID: UInt32 = 0

    private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32

    init?(_ key: Key, action: @escaping () -> Void) {
        Self.installHandler()
        Self.lastID += 1
        id = Self.lastID
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D4F_4755), id: id)  // "MOGU"
        let status = RegisterEventHotKey(key.code, key.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            NSLog("ホットキー \(key.label) を登録できませんでした（ほかのアプリが使っているかもしれません）: \(status)")
            return nil
        }
        Self.actions[id] = action
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        Self.actions[id] = nil
    }

    /// 受け口はアプリに1つだけ置く。
    private static func installHandler() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard status == noErr else { return noErr }
            let id = pressed.id
            DispatchQueue.main.async { GlobalHotKey.actions[id]?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }
}
