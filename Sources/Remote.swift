import AppKit
import AVFoundation

/// Shows the video of a window that lives on the other Mac and captures input for it.
final class RemoteVideoView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    let wid: UInt32
    var videoSize: NSSize
    var onInput: ((InputEvent) -> Void)?
    var onFilesDropped: (([URL]) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var lastMove: TimeInterval = 0
    private var remainderX: CGFloat = 0
    private var remainderY: CGFloat = 0

    init(wid: UInt32, videoSize: NSSize) {
        self.wid = wid
        self.videoSize = videoSize
        super.init(frame: NSRect(origin: .zero, size: videoSize))
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer = displayLayer
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: File drops (copied to the other Mac and opened in the window's app)

    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFiles(sender)
        guard !urls.isEmpty else { return false }
        onFilesDropped?(urls)
        return true
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Returns false when the decoder failed and needs a fresh keyframe.
    func enqueue(_ sample: CMSampleBuffer) -> Bool {
        if #available(macOS 14.0, *) {
            let renderer = displayLayer.sampleBufferRenderer
            if renderer.status == .failed {
                Log.write("Dekodér selhal: \(String(describing: renderer.error)) – žádám o nový klíčový snímek")
                renderer.flush()
                return false
            }
            renderer.enqueue(sample)
        } else {
            if displayLayer.status == .failed {
                displayLayer.flush()
                return false
            }
            displayLayer.enqueue(sample)
        }
        return true
    }

    // MARK: Input

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    private func videoRect() -> NSRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds }
        return AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
    }

    private func normalized(_ event: NSEvent) -> (Double, Double) {
        let p = convert(event.locationInWindow, from: nil)
        let r = videoRect()
        let x = min(max((p.x - r.minX) / max(r.width, 1), 0), 1)
        let y = min(max((p.y - r.minY) / max(r.height, 1), 0), 1)
        return (Double(x), Double(y))
    }

    static func flags(_ e: NSEvent) -> UInt64 {
        UInt64(e.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
    }

    private func mouse(_ kind: InputEvent.Kind, _ e: NSEvent, button: Int) {
        let (x, y) = normalized(e)
        var ev = InputEvent(wid: wid, kind: kind)
        ev.x = x
        ev.y = y
        ev.button = button
        ev.clicks = e.clickCount
        ev.flags = Self.flags(e)
        onInput?(ev)
    }

    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); mouse(.mouseDown, e, button: 0) }
    override func mouseUp(with e: NSEvent) { mouse(.mouseUp, e, button: 0) }
    override func mouseDragged(with e: NSEvent) { mouse(.mouseDrag, e, button: 0) }
    override func rightMouseDown(with e: NSEvent) { window?.makeFirstResponder(self); mouse(.mouseDown, e, button: 1) }
    override func rightMouseUp(with e: NSEvent) { mouse(.mouseUp, e, button: 1) }
    override func rightMouseDragged(with e: NSEvent) { mouse(.mouseDrag, e, button: 1) }
    override func otherMouseDown(with e: NSEvent) { mouse(.mouseDown, e, button: max(2, e.buttonNumber)) }
    override func otherMouseUp(with e: NSEvent) { mouse(.mouseUp, e, button: max(2, e.buttonNumber)) }
    override func otherMouseDragged(with e: NSEvent) { mouse(.mouseDrag, e, button: max(2, e.buttonNumber)) }

    override func mouseMoved(with e: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMove > 1.0 / 60 else { return }
        lastMove = now
        let (x, y) = normalized(e)
        var ev = InputEvent(wid: wid, kind: .mouseMove)
        ev.x = x
        ev.y = y
        ev.flags = Self.flags(e)
        onInput?(ev)
    }

    override func scrollWheel(with e: NSEvent) {
        let (x, y) = normalized(e)
        var ev = InputEvent(wid: wid, kind: .scroll)
        ev.x = x
        ev.y = y
        ev.precise = e.hasPreciseScrollingDeltas
        if e.hasPreciseScrollingDeltas {
            remainderX += e.scrollingDeltaX
            remainderY += e.scrollingDeltaY
            let ix = remainderX.rounded(.towardZero), iy = remainderY.rounded(.towardZero)
            remainderX -= ix
            remainderY -= iy
            ev.dx = Double(ix)
            ev.dy = Double(iy)
        } else {
            func lines(_ v: CGFloat) -> Double { v == 0 ? 0 : (abs(v) < 1 ? (v > 0 ? 1 : -1) : Double(v.rounded())) }
            ev.dx = lines(e.scrollingDeltaX)
            ev.dy = lines(e.scrollingDeltaY)
        }
        ev.phase = Self.scrollPhase(e.phase)
        ev.momentum = Self.momentumPhase(e.momentumPhase)
        ev.flags = Self.flags(e)
        onInput?(ev)
    }

    private static func scrollPhase(_ p: NSEvent.Phase) -> Int {
        if p.contains(.began) { return 1 }
        if p.contains(.changed) { return 2 }
        if p.contains(.ended) { return 4 }
        if p.contains(.cancelled) { return 8 }
        if p.contains(.mayBegin) { return 128 }
        return 0
    }

    private static func momentumPhase(_ p: NSEvent.Phase) -> Int {
        if p.contains(.began) { return 1 }
        if p.contains(.changed) { return 2 }
        if p.contains(.ended) || p.contains(.cancelled) { return 3 }
        return 0
    }

    override func keyDown(with e: NSEvent) { key(.keyDown, e) }
    override func keyUp(with e: NSEvent) { key(.keyUp, e) }
    override func flagsChanged(with e: NSEvent) { key(.flags, e) }

    /// ⌘-shortcuts (⌘C, ⌘V, ⌘W…) belong to the remote app, not to MostOken.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.type == .keyDown, window?.isKeyWindow == true, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: e)
        }
        key(.keyDown, e)
        key(.keyUp, e)
        return true
    }

    private func key(_ kind: InputEvent.Kind, _ e: NSEvent) {
        var ev = InputEvent(wid: wid, kind: kind)
        ev.keyCode = e.keyCode
        ev.flags = Self.flags(e)
        if kind == .keyDown { ev.isRepeat = e.isARepeat }
        onInput?(ev)
    }
}

/// A window on this Mac that mirrors (and controls) a window running on the other Mac.
final class RemoteWindowController: NSObject, NSWindowDelegate {
    let wid: UInt32
    weak var peer: PeerConnection?
    let window: NSWindow
    let videoView: RemoteVideoView
    let title: String
    var onClosed: ((RemoteWindowController) -> Void)?
    private(set) var framesShown = 0

    private var format: CMVideoFormatDescription?
    private var waitingForKey = true
    private var closingFromRemote = false
    private var lastKeyRequest = Date.distantPast
    private var returnInfo: ReturnWindow?
    private let grab: CGPoint?

    init(open o: WindowOpen, peer: PeerConnection) {
        wid = o.wid
        self.peer = peer
        title = o.title.isEmpty ? o.app : "\(o.app) — \(o.title)"
        let size = NSSize(width: max(160, o.width), height: max(100, o.height))
        if let gx = o.grabX, let gy = o.grabY { grab = CGPoint(x: gx, y: gy) } else { grab = nil }
        videoView = RemoteVideoView(wid: o.wid, videoSize: size)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "\(title) (z: \(peer.peerName))"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.tabbingMode = .disallowed
        window.contentView = videoView
        window.delegate = self
        videoView.onInput = { [weak self] e in self?.peer?.send(Wire.json(.input, e)) }
        // Enter from the edge facing the Mac it came from, where the pointer crossed.
        let frame = ScreenGeometry.entryFrame(size: size, side: Settings.peerSide, crossing: o.crossing, grab: grab)
        window.setFrame(window.frameRect(forContentRect: frame), display: false)
    }

    func show() {
        window.orderFrontRegardless()
        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(videoView)
        // If the drag continues on this Mac (Universal Control carried the pointer over),
        // keep the window under the pointer until the button is released.
        if let g = grab {
            let size = window.frame.size
            DragFollower.follow(grab: g, size: size) { [weak self] origin in
                self?.window.setFrameOrigin(origin)
            }
        }
    }

    func handleFrame(_ f: VideoFrame) {
        if f.isKey, f.parameterSets.count >= 2 {
            format = H264.makeFormat(f.parameterSets)
            waitingForKey = false
        }
        guard !waitingForKey, let format else { requestKeyframe(); return }
        guard let sample = H264.makeSampleBuffer(f.data, format: format) else { return }
        if !videoView.enqueue(sample) {
            waitingForKey = true
            requestKeyframe()
            return
        }
        framesShown += 1
        if framesShown == 1 { Log.write("Okno \(wid) „\(title)“ se zobrazuje") }
    }

    private func requestKeyframe() {
        guard Date().timeIntervalSince(lastKeyRequest) > 0.5 else { return }
        lastKeyRequest = Date()
        peer?.send(Wire.json(.keyframeRequest, WindowRef(wid: wid)))
    }

    func applyGeometry(_ g: Geometry) {
        let size = NSSize(width: g.width, height: g.height)
        videoView.videoSize = size
        guard !window.inLiveResize, !window.styleMask.contains(.fullScreen) else { return }
        let current = videoView.bounds.size
        guard abs(current.width - size.width) > 1 || abs(current.height - size.height) > 1 else { return }
        var frame = window.frame
        let top = frame.maxY
        frame.size = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: true, animate: false)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        let s = videoView.bounds.size
        peer?.send(Wire.json(.resizeRequest, Geometry(wid: wid, width: Double(s.width), height: Double(s.height))))
    }

    func windowWillClose(_ notification: Notification) {
        if !closingFromRemote {
            peer?.send(Wire.json(.returnWindow, returnInfo ?? ReturnWindow(wid: wid)))
        }
        onClosed?(self)
    }

    func closeFromRemote() {
        closingFromRemote = true
        window.close()
    }

    /// Give the window back. With `crossing`, it reappears on the other Mac at that edge position.
    func returnToOrigin(crossing: Double? = nil, grab: CGPoint? = nil) {
        returnInfo = ReturnWindow(wid: wid, crossing: crossing,
                                  grabX: grab.map { Double($0.x) }, grabY: grab.map { Double($0.y) })
        window.close()
    }
}
