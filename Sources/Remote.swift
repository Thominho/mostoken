import AppKit
import AVFoundation

/// A window without any title bar of its own: the captured window already has one.
final class RemoteWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Menus and other pop-ups: float above everything and never take keyboard focus.
final class RemotePopupPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows the video of a window that lives on the other Mac and turns local mouse/keyboard
/// input into input for that window.
///
/// The captured window brings its own title bar, so:
/// - dragging in the title bar area moves this window (a plain click there still goes through,
///   so buttons in the title bar work); a double-click zooms it,
/// - the window's own yellow / green buttons minimize / zoom this window, the red one closes
///   the real window,
/// - everything else is forwarded.
final class RemoteVideoView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    let wid: UInt32
    let isPopup: Bool
    var videoSize: NSSize { didSet { needsLayout = true } }
    var chrome: Chrome? { didSet { needsLayout = true } }
    var onInput: ((InputEvent) -> Void)?
    var onFilesDropped: (([URL]) -> Void)?
    var onLocalMinimize: (() -> Void)?
    var onLocalZoom: (() -> Void)?
    var onCloseRequest: (() -> Void)?
    /// Real traffic-light buttons over the captured ones (macOS may cover those with its
    /// "window is being shared" badge).
    private var buttons: [NSButton] = []
    /// Screen position of the last click, to place menus the click opens.
    private(set) var lastClickScreen: NSPoint?

    private var trackingArea: NSTrackingArea?
    private var lastMove: TimeInterval = 0
    private var remainderX: CGFloat = 0
    private var remainderY: CGFloat = 0
    private var pendingTitleDown: NSEvent?
    private var movingWindow = false

    init(wid: UInt32, videoSize: NSSize, isPopup: Bool) {
        self.wid = wid
        self.videoSize = videoSize
        self.isPopup = isPopup
        super.init(frame: NSRect(origin: .zero, size: videoSize))
        displayLayer.videoGravity = .resizeAspect
        wantsLayer = true
        layer?.addSublayer(displayLayer)
        displayLayer.frame = bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        setTransparent(true)
        if !isPopup { registerForDraggedTypes([.fileURL]) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// HEVC with alpha brings the window's real shape; H.264 needs a rounded opaque backing.
    func setTransparent(_ transparent: Bool) {
        displayLayer.backgroundColor = transparent ? NSColor.clear.cgColor : NSColor.windowBackgroundColor.cgColor
        displayLayer.cornerRadius = transparent ? 0 : (isPopup ? 6 : 10)
        displayLayer.masksToBounds = !transparent
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { !isPopup }
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

    // MARK: Geometry

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
        layoutButtons()
    }

    private func layoutButtons() {
        guard !isPopup, let chrome else { buttons.forEach { $0.isHidden = true }; return }
        let kinds: [(NSWindow.ButtonType, [Double]?)] = [(.closeButton, chrome.close), (.miniaturizeButton, chrome.minimize),
                                                         (.zoomButton, chrome.zoom)]
        if buttons.isEmpty {
            for (type, _) in kinds {
                guard let b = NSWindow.standardWindowButton(type, for: [.titled, .closable, .miniaturizable, .resizable]) else { continue }
                b.target = self
                b.action = #selector(buttonPressed(_:))
                b.tag = Int(type.rawValue)
                addSubview(b)
                buttons.append(b)
            }
        }
        for b in buttons {
            guard let r = kinds.first(where: { Int($0.0.rawValue) == b.tag })?.1, let rect = viewRect(r)?.insetBy(dx: 3, dy: 3) else {
                b.isHidden = true
                continue
            }
            b.isHidden = false
            let s = b.frame.size
            b.setFrameOrigin(NSPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2))
        }
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        switch NSWindow.ButtonType(rawValue: UInt(sender.tag)) {
        case .closeButton: onCloseRequest?()
        case .miniaturizeButton: onLocalMinimize?()
        case .zoomButton: onLocalZoom?()
        default: break
        }
    }

    private var videoRect: NSRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds }
        return AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
    }

    /// Points of the original window per point of this view.
    private var videoScale: CGFloat { videoRect.width / max(videoSize.width, 1) }

    private func normalized(_ p: NSPoint) -> (Double, Double) {
        let r = videoRect
        let x = min(max((p.x - r.minX) / max(r.width, 1), 0), 1)
        let y = min(max((p.y - r.minY) / max(r.height, 1), 0), 1)
        return (Double(x), Double(y))
    }

    private func viewRect(_ r: [Double]?) -> NSRect? {
        guard let r, r.count == 4 else { return nil }
        let vr = videoRect, s = videoScale
        return NSRect(x: vr.minX + CGFloat(r[0]) * s, y: vr.minY + CGFloat(r[1]) * s,
                      width: CGFloat(r[2]) * s, height: CGFloat(r[3]) * s).insetBy(dx: -3, dy: -3)
    }

    private func inTitleZone(_ p: NSPoint) -> Bool {
        p.y - videoRect.minY < CGFloat(chrome?.titleHeight ?? 30) * videoScale
    }

    private func local(_ e: NSEvent) -> NSPoint { convert(e.locationInWindow, from: nil) }

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

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    static func flags(_ e: NSEvent) -> UInt64 {
        UInt64(e.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
    }

    private func send(_ kind: InputEvent.Kind, _ e: NSEvent, button: Int) {
        let (x, y) = normalized(local(e))
        var ev = InputEvent(wid: wid, kind: kind)
        ev.x = x
        ev.y = y
        ev.button = button
        ev.clicks = e.clickCount
        ev.flags = Self.flags(e)
        onInput?(ev)
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        lastClickScreen = NSEvent.mouseLocation
        movingWindow = false
        pendingTitleDown = nil
        if !isPopup {
            let p = local(e)
            if inTitleZone(p) {
                if e.clickCount == 2 { onLocalZoom?(); return }
                // Wait: a drag moves this window, a plain click goes through on mouse-up.
                pendingTitleDown = e
                return
            }
        }
        send(.mouseDown, e, button: 0)
    }

    override func mouseDragged(with e: NSEvent) {
        if let down = pendingTitleDown {
            let d = hypot(e.locationInWindow.x - down.locationInWindow.x, e.locationInWindow.y - down.locationInWindow.y)
            if d > 3 {
                pendingTitleDown = nil
                movingWindow = true
                window?.performDrag(with: down)
            }
            return
        }
        if movingWindow { return }
        send(.mouseDrag, e, button: 0)
    }

    override func mouseUp(with e: NSEvent) {
        if let down = pendingTitleDown {
            pendingTitleDown = nil
            send(.mouseDown, down, button: 0)
            send(.mouseUp, e, button: 0)
            return
        }
        if movingWindow {
            movingWindow = false
            return
        }
        send(.mouseUp, e, button: 0)
    }

    override func rightMouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        lastClickScreen = NSEvent.mouseLocation
        send(.mouseDown, e, button: 1)
    }
    override func rightMouseUp(with e: NSEvent) { send(.mouseUp, e, button: 1) }
    override func rightMouseDragged(with e: NSEvent) { send(.mouseDrag, e, button: 1) }
    override func otherMouseDown(with e: NSEvent) { send(.mouseDown, e, button: max(2, e.buttonNumber)) }
    override func otherMouseUp(with e: NSEvent) { send(.mouseUp, e, button: max(2, e.buttonNumber)) }
    override func otherMouseDragged(with e: NSEvent) { send(.mouseDrag, e, button: max(2, e.buttonNumber)) }

    override func mouseMoved(with e: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMove > 1.0 / 60 else { return }
        lastMove = now
        let (x, y) = normalized(local(e))
        var ev = InputEvent(wid: wid, kind: .mouseMove)
        ev.x = x
        ev.y = y
        ev.flags = Self.flags(e)
        onInput?(ev)
    }

    override func scrollWheel(with e: NSEvent) {
        let (x, y) = normalized(local(e))
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

    // MARK: Keyboard

    override func keyDown(with e: NSEvent) { key(.keyDown, e) }
    override func keyUp(with e: NSEvent) { key(.keyUp, e) }
    override func flagsChanged(with e: NSEvent) { key(.flags, e) }

    /// ⌘-shortcuts belong to the remote app (⌘C, ⌘V, ⌘W…), except the ones about this window
    /// itself: ⌘M minimizes it here, ⌘H is ignored (it would hide the app on the other Mac).
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.type == .keyDown, window?.isKeyWindow == true, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: e)
        }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command && chars == "m" { onLocalMinimize?(); return true }
        if flags == .command && chars == "h" { return true }
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

/// A window on this Mac that shows (and controls) a window running on the other Mac.
final class RemoteWindowController: NSObject, NSWindowDelegate {
    let wid: UInt32
    let parentWid: UInt32?
    var isPopup: Bool { parentWid != nil }
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
    private var zoomedFrom: NSRect?
    private var lastVisible: Bool?
    private var lastScale: CGFloat = 0
    private var styledForAlpha: Bool?

    init(open o: WindowOpen, peer: PeerConnection, anchor: NSPoint?) {
        wid = o.wid
        parentWid = o.parent
        self.peer = peer
        title = o.title.isEmpty ? o.app : "\(o.app) — \(o.title)"
        let isPopup = o.parent != nil
        let size = NSSize(width: max(isPopup ? 8 : 160, o.width), height: max(isPopup ? 8 : 100, o.height))
        if let gx = o.grabX, let gy = o.grabY { grab = CGPoint(x: gx, y: gy) } else { grab = nil }
        videoView = RemoteVideoView(wid: o.wid, videoSize: size, isPopup: isPopup)
        videoView.chrome = o.chrome

        if isPopup {
            let panel = RemotePopupPanel(contentRect: NSRect(origin: .zero, size: size),
                                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .popUpMenu
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            window = panel
        } else {
            let w = RemoteWindow(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = false
            w.tabbingMode = .disallowed
            // No title bar of our own at all: the captured window shows its own.
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                w.standardWindowButton(b)?.isHidden = true
            }
            w.standardWindowButton(.closeButton)?.superview?.superview?.isHidden = true
            window = w
        }
        super.init()
        window.title = "\(title) (z: \(peer.peerName))"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.contentView = videoView
        window.delegate = self
        videoView.onInput = { [weak self] e in self?.peer?.send(Wire.json(.input, e)) }
        videoView.onLocalMinimize = { [weak self] in self?.window.miniaturize(nil) }
        videoView.onLocalZoom = { [weak self] in self?.toggleZoom() }
        videoView.onCloseRequest = { [weak self] in
            guard let self else { return }
            self.peer?.send(Wire.json(.closeWindow, WindowRef(wid: self.wid)))
        }

        if isPopup {
            window.setFrame(popupFrame(size: size, open: o, anchor: anchor), display: false)
        } else {
            // Enter from the edge facing the Mac it came from, where the pointer crossed.
            let frame = ScreenGeometry.entryFrame(size: size, side: Settings.peerSide, crossing: o.crossing, grab: grab)
            window.setFrame(frame, display: false)
        }
    }

    /// Menus open next to where the person clicked on this Mac, like they would on the other one.
    private func popupFrame(size: NSSize, open o: WindowOpen, anchor: NSPoint?) -> NSRect {
        let point = anchor ?? NSEvent.mouseLocation
        var dx: CGFloat = 1, dy: CGFloat = 1
        if let ox = o.offsetX, let oy = o.offsetY, abs(ox) < 600, abs(oy) < 600 {
            dx = CGFloat(ox)
            dy = CGFloat(oy)
        }
        var frame = NSRect(x: point.x + dx, y: point.y - dy - size.height, width: size.width, height: size.height)
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, vf.minX), vf.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, vf.minY), vf.maxY - frame.height)
        }
        return frame
    }

    func show() {
        if isPopup {
            window.orderFrontRegardless()
        } else {
            window.orderFrontRegardless()
            window.makeKey()
            NSApp.activate(ignoringOtherApps: true)
            window.makeFirstResponder(videoView)
            // If the drag continues on this Mac (Universal Control carried the pointer over),
            // keep the window under the pointer until the button is released.
            if let g = grab {
                let size = window.frame.size
                DragFollower.follow(grab: g, size: size) { [weak self] origin in self?.window.setFrameOrigin(origin) }
            }
            // The original did not fit this screen: make it the size it is shown at here.
            if abs(window.frame.width - videoView.videoSize.width) > 1 || abs(window.frame.height - videoView.videoSize.height) > 1 {
                sendResizeRequest()
            }
        }
        sendViewInfo()
    }

    private func sendViewInfo() {
        let scale = window.backingScaleFactor
        guard scale != lastScale else { return }
        lastScale = scale
        peer?.send(Wire.json(.viewInfo, ViewInfo(wid: wid, scale: Double(scale))))
    }

    private func sendVisibility() {
        let visible = window.occlusionState.contains(.visible) && !window.isMiniaturized
        guard visible != lastVisible else { return }
        lastVisible = visible
        peer?.send(Wire.json(.visibility, Visibility(wid: wid, visible: visible)))
    }

    private func sendResizeRequest() {
        let s = window.frame.size
        peer?.send(Wire.json(.resizeRequest, Geometry(wid: wid, width: Double(s.width), height: Double(s.height))))
    }

    func handleFrame(_ f: VideoFrame) {
        if f.isKey, let fmt = VideoFormat.from(f) {
            format = fmt
            waitingForKey = false
        }
        guard !waitingForKey, let format else { requestKeyframe(); return }
        if styledForAlpha != f.isHEVC {
            styledForAlpha = f.isHEVC
            videoView.setTransparent(f.isHEVC)
        }
        guard let sample = H264.makeSampleBuffer(f.data, format: format) else { return }
        if !videoView.enqueue(sample) {
            waitingForKey = true
            requestKeyframe()
            return
        }
        framesShown += 1
        if framesShown == 1 { Log.write("\(isPopup ? "Nabídka" : "Okno") \(wid) „\(title)“ se zobrazuje (\(f.isHEVC ? "HEVC" : "H.264"))") }
        // The shadow follows the window's shape, which is known only once pixels arrive.
        if framesShown == 2 || framesShown == 30 { window.invalidateShadow() }
    }

    private func requestKeyframe() {
        guard Date().timeIntervalSince(lastKeyRequest) > 0.5 else { return }
        lastKeyRequest = Date()
        peer?.send(Wire.json(.keyframeRequest, WindowRef(wid: wid)))
    }

    func applyGeometry(_ g: Geometry) {
        let size = NSSize(width: g.width, height: g.height)
        videoView.videoSize = size
        if let c = g.chrome { videoView.chrome = c }
        guard !window.inLiveResize, !window.styleMask.contains(.fullScreen) else { return }
        let current = window.frame.size
        guard abs(current.width - size.width) > 1 || abs(current.height - size.height) > 1 else { return }
        var frame = window.frame
        let top = frame.maxY
        frame.size = size
        frame.origin.y = top - size.height
        window.setFrame(frame, display: true, animate: false)
        window.invalidateShadow()
    }

    private func toggleZoom() {
        guard let screen = window.screen ?? NSScreen.main else { return }
        if let previous = zoomedFrom {
            zoomedFrom = nil
            window.setFrame(previous, display: true, animate: true)
        } else {
            zoomedFrom = window.frame
            window.setFrame(screen.visibleFrame, display: true, animate: true)
        }
        sendResizeRequest()
    }

    // MARK: NSWindowDelegate

    func windowDidEndLiveResize(_ notification: Notification) { sendResizeRequest() }
    func windowDidBecomeKey(_ notification: Notification) {
        peer?.send(Wire.json(.focus, WindowRef(wid: wid)))
    }
    func windowDidChangeOcclusionState(_ notification: Notification) { sendVisibility() }
    func windowDidMiniaturize(_ notification: Notification) { sendVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { sendVisibility() }
    func windowDidChangeBackingProperties(_ notification: Notification) { sendViewInfo() }
    func windowDidChangeScreen(_ notification: Notification) { sendViewInfo() }

    func windowWillClose(_ notification: Notification) {
        if !closingFromRemote && !isPopup {
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
