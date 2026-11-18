import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreImage

/// Captures one window on this Mac, encodes it and streams it to the other Mac, and replays the
/// other Mac's mouse/keyboard input into it. Menus and other pop-ups of the same app get their
/// own (child) streamer.
final class WindowStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    let info: WindowInfo
    var wid: CGWindowID { info.wid }
    weak var peer: PeerConnection?
    /// Set for pop-up windows (menus…): the window they belong to.
    let parentWid: CGWindowID?
    var isPopup: Bool { parentWid != nil }
    var onEnded: ((WindowStreamer) -> Void)?
    /// The set of pop-up windows of this app changed.
    var onPopups: ((WindowStreamer, [WindowInfo]) -> Void)?
    let injector: InputInjector
    let codec: VideoCodec

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "mostoken.capture", qos: .userInteractive)

    // Confined to `queue`.
    private var encoder: VideoEncoder?
    private let flattener: Flattener?
    private var forceKey = true
    private var lastBuffer: CVPixelBuffer?
    private var lastEncodedIsCurrent = true
    private var framesSent = 0
    private var bytesSent = 0
    private var framesDropped = 0
    private var paused = false

    // Frames handed to the network but not yet sent (any thread).
    private let flightLock = NSLock()
    private var inFlight = 0
    private let maxInFlight = 3

    // Confined to the main thread.
    private var size: CGSize
    private var nativeScale: CGFloat = 2
    private var receiverScale: CGFloat?
    private var pollTimer: Timer?
    private var parkTimer: Timer?
    private var reparkTimer: Timer?
    private var restoreOrigin: CGPoint?
    private var stopped = false
    private var lastStats = Date()
    private var shownForInput = false
    private var lastPointerInput = Date()
    private var knownPopups: Set<CGWindowID> = []
    private var popupWatchUntil = Date.distantPast

    init(info: WindowInfo, peer: PeerConnection, parent: CGWindowID? = nil) {
        self.info = info
        self.peer = peer
        self.parentWid = parent
        self.size = info.bounds.size
        let alpha = peer.capabilities.contains(Capability.hevcAlpha) && VideoEncoder.hevcAlphaSupported
        self.codec = alpha ? .hevcAlpha : .h264
        self.flattener = alpha ? nil : Flattener(background: WindowStreamer.windowBackground())
        self.injector = InputInjector(pid: info.pid, wid: info.wid, isPopup: parent != nil)
        super.init()
        injector.showWindow = { [weak self] in self?.showForInput() }
        injector.onActivity = { [weak self] _ in self?.watchForPopups() }
    }

    private static func windowBackground() -> CIColor {
        var color = CIColor(red: 0.93, green: 0.93, blue: 0.93)
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let rgb = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) {
                color = CIColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
            }
        }
        return color
    }

    private static func screenScale(for cgRect: CGRect) -> CGFloat {
        let h = ScreenGeometry.primaryHeight
        let cocoa = NSRect(x: cgRect.minX, y: h - cgRect.maxY, width: cgRect.width, height: cgRect.height)
        let screen = NSScreen.screens.max { $0.frame.intersection(cocoa).width * $0.frame.intersection(cocoa).height
            < $1.frame.intersection(cocoa).width * $1.frame.intersection(cocoa).height }
        return screen?.backingScaleFactor ?? 2
    }

    /// Never capture more pixels than the other Mac's screen can show.
    private var scale: CGFloat { min(nativeScale, receiverScale ?? nativeScale) }

    // MARK: Capture

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scWindow = content.windows.first(where: { $0.windowID == wid }) else {
            throw NSError(domain: "MostOken", code: 1, userInfo: [NSLocalizedDescriptionKey: "Okno se nepodařilo najít."])
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let native: CGFloat
        if #available(macOS 14.0, *) {
            native = CGFloat(filter.pointPixelScale)
        } else {
            native = Self.screenScale(for: info.bounds)
        }
        let config = await MainActor.run { () -> SCStreamConfiguration in
            self.nativeScale = native
            return self.makeConfig(self.size)
        }
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        await MainActor.run {
            if self.stopped {
                s.stopCapture(completionHandler: nil)
                return
            }
            self.stream = s
            self.pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
            Log.write("Zachytávám \(self.isPopup ? "nabídku" : "okno") \(self.wid) (\(Int(self.size.width))×\(Int(self.size.height)) bodů, \(native)×, \(self.codec == .hevcAlpha ? "HEVC s průhledností" : "H.264"))")
        }
    }

    private func makeConfig(_ size: CGSize) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = max(16, Int((size.width * scale).rounded()) / 2 * 2)
        c.height = max(16, Int((size.height * scale).rounded()) / 2 * 2)
        c.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = false
        c.queueDepth = 4
        c.colorSpaceName = CGColorSpace.sRGB
        if #available(macOS 14.0, *) { c.ignoreShadowsSingleWindow = true }
        if #available(macOS 14.2, *) { c.includeChildWindows = true }
        return c
    }

    private func reconfigure() {
        stream?.updateConfiguration(makeConfig(size)) { error in
            if let error { Log.write("Změna zachytávání selhala: \(error.localizedDescription)") }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let frame = flattener.map { $0.flatten(pixelBuffer) } ?? pixelBuffer
        guard let frame else { return }
        lastBuffer = frame
        lastEncodedIsCurrent = false
        encode(frame)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("Zachytávání okna \(wid) skončilo: \(error.localizedDescription)")
        DispatchQueue.main.async {
            if !self.stopped { self.onEnded?(self) }
        }
    }

    private var framesInFlight: Int {
        flightLock.lock(); defer { flightLock.unlock() }
        return inFlight
    }

    /// Must run on `queue`.
    private func encode(_ pixelBuffer: CVPixelBuffer) {
        guard let peer, !paused else { return }
        // Keep the queue short so latency never builds up; a skipped frame is simply replaced
        // by the next one (the encoder never saw it, so nothing has to be resynced).
        if framesInFlight >= maxInFlight {
            framesDropped += 1
            return
        }
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        if encoder == nil || encoder?.width != w || encoder?.height != h {
            encoder?.invalidate()
            let wid = self.wid, hevc = codec == .hevcAlpha
            encoder = VideoEncoder(width: w, height: h, codec: codec) { [weak self] data, isKey, sets in
                guard let self, let peer = self.peer else { return }
                let packet = Wire.pack(.frame, VideoFrame(wid: wid, isKey: isKey, parameterSets: sets, data: data,
                                                          isHEVC: hevc).encoded())
                self.flightLock.lock(); self.inFlight += 1; self.flightLock.unlock()
                peer.send(packet) { [weak self] in
                    guard let self else { return }
                    self.flightLock.lock(); self.inFlight -= 1; self.flightLock.unlock()
                }
                self.queue.async {
                    self.framesSent += 1
                    self.bytesSent += packet.count
                }
            }
            forceKey = true
        }
        let key = forceKey
        forceKey = false
        lastEncodedIsCurrent = true
        encoder?.encode(pixelBuffer, forceKey: key)
    }

    func requestKeyframe() {
        queue.async { [weak self] in
            guard let self else { return }
            self.forceKey = true
            if let pb = self.lastBuffer { self.encode(pb) }
        }
    }

    /// The other Mac shows the window on a screen with this backing scale.
    func setReceiverScale(_ s: CGFloat) {
        let clamped = min(max(s, 1), 3)
        guard clamped != receiverScale else { return }
        receiverScale = clamped
        reconfigure()
        Log.write("Okno \(wid): zachytávám v rozlišení \(scale)× (druhý Mac má \(clamped)×)")
    }

    /// Nothing is visible on the other Mac (minimized, covered): stop encoding.
    func setVisible(_ visible: Bool) {
        queue.async {
            guard self.paused == visible else { return }
            self.paused = !visible
            if visible {
                self.forceKey = true
                if let pb = self.lastBuffer { self.encode(pb) }
            }
        }
    }

    /// Saves the last captured frame as PNG (used by the automatic test).
    func snapshot(to url: URL, completion: @escaping (Bool) -> Void) {
        queue.async {
            var ok = false
            if let pb = self.lastBuffer, let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
                let image = CIImage(cvPixelBuffer: pb)
                ok = (try? CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: srgb)) != nil
            }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    private func poll() {
        guard !stopped else { return }
        guard let b = WindowList.bounds(of: wid) else {
            Log.write("\(isPopup ? "Nabídka" : "Okno") \(wid) zmizelo")
            onEnded?(self)
            return
        }
        if abs(b.width - size.width) > 0.5 || abs(b.height - size.height) > 0.5 {
            size = b.size
            reconfigure()
            peer?.send(Wire.json(.geometry, Geometry(wid: wid, width: Double(b.width), height: Double(b.height),
                                                     chrome: isPopup ? nil : AX.chrome(pid: info.pid, wid: wid))))
            if restoreOrigin != nil && !shownForInput && Settings.peerSide != .right { park() }
        }
        // Static windows produce no new frames: catch up on a skipped or owed frame.
        queue.async { [weak self] in
            guard let self, !self.paused, let pb = self.lastBuffer, self.framesInFlight == 0,
                  self.forceKey || !self.lastEncodedIsCurrent else { return }
            self.encode(pb)
        }
        if !isPopup && (!knownPopups.isEmpty || Date() < popupWatchUntil) { scanPopups() }
        if Date().timeIntervalSince(lastStats) > 10 {
            lastStats = Date()
            queue.async {
                Log.write("Okno \(self.wid): odesláno \(self.framesSent) snímků (\(self.bytesSent / 1024) kB), vynecháno \(self.framesDropped)")
            }
        }
    }

    // MARK: Menus and other pop-ups

    /// After a click or key press a menu may open; look for it a few times.
    private func watchForPopups() {
        guard !isPopup else { return }
        popupWatchUntil = Date().addingTimeInterval(1.5)
        for delay in [0.06, 0.15, 0.3, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.scanPopups() }
        }
    }

    private func scanPopups() {
        guard !stopped, !isPopup else { return }
        let popups = WindowList.popups(of: info.pid)
        let ids = Set(popups.map(\.wid))
        guard ids != knownPopups else { return }
        knownPopups = ids
        onPopups?(self, popups)
    }

    // MARK: Moving the original window out of the way

    /// Slides the original window almost completely off the screen edge facing the other Mac,
    /// leaving a thin strip visible (fully hidden windows may stop rendering).
    func park() {
        guard !isPopup else { return }
        guard let ax = AX.window(pid: info.pid, wid: wid), let pos = AX.position(ax), let sz = AX.size(ax) else {
            Log.write("Původní okno nejde odsunout (chybí oprávnění Zpřístupnění?)")
            return
        }
        if restoreOrigin == nil { restoreOrigin = pos }
        let u = ScreenGeometry.union
        let strip: CGFloat = 36
        var target = pos
        switch Settings.peerSide {
        case .right: target.x = u.maxX - strip
        case .left: target.x = u.minX - sz.width + strip
        case .bottom, .top:
            // A window cannot go above the menu bar, so "top" also parks at the bottom edge.
            target.y = ScreenGeometry.primaryHeight - u.minY - strip
        }
        AX.setPosition(ax, target)
    }

    /// After an edge drag: wait for the mouse button to be released (macOS may tile the window
    /// on drop), then restore the original size and park it.
    func park(afterDragFrom original: CGRect) {
        parkTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if NSEvent.pressedMouseButtons & 1 != 0 { return }
            timer.invalidate()
            self.parkTimer = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard !self.stopped, let ax = AX.window(pid: self.info.pid, wid: self.wid) else { return }
                AX.setSize(ax, original.size)
                if Settings.parkOriginal {
                    self.restoreOrigin = original.origin
                    self.park()
                } else {
                    AX.setPosition(ax, original.origin)
                }
            }
        }
    }

    /// Cursor mode only: put a parked window back on screen so a click can land on it, and
    /// park it again after a few seconds without clicks.
    private func showForInput() {
        lastPointerInput = Date()
        if let origin = restoreOrigin, !shownForInput, let ax = AX.window(pid: info.pid, wid: wid) {
            AX.setPosition(ax, origin)
            shownForInput = true
        }
        guard shownForInput, reparkTimer == nil else { return }
        reparkTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard !self.injector.buttonDown, Date().timeIntervalSince(self.lastPointerInput) > 4 else { return }
            timer.invalidate()
            self.reparkTimer = nil
            self.shownForInput = false
            if !self.stopped { self.park() }
        }
    }

    private func unpark() {
        guard let origin = restoreOrigin else { return }
        restoreOrigin = nil
        if let ax = AX.window(pid: info.pid, wid: wid) { AX.setPosition(ax, origin) }
    }

    func resize(to newSize: CGSize) {
        guard !isPopup, let ax = AX.window(pid: info.pid, wid: wid) else { return }
        AX.setSize(ax, newSize)
    }

    /// Stops streaming. With `returnCrossing` the window comes back at the edge facing the other
    /// Mac (where the pointer crossed back), otherwise to where it was before it was sent.
    func stop(returnCrossing: Double? = nil, grab: CGPoint? = nil) {
        guard !stopped else { return }
        stopped = true
        pollTimer?.invalidate(); pollTimer = nil
        parkTimer?.invalidate(); parkTimer = nil
        reparkTimer?.invalidate(); reparkTimer = nil
        stream?.stopCapture(completionHandler: nil)
        stream = nil
        if !isPopup {
            if let crossing = returnCrossing, let ax = AX.window(pid: info.pid, wid: wid), let sz = AX.size(ax) {
                restoreOrigin = nil
                let frame = ScreenGeometry.entryFrame(size: sz, side: Settings.peerSide, crossing: crossing, grab: grab)
                AX.setPosition(ax, ScreenGeometry.cgOrigin(of: frame))
                AX.raise(pid: info.pid, wid: wid)
                if let g = grab {
                    DragFollower.follow(grab: g, size: sz) { origin in
                        AX.setPosition(ax, ScreenGeometry.cgOrigin(of: NSRect(origin: origin, size: sz)))
                    }
                }
            } else {
                unpark()
            }
        }
        queue.async {
            self.encoder?.invalidate()
            self.encoder = nil
            self.lastBuffer = nil
        }
        Log.write("Přestávám posílat \(isPopup ? "nabídku" : "okno") \(wid)")
    }
}
