import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreImage

/// Captures one window on this Mac, encodes it and streams it to the other Mac.
/// Also replays the other Mac's mouse/keyboard input into that window.
final class WindowStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    let info: WindowInfo
    var wid: CGWindowID { info.wid }
    weak var peer: PeerConnection?
    var onEnded: ((WindowStreamer) -> Void)?
    let injector: InputInjector

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "mostoken.capture", qos: .userInteractive)

    // Confined to `queue`.
    private var encoder: VideoEncoder?
    private let flattener: Flattener
    private var forceKey = true
    private var lastBuffer: CVPixelBuffer?
    private var framesSent = 0
    private var bytesSent = 0

    // Confined to the main thread.
    private var size: CGSize
    private var scale: CGFloat = 2
    private var pollTimer: Timer?
    private var parkTimer: Timer?
    private var restoreOrigin: CGPoint?
    private var stopped = false
    private var lastStats = Date()
    private var shownForInput = false
    private var reparkTimer: Timer?
    private var lastPointerInput = Date()

    init(info: WindowInfo, peer: PeerConnection) {
        self.info = info
        self.peer = peer
        self.size = info.bounds.size
        self.injector = InputInjector(pid: info.pid, wid: info.wid)
        self.flattener = Flattener(background: WindowStreamer.windowBackground())
        super.init()
        injector.showWindow = { [weak self] in self?.showForInput() }
    }

    /// A click is coming from the other Mac: put a parked window back on screen so the click can
    /// land on it, and park it again after a few seconds without clicks.
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
        let h = NSScreen.screens.first?.frame.height ?? 0
        let cocoa = NSRect(x: cgRect.minX, y: h - cgRect.maxY, width: cgRect.width, height: cgRect.height)
        let screen = NSScreen.screens.max { $0.frame.intersection(cocoa).width * $0.frame.intersection(cocoa).height
            < $1.frame.intersection(cocoa).width * $1.frame.intersection(cocoa).height }
        return screen?.backingScaleFactor ?? 2
    }

    // MARK: Capture

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scWindow = content.windows.first(where: { $0.windowID == wid }) else {
            throw NSError(domain: "MostOken", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Okno se nepodařilo najít."])
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let scale: CGFloat
        if #available(macOS 14.0, *) {
            scale = CGFloat(filter.pointPixelScale)
        } else {
            scale = Self.screenScale(for: info.bounds)
        }
        let config = await MainActor.run { () -> SCStreamConfiguration in
            self.scale = scale
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
            self.pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.poll()
            }
            Log.write("Zachytávám okno \(self.wid) (\(Int(self.size.width))×\(Int(self.size.height)) bodů, \(scale)×)")
        }
    }

    private func makeConfig(_ size: CGSize) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = max(64, Int((size.width * scale).rounded()) / 2 * 2)
        c.height = max(64, Int((size.height * scale).rounded()) / 2 * 2)
        c.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = false
        c.queueDepth = 5
        c.colorSpaceName = CGColorSpace.sRGB
        if #available(macOS 14.0, *) { c.ignoreShadowsSingleWindow = true }
        if #available(macOS 14.2, *) { c.includeChildWindows = true }
        return c
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let flat = flattener.flatten(pixelBuffer) else { return }
        lastBuffer = flat
        encode(flat)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("Zachytávání okna \(wid) skončilo: \(error.localizedDescription)")
        DispatchQueue.main.async {
            if !self.stopped { self.onEnded?(self) }
        }
    }

    /// Must run on `queue`.
    private func encode(_ pixelBuffer: CVPixelBuffer) {
        guard let peer else { return }
        if peer.pendingBytes > 4_000_000 {
            // Network is behind: drop this frame, resync with a keyframe later.
            forceKey = true
            return
        }
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        if encoder == nil || encoder?.width != w || encoder?.height != h {
            encoder?.invalidate()
            let wid = self.wid
            encoder = VideoEncoder(width: w, height: h) { [weak self] data, isKey, sets in
                guard let self, let peer = self.peer else { return }
                let packet = Wire.pack(.frame, VideoFrame(wid: wid, isKey: isKey, parameterSets: sets, data: data).encoded())
                peer.send(packet)
                self.queue.async {
                    self.framesSent += 1
                    self.bytesSent += packet.count
                }
            }
            forceKey = true
        }
        let key = forceKey
        forceKey = false
        encoder?.encode(pixelBuffer, forceKey: key)
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

    func requestKeyframe() {
        queue.async { [weak self] in
            guard let self else { return }
            self.forceKey = true
            if let pb = self.lastBuffer { self.encode(pb) }
        }
    }

    private func poll() {
        guard !stopped else { return }
        guard let b = WindowList.bounds(of: wid) else {
            Log.write("Okno \(wid) bylo zavřeno")
            onEnded?(self)
            return
        }
        if abs(b.width - size.width) > 0.5 || abs(b.height - size.height) > 0.5 {
            size = b.size
            stream?.updateConfiguration(makeConfig(b.size)) { error in
                if let error { Log.write("Změna velikosti zachytávání selhala: \(error.localizedDescription)") }
            }
            peer?.send(Wire.json(.geometry, Geometry(wid: wid, width: Double(b.width), height: Double(b.height))))
            if restoreOrigin != nil && Settings.peerSide != .right { park() }
        }
        // Static windows produce no new frames; resend the last one if a keyframe is owed.
        queue.async { [weak self] in
            guard let self, self.forceKey, let pb = self.lastBuffer,
                  (self.peer?.pendingBytes ?? 0) < 1_000_000 else { return }
            self.encode(pb)
        }
        if Date().timeIntervalSince(lastStats) > 5 {
            lastStats = Date()
            queue.async {
                Log.write("Okno \(self.wid): odesláno \(self.framesSent) snímků, \(self.bytesSent / 1024) kB")
            }
        }
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
        queue.async {
            self.encoder?.invalidate()
            self.encoder = nil
            self.lastBuffer = nil
        }
        Log.write("Přestávám posílat okno \(wid)")
    }

    // MARK: Moving the original window out of the way

    /// Slides the original window almost completely off the screen edge facing the other Mac,
    /// leaving a thin strip visible (fully hidden windows may stop rendering).
    func park() {
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

    private func unpark() {
        guard let origin = restoreOrigin else { return }
        restoreOrigin = nil
        if let ax = AX.window(pid: info.pid, wid: wid) { AX.setPosition(ax, origin) }
    }

    func resize(to newSize: CGSize) {
        guard let ax = AX.window(pid: info.pid, wid: wid) else { return }
        AX.setSize(ax, newSize)
    }
}
