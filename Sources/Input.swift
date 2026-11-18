import AppKit

/// Replays input from the other Mac into a window on this Mac.
///
/// Default mode posts events straight to the owning app (`postToPid`) with the target window
/// number set, so this Mac's own cursor does not move and the window can sit off-screen.
/// "Via cursor" mode posts real system events instead, for apps that ignore the first mode.
final class InputInjector {
    let pid: pid_t
    let wid: CGWindowID
    private let source = CGEventSource(stateID: .hidSystemState)

    private enum Field {
        static let scrollIsContinuous = CGEventField(rawValue: 88)!
        static let windowUnderPointer = CGEventField(rawValue: 91)!
        static let windowUnderPointerThatCanHandle = CGEventField(rawValue: 92)!
        static let scrollPhase = CGEventField(rawValue: 99)!
        static let momentumPhase = CGEventField(rawValue: 123)!
    }

    init(pid: pid_t, wid: CGWindowID) {
        self.pid = pid
        self.wid = wid
    }

    func inject(_ e: InputEvent) {
        guard let b = WindowList.bounds(of: wid) else { return }
        let point = CGPoint(x: b.minX + CGFloat(e.x) * b.width, y: b.minY + CGFloat(e.y) * b.height)
        let flags = CGEventFlags(rawValue: e.flags)

        switch e.kind {
        case .mouseDown, .mouseUp, .mouseDrag, .mouseMove:
            if e.kind == .mouseDown { AX.raise(pid: pid, wid: wid) }
            let (type, button) = Self.mouseType(e)
            guard let ev = CGEvent(mouseEventSource: source, mouseType: type,
                                   mouseCursorPosition: point, mouseButton: button) else { return }
            if e.button >= 2 { ev.setIntegerValueField(.mouseEventButtonNumber, value: Int64(e.button)) }
            if e.kind != .mouseMove { ev.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, e.clicks))) }
            ev.flags = flags
            post(ev)

        case .scroll:
            let units: CGScrollEventUnit = e.precise ? .pixel : .line
            guard let ev = CGEvent(scrollWheelEvent2Source: source, units: units, wheelCount: 2,
                                   wheel1: Int32(e.dy), wheel2: Int32(e.dx), wheel3: 0) else { return }
            ev.location = point
            ev.flags = flags
            ev.setIntegerValueField(Field.scrollIsContinuous, value: e.precise ? 1 : 0)
            ev.setIntegerValueField(Field.scrollPhase, value: Int64(e.phase))
            ev.setIntegerValueField(Field.momentumPhase, value: Int64(e.momentum))
            post(ev)

        case .keyDown, .keyUp:
            if e.kind == .keyDown, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                AX.raise(pid: pid, wid: wid)
            }
            guard let ev = CGEvent(keyboardEventSource: source, virtualKey: e.keyCode,
                                   keyDown: e.kind == .keyDown) else { return }
            ev.flags = flags
            if e.isRepeat { ev.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            post(ev)

        case .flags:
            guard let ev = CGEvent(keyboardEventSource: source, virtualKey: e.keyCode, keyDown: true) else { return }
            ev.type = .flagsChanged
            ev.flags = flags
            post(ev)
        }
    }

    private func post(_ ev: CGEvent) {
        if Settings.injectViaCursor {
            ev.post(tap: .cghidEventTap)
        } else {
            ev.setIntegerValueField(Field.windowUnderPointer, value: Int64(wid))
            ev.setIntegerValueField(Field.windowUnderPointerThatCanHandle, value: Int64(wid))
            ev.postToPid(pid)
        }
    }

    private static func mouseType(_ e: InputEvent) -> (CGEventType, CGMouseButton) {
        switch e.kind {
        case .mouseDown:
            return e.button == 0 ? (.leftMouseDown, .left) : e.button == 1 ? (.rightMouseDown, .right) : (.otherMouseDown, .center)
        case .mouseUp:
            return e.button == 0 ? (.leftMouseUp, .left) : e.button == 1 ? (.rightMouseUp, .right) : (.otherMouseUp, .center)
        case .mouseDrag:
            return e.button == 0 ? (.leftMouseDragged, .left) : e.button == 1 ? (.rightMouseDragged, .right) : (.otherMouseDragged, .center)
        default:
            return (.mouseMoved, .left)
        }
    }
}
