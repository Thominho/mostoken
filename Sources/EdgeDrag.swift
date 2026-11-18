import AppKit

/// Watches window drags. When a window is dragged so the pointer rests at the screen edge
/// facing the other Mac, the window is sent there (or, for a window that came from the other
/// Mac, given back).
final class EdgeDragMonitor {
    /// (window, its frame before the drag, crossing 0...1, grab point in points from window top-left)
    var onSend: ((WindowInfo, CGRect, Double, CGPoint) -> Void)?
    var onReturn: ((NSWindow, Double, CGPoint) -> Void)?
    var isRemoteWindow: ((NSWindow) -> Bool)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var timer: Timer?
    private var target: WindowInfo?
    private var localWindow: NSWindow?
    private var startFrame: CGRect?     // CG coordinates
    private var grab: CGPoint = .zero
    private var edgeSince: Date?

    private let dwell: TimeInterval = 0.25

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            self?.beginGlobal()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.beginLocal(event)
            return event
        }
    }

    private func beginGlobal() {
        guard Settings.edgeDrag else { return }
        let p = ScreenGeometry.toCG(NSEvent.mouseLocation)
        guard let w = WindowList.at(p) else { return }
        reset()
        target = w
        startFrame = w.bounds
        grab = CGPoint(x: p.x - w.bounds.minX, y: p.y - w.bounds.minY)
        startTimer()
    }

    private func beginLocal(_ event: NSEvent) {
        guard Settings.edgeDrag, let w = event.window, isRemoteWindow?(w) == true,
              let b = WindowList.bounds(of: CGWindowID(w.windowNumber)) else { return }
        reset()
        localWindow = w
        startFrame = b
        let p = ScreenGeometry.toCG(NSEvent.mouseLocation)
        grab = CGPoint(x: p.x - b.minX, y: p.y - b.minY)
        startTimer()
    }

    private func reset() {
        timer?.invalidate()
        timer = nil
        target = nil
        localWindow = nil
        startFrame = nil
        edgeSince = nil
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { reset(); return }
        guard let crossing = ScreenGeometry.crossing(at: NSEvent.mouseLocation, side: Settings.peerSide) else {
            edgeSince = nil
            return
        }
        if edgeSince == nil {
            // Only react to a window that is actually being moved (not resized, not a plain click).
            let wid = target?.wid ?? localWindow.map { CGWindowID($0.windowNumber) }
            guard let wid, let start = startFrame, let now = WindowList.bounds(of: wid),
                  abs(now.width - start.width) < 1, abs(now.height - start.height) < 1,
                  now.origin != start.origin else { return }
            edgeSince = Date()
            return
        }
        guard let since = edgeSince, Date().timeIntervalSince(since) >= dwell else { return }
        if let t = target, let start = startFrame {
            onSend?(t, start, crossing, grab)
        } else if let w = localWindow {
            onReturn?(w, crossing, grab)
        }
        reset()
    }
}
