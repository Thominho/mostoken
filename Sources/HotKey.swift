import Carbon

/// Global keyboard shortcut via Carbon (works without extra permissions).
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false

    init(keyCode: Int, modifiers: Int, id: UInt32, handler: @escaping () -> Void) {
        HotKey.install()
        HotKey.handlers[id] = handler
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D4F_4B4E), id: id) // 'MOKN'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr { Log.write("Klávesovou zkratku \(id) nelze zaregistrovat (\(status))") }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }

    private static func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
