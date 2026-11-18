import AppKit

/// Replays input from the other Mac into a window on this Mac.
///
/// Keys are posted straight to the owning app (`postToPid`), which works even in the background.
/// Mouse and scroll events by default go through the normal event system at the window's real
/// position: before the first click the window is brought back on screen (if parked) and raised,
/// exactly like a click on a real display. The experimental "background" mode posts pointer
/// events to the app too, without moving anything.
final class InputInjector {
    let pid: pid_t
    let wid: CGWindowID
    /// Asked before pointer events in cursor mode: make the window visible on screen.
    var showWindow: (() -> Void)?
    /// True between a forwarded mouse-down and mouse-up.
    private(set) var buttonDown = false

    private var pending: [InputEvent] = []
    private var waiting = false
    private var lastFrontCheck = Date.distantPast

    private enum Field {
        static let scrollIsContinuous = CGEventField(rawValue: 88)!
        static let scrollPhase = CGEventField(rawValue: 99)!
        static let momentumPhase = CGEventField(rawValue: 123)!
    }

    init(pid: pid_t, wid: CGWindowID) {
        self.pid = pid
        self.wid = wid
    }

    func inject(_ e: InputEvent) {
        switch e.kind {
        case .keyDown, .keyUp, .flags:
            injectKey(e)
        case .mouseDown, .mouseUp, .mouseDrag, .mouseMove, .scroll:
            if e.kind == .mouseDown { buttonDown = true }
            if e.kind == .mouseUp { buttonDown = false }
            if Settings.mouseMode == "background" {
                if e.kind == .mouseDown { AX.raise(pid: pid, wid: wid) }
                postPointer(e, toApp: true)
            } else {
                pending.append(e)
                drain()
            }
        }
    }

    // MARK: Keyboard

    private func injectKey(_ e: InputEvent) {
        if e.kind == .keyDown, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            AX.raise(pid: pid, wid: wid)
        }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let ev = CGEvent(keyboardEventSource: source, virtualKey: e.keyCode, keyDown: e.kind != .keyUp) else { return }
        if e.kind == .flags { ev.type = .flagsChanged }
        ev.flags = CGEventFlags(rawValue: e.flags)
        if e.isRepeat { ev.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        ev.postToPid(pid)
    }

    // MARK: Pointer, cursor mode

    private func drain() {
        guard !waiting else { return }
        while let e = pending.first {
            if e.kind == .mouseMove && pending.count > 1 && pending[1].kind == .mouseMove {
                pending.removeFirst()   // only the newest hover position matters
                continue
            }
            let starts = e.kind == .mouseDown || e.kind == .scroll
            if starts && !isFrontmost(at: e) {
                showWindow?()
                AX.raise(pid: pid, wid: wid)
                waiting = true
                // Give the window server a moment to move/raise the window before clicking.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                    self.waiting = false
                    self.lastFrontCheck = Date()
                    self.drain()
                }
                return
            }
            pending.removeFirst()
            if e.kind == .mouseMove && !isOnScreen() { continue } // don't pull a parked window out just for hover
            if starts { showWindow?() }
            postPointer(e, toApp: false)
        }
    }

    private func point(for e: InputEvent) -> CGPoint? {
        guard let b = WindowList.bounds(of: wid) else { return nil }
        return CGPoint(x: b.minX + CGFloat(e.x) * b.width, y: b.minY + CGFloat(e.y) * b.height)
    }

    private func isOnScreen() -> Bool {
        guard let b = WindowList.bounds(of: wid) else { return false }
        let screens = NSScreen.screens.map { s -> CGRect in
            let f = s.frame
            return CGRect(x: f.minX, y: ScreenGeometry.primaryHeight - f.maxY, width: f.width, height: f.height)
        }
        let visible = screens.reduce(0) { $0 + $1.intersection(b).width * $1.intersection(b).height }
        return visible >= b.width * b.height * 0.9
    }

    /// The window must be the topmost window under the event position, otherwise the click
    /// would land on something else.
    private func isFrontmost(at e: InputEvent) -> Bool {
        guard let p = point(for: e), isOnScreen() else { return false }
        if Date().timeIntervalSince(lastFrontCheck) < 0.5 && e.kind == .scroll { return true }
        return WindowList.topmostWindow(at: p) == wid
    }

    // MARK: Posting

    private func postPointer(_ e: InputEvent, toApp: Bool) {
        guard let p = point(for: e) else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let flags = CGEventFlags(rawValue: e.flags)
        let ev: CGEvent?
        if e.kind == .scroll {
            ev = CGEvent(scrollWheelEvent2Source: source, units: e.precise ? .pixel : .line, wheelCount: 2,
                         wheel1: Int32(e.dy), wheel2: Int32(e.dx), wheel3: 0)
            ev?.location = p
            ev?.setIntegerValueField(Field.scrollIsContinuous, value: e.precise ? 1 : 0)
            ev?.setIntegerValueField(Field.scrollPhase, value: Int64(e.phase))
            ev?.setIntegerValueField(Field.momentumPhase, value: Int64(e.momentum))
        } else {
            let (type, button) = Self.mouseType(e)
            ev = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
            if e.button >= 2 { ev?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(e.button)) }
            if e.kind != .mouseMove { ev?.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, e.clicks))) }
        }
        guard let ev else { return }
        ev.flags = flags
        if toApp {
            for field in Settings.backgroundFields {
                if let f = CGEventField(rawValue: UInt32(field)) { ev.setIntegerValueField(f, value: Int64(wid)) }
            }
            ev.postToPid(pid)
        } else {
            ev.post(tap: .cgSessionEventTap)
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
