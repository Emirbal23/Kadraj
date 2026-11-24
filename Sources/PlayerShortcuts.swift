import AppKit
import Carbon

enum PlayerShortcutAction: UInt32, CaseIterable {
    case visibility = 1
    case close = 3

    var title: String {
        switch self {
        case .visibility: "Gizle / göster"
        case .close: "Kadrajı kapat"
        }
    }

    var defaultShortcut: PlayerShortcut {
        switch self {
        case .visibility: PlayerShortcut(key: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey | shiftKey), keyLabel: "K")
        case .close: PlayerShortcut(key: UInt32(kVK_ANSI_W), modifiers: UInt32(controlKey | optionKey | shiftKey), keyLabel: "W")
        }
    }
}

struct PlayerShortcut: Codable {
    let key: UInt32
    let modifiers: UInt32
    let keyLabel: String

    init(key: UInt32, modifiers: UInt32, keyLabel: String) {
        self.key = key
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.control, .option, .command]).isEmpty else { return nil }
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        let special: [Int: String] = [kVK_Space: "Boşluk", kVK_Return: "↩", kVK_Escape: "Esc",
                                      kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
                                      kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                                      kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
                                      kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9",
                                      kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        let characters = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers
        let printable = characters?.first.flatMap { $0.isLetter || $0.isNumber || $0.isPunctuation || $0.isSymbol
            ? String($0).uppercased() : nil }
        guard let label = special[Int(event.keyCode)] ?? printable else { return nil }
        self.init(key: UInt32(event.keyCode), modifiers: carbon, keyLabel: label)
    }

    var label: String {
        let flags = [(UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"),
                     (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘")]
        return flags.filter { modifiers & $0.0 != 0 }.map(\.1).joined() + keyLabel
    }

    func sameKeys(as other: PlayerShortcut) -> Bool {
        key == other.key && modifiers == other.modifiers
    }
}

@MainActor
final class PlayerShortcuts {
    private let defaults: UserDefaults
    private var registrations: [PlayerShortcutAction: EventHotKeyRef] = [:]
    private var values: [PlayerShortcutAction: PlayerShortcut] = [:]
    private var eventHandler: EventHandlerRef?
    var perform: ((PlayerShortcutAction) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for action in PlayerShortcutAction.allCases {
            let saved = defaults.data(forKey: storageKey(action))
                .flatMap { try? JSONDecoder().decode(PlayerShortcut.self, from: $0) }
            values[action] = saved ?? action.defaultShortcut
        }
    }

    func start() {
        if eventHandler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                               EventParamType(typeEventHotKeyID), nil,
                                               MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard status == noErr, identifier.signature == 0x4b_41_44_52,
                      let action = PlayerShortcutAction(rawValue: identifier.id) else {
                    return OSStatus(eventNotHandledErr)
                }
                MainActor.assumeIsolated {
                    Unmanaged<PlayerShortcuts>.fromOpaque(context).takeUnretainedValue().perform?(action)
                }
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        }
        guard eventHandler != nil else { return }
        for action in PlayerShortcutAction.allCases where registrations[action] == nil {
            registrations[action] = register(shortcut(for: action), as: action)
        }
    }

    func suspend() {
        for reference in registrations.values { UnregisterEventHotKey(reference) }
        registrations.removeAll()
    }

    func stop() {
        suspend()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    func shortcut(for action: PlayerShortcutAction) -> PlayerShortcut { values[action] ?? action.defaultShortcut }
    func isActive(_ action: PlayerShortcutAction) -> Bool { registrations[action] != nil }

    func replace(_ action: PlayerShortcutAction, with candidate: PlayerShortcut) -> Bool {
        guard eventHandler != nil,
              !PlayerShortcutAction.allCases.contains(where: { $0 != action && shortcut(for: $0).sameKeys(as: candidate) })
        else { return false }
        if let existing = registrations.removeValue(forKey: action) { UnregisterEventHotKey(existing) }
        guard let reference = register(candidate, as: action) else {
            registrations[action] = register(shortcut(for: action), as: action)
            return false
        }
        registrations[action] = reference
        values[action] = candidate
        defaults.set(try? JSONEncoder().encode(candidate), forKey: storageKey(action))
        return true
    }

    private func register(_ shortcut: PlayerShortcut, as action: PlayerShortcutAction) -> EventHotKeyRef? {
        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x4b_41_44_52, id: action.rawValue)
        let status = RegisterEventHotKey(shortcut.key, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &reference)
        return status == noErr ? reference : nil
    }

    private func storageKey(_ action: PlayerShortcutAction) -> String { "playerShortcut.\(action.rawValue)" }
}
