import AppKit
import ApplicationServices

struct WindowInfo {
    let wid: CGWindowID
    let pid: pid_t
    let app: String
    let title: String
    /// Global coordinates, origin at the top-left of the primary screen (CoreGraphics space).
    let bounds: CGRect

    var label: String { title.isEmpty ? app : "\(app) — \(title)" }
}

enum WindowList {
    /// Normal windows of other apps, front to back.
    static func onScreen() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { d in
            guard let layer = d[kCGWindowLayer as String] as? Int, layer == 0,
                  let wid = d[kCGWindowNumber as String] as? CGWindowID,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let boundsDict = d[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 80, bounds.height >= 60 else { return nil }
            if let alpha = d[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { return nil }
            let app = d[kCGWindowOwnerName as String] as? String ?? "?"
            let title = d[kCGWindowName as String] as? String ?? ""
            return WindowInfo(wid: wid, pid: pid, app: app, title: title, bounds: bounds)
        }
    }

    static func bounds(of wid: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]],
              let d = list.first,
              let boundsDict = d[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
    }

    static func frontmost() -> WindowInfo? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return onScreen().first { $0.pid == pid }
    }

    static func at(_ point: CGPoint) -> WindowInfo? {
        onScreen().first { $0.bounds.contains(point) }
    }
}

enum ScreenGeometry {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// All screens of this Mac together (Cocoa coordinates).
    static var union: NSRect {
        NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
    }

    static func toCG(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }

    /// CoreGraphics top-left origin for a Cocoa frame.
    static func cgOrigin(of frame: NSRect) -> CGPoint { CGPoint(x: frame.minX, y: primaryHeight - frame.maxY) }

    /// If the pointer is at the outer edge facing `side`, returns how far along that edge it is (0...1).
    static func crossing(at p: NSPoint, side: Side) -> Double? {
        let u = union
        guard !u.isNull, u.width > 0, u.height > 0 else { return nil }
        let alongY = Double(min(max((u.maxY - p.y) / u.height, 0), 1))
        let alongX = Double(min(max((p.x - u.minX) / u.width, 0), 1))
        switch side {
        case .right: return p.x >= u.maxX - 2 ? alongY : nil
        case .left: return p.x <= u.minX + 1 ? alongY : nil
        case .top: return p.y >= u.maxY - 2 ? alongX : nil
        case .bottom: return p.y <= u.minY + 1 ? alongX : nil
        }
    }

    /// Frame (Cocoa coordinates) for a window entering this Mac from `side`, placed so that the
    /// grabbed point lines up with where the pointer crossed.
    static func entryFrame(size: NSSize, side: Side, crossing: Double?, grab: CGPoint?) -> NSRect {
        let c = CGFloat(crossing ?? 0.5)
        let g = grab ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let u = union
        let edgePoint: NSPoint
        switch side {
        case .left: edgePoint = NSPoint(x: u.minX, y: u.maxY - c * u.height)
        case .right: edgePoint = NSPoint(x: u.maxX, y: u.maxY - c * u.height)
        case .top: edgePoint = NSPoint(x: u.minX + c * u.width, y: u.maxY)
        case .bottom: edgePoint = NSPoint(x: u.minX + c * u.width, y: u.minY)
        }
        let screen = NSScreen.screens.min { distance($0.frame, edgePoint) < distance($1.frame, edgePoint) }
        let vf = screen?.visibleFrame ?? u
        let w = min(size.width, vf.width), h = min(size.height, vf.height)
        let margin: CGFloat = 8
        var origin = NSPoint.zero
        switch side {
        case .left:
            origin.x = vf.minX + margin
            origin.y = vf.maxY - c * vf.height + g.y - h
        case .right:
            origin.x = vf.maxX - w - margin
            origin.y = vf.maxY - c * vf.height + g.y - h
        case .top:
            origin.y = vf.maxY - h
            origin.x = vf.minX + c * vf.width - g.x
        case .bottom:
            origin.y = vf.minY + margin
            origin.x = vf.minX + c * vf.width - g.x
        }
        origin.x = min(max(origin.x, vf.minX), max(vf.minX, vf.maxX - w))
        origin.y = min(max(origin.y, vf.minY), max(vf.minY, vf.maxY - h))
        return NSRect(origin: origin, size: NSSize(width: w, height: h))
    }

    private static func distance(_ r: NSRect, _ p: NSPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }
}

/// While the left button stays down, keeps the grabbed point of a window under the pointer.
enum DragFollower {
    static func follow(grab: CGPoint, size: NSSize, move: @escaping (NSPoint) -> Void) {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
        let start = Date()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { timer in
            guard NSEvent.pressedMouseButtons & 1 != 0, Date().timeIntervalSince(start) < 15 else {
                timer.invalidate()
                return
            }
            let m = NSEvent.mouseLocation
            move(NSPoint(x: m.x - grab.x, y: m.y + grab.y - size.height))
        }
    }
}

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AX {
    static func window(pid: pid_t, wid: CGWindowID) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        for w in windows {
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(w, &id) == .success, id == wid { return w }
        }
        return nil
    }

    static func position(_ w: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ w: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &s) ? s : nil
    }

    static func setPosition(_ w: AXUIElement, _ point: CGPoint) {
        var p = point
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
    }

    static func setSize(_ w: AXUIElement, _ size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) }
    }

    static func raise(pid: pid_t, wid: CGWindowID) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let w = window(pid: pid, wid: wid) {
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        }
    }
}

enum Permissions {
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestMissing() {
        if !screenRecording { _ = CGRequestScreenCaptureAccess() }
        if !accessibility {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
    }

    static func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Small transient message near the bottom of the screen.
enum HUD {
    private static var panel: NSPanel?

    static func show(_ text: String) {
        panel?.orderOut(nil)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 36, height: label.frame.height + 20)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        let bg = NSView(frame: NSRect(origin: .zero, size: size))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        bg.layer?.cornerRadius = 11
        label.frame.origin = NSPoint(x: 18, y: 10)
        bg.addSubview(label)
        p.contentView = bg
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 70))
        }
        p.orderFrontRegardless()
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if panel === p {
                p.orderOut(nil)
                panel = nil
            }
        }
    }
}
