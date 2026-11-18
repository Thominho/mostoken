import AppKit

/// Replays input from the other Mac into a window on this Mac.
///
/// Default ("background"): every event is posted straight to the owning app with the target
/// window number and the position inside that window, so it arrives exactly like a real click
/// on that window — while this Mac's own cursor and windows stay where they are. That matters
/// with Universal Control, where the same mouse may be driving the other Mac at that moment.
///
/// Fallback ("cursor"): real system events at the window's on-screen position; the window is
/// brought back on screen for a moment. Used only if the background method is unavailable or
/// the person switches to it in Settings.
final class InputInjector {
    let pid: pid_t
    let wid: CGWindowID
    /// Cursor mode only: make the window visible on screen before a click.
    var showWindow: (() -> Void)?
    /// Called after a click or key press (menus may have opened).
    var onActivity: ((InputEvent.Kind) -> Void)?
    /// True between a forwarded mouse-down and mouse-up.
    private(set) var buttonDown = false
    /// Where the last click landed on this Mac (global coordinates), to place menus it opens.
    private(set) var lastClick: CGPoint?

    private var pending: [InputEvent] = []
    private var waiting = false
    private let isPopup: Bool

    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    /// CoreGraphics SPI; without it AppKit cannot tell where inside the window an event is.
    private static let setWindowLocation: SetWindowLocation? = {
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "CGEventSetWindowLocation") else {
            Log.write("CGEventSetWindowLocation není k dispozici – klikání půjde přes kurzor")
            return nil
        }
        return unsafeBitCast(sym, to: SetWindowLocation.self)
    }()

    private enum Field {
        static let windowNumber = CGEventField(rawValue: 51)!
        static let windowUnderPointer = CGEventField(rawValue: 91)!
        static let windowUnderPointerThatCanHandle = CGEventField(rawValue: 92)!
        static let scrollIsContinuous = CGEventField(rawValue: 88)!
        static let scrollPhase = CGEventField(rawValue: 99)!
        static let momentumPhase = CGEventField(rawValue: 123)!
    }

    init(pid: pid_t, wid: CGWindowID, isPopup: Bool = false) {
        self.pid = pid
        self.wid = wid
        self.isPopup = isPopup
    }

    private var background: Bool {
        Settings.mouseMode != "cursor" && Self.setWindowLocation != nil
    }

    func inject(_ e: InputEvent) {
        switch e.kind {
        case .keyDown, .keyUp, .flags:
            injectKey(e)
            if e.kind == .keyDown { onActivity?(e.kind) }
        case .mouseDown, .mouseUp, .mouseDrag, .mouseMove, .scroll:
            if e.kind == .mouseDown { buttonDown = true }
            if e.kind == .mouseUp { buttonDown = false }
            pending.append(e)
            drain()
        }
    }

    /// The window got focus on the other Mac: get the app ready here, so the first click is
    /// not swallowed by activation.
    func prepareFocus() {
        guard !isPopup else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { AX.raise(pid: pid, wid: wid) }
    }

    // MARK: Keyboard (always straight to the app)

    private func injectKey(_ e: InputEvent) {
        if e.kind == .keyDown, !isPopup, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            AX.raise(pid: pid, wid: wid)
        }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let ev = CGEvent(keyboardEventSource: source, virtualKey: e.keyCode, keyDown: e.kind != .keyUp) else { return }
        if e.kind == .flags { ev.type = .flagsChanged }
        ev.flags = CGEventFlags(rawValue: e.flags)
        if e.isRepeat { ev.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        ev.postToPid(pid)
    }

    // MARK: Pointer

    private func drain() {
        guard !waiting else { return }
        while let e = pending.first {
            // Only the newest hover / drag position matters when events pile up.
            if (e.kind == .mouseMove || e.kind == .mouseDrag) && pending.count > 1 && pending[1].kind == e.kind {
                pending.removeFirst()
                continue
            }
            let starts = e.kind == .mouseDown || (e.kind == .scroll && !background)
            if starts && !ready(for: e) {
                waiting = true
                waitUntilReady(e, deadline: Date().addingTimeInterval(0.4))
                return
            }
            pending.removeFirst()
            if background {
                post(e, toApp: true)
            } else {
                if e.kind == .mouseMove && !isOnScreen() { continue } // don't pull a parked window out for hover
                if starts { showWindow?() }
                post(e, toApp: false)
            }
            if e.kind == .mouseDown { onActivity?(e.kind) }
        }
    }

    /// Background: the app must be active, otherwise AppKit uses the first click only to
    /// activate it. Cursor: the window must be on screen and on top under the pointer.
    private func ready(for e: InputEvent) -> Bool {
        if isPopup { return true }
        if background { return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
        guard let p = point(for: e), isOnScreen() else { return false }
        return WindowList.topmostWindow(at: p) == wid
    }

    private func waitUntilReady(_ e: InputEvent, deadline: Date) {
        if !background { showWindow?() }
        AX.raise(pid: pid, wid: wid)
        func check() {
            if ready(for: e) || Date() > deadline {
                // Let the window server finish the switch before the click lands.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                    self.waiting = false
                    self.drain()
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: check)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: check)
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

    private func post(_ e: InputEvent, toApp: Bool) {
        guard let b = WindowList.bounds(of: wid) else { return }
        let local = CGPoint(x: CGFloat(e.x) * b.width, y: CGFloat(e.y) * b.height)
        let global = CGPoint(x: b.minX + local.x, y: b.minY + local.y)
        let source = CGEventSource(stateID: .hidSystemState)
        let ev: CGEvent?
        if e.kind == .scroll {
            ev = CGEvent(scrollWheelEvent2Source: source, units: e.precise ? .pixel : .line, wheelCount: 2,
                         wheel1: Int32(e.dy), wheel2: Int32(e.dx), wheel3: 0)
            ev?.setIntegerValueField(Field.scrollIsContinuous, value: e.precise ? 1 : 0)
            ev?.setIntegerValueField(Field.scrollPhase, value: Int64(e.phase))
            ev?.setIntegerValueField(Field.momentumPhase, value: Int64(e.momentum))
        } else {
            let (type, button) = Self.mouseType(e)
            ev = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: global, mouseButton: button)
            if e.button >= 2 { ev?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(e.button)) }
            if e.kind != .mouseMove { ev?.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, e.clicks))) }
        }
        guard let ev else { return }
        if e.kind == .mouseDown { lastClick = global }
        ev.flags = CGEventFlags(rawValue: e.flags)
        // Order matters: setting `location` resets the window location.
        ev.location = global
        if toApp, let setWindowLocation = Self.setWindowLocation {
            // A sheet or dialog of the same app may sit on top of the window at that point.
            var target = wid, targetLocal = local
            if !isPopup, let (childID, childBounds) = WindowList.topmostWindow(of: pid, at: global), childID != wid {
                target = childID
                targetLocal = CGPoint(x: global.x - childBounds.minX, y: global.y - childBounds.minY)
            }
            setWindowLocation(ev, targetLocal)
            ev.setIntegerValueField(Field.windowNumber, value: Int64(target))
            ev.setIntegerValueField(Field.windowUnderPointer, value: Int64(target))
            ev.setIntegerValueField(Field.windowUnderPointerThatCanHandle, value: Int64(target))
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
