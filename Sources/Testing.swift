import AppKit
import Network
import CoreImage
import CryptoKit
import VideoToolbox

/// `MostOken --selftest`: checks framing, encoding, TCP transfer and decoding without any
/// permissions or UI.
enum SelfTest {
    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            print((condition ? "OK    " : "CHYBA ") + message)
            if !condition { ok = false }
        }
        print("== MostOken self-test ==")

        // 1. Wire format
        let sample = VideoFrame(wid: 42, isKey: true, parameterSets: [Data([0x67, 1, 2]), Data([0x68, 3])],
                                data: Data((0..<5000).map { UInt8($0 & 0xff) }))
        let packet = Wire.pack(.frame, sample.encoded())
        let length = packet.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        check(Int(length) == packet.count - 4 && packet[4] == MsgType.frame.rawValue, "rámec zprávy")
        let back = VideoFrame.decode(packet.subdata(in: 5..<packet.count))
        check(back?.wid == 42 && back?.isKey == true && back?.parameterSets == sample.parameterSets
              && back?.data == sample.data, "kódování snímku do zprávy")
        var input = InputEvent(wid: 7, kind: .scroll)
        input.dx = 3; input.dy = -12; input.precise = true; input.phase = 2
        let inputPacket = Wire.json(.input, input)
        let inputBack = Wire.parse(InputEvent.self, inputPacket.subdata(in: 5..<inputPacket.count))
        check(inputBack?.kind == .scroll && inputBack?.dy == -12 && inputBack?.phase == 2, "vstupní událost")
        let openBack = Wire.parse(WindowOpen.self, Data(#"{"wid":1,"title":"a","app":"b","width":10,"height":20}"#.utf8))
        check(openBack?.crossing == nil && openBack?.height == 20, "zpráva o okně bez nepovinných polí")
        check(Side.left.opposite == .right && Side.top.opposite == .bottom, "protilehlé strany")

        // 1b. Pairing and encryption
        let a = Curve25519.KeyAgreement.PrivateKey(), b = Curve25519.KeyAgreement.PrivateKey()
        let ka = try? Pairing.pairingKey(a, peerPublic: b.publicKey.rawRepresentation)
        let kb = try? Pairing.pairingKey(b, peerPublic: a.publicKey.rawRepresentation)
        check(ka != nil && ka == kb && ka?.count == 32, "párovací klíč vyjde na obou Macích stejně")
        let codeA = Pairing.code(a.publicKey.rawRepresentation, b.publicKey.rawRepresentation)
        let codeB = Pairing.code(b.publicKey.rawRepresentation, a.publicKey.rawRepresentation)
        let mitm = Curve25519.KeyAgreement.PrivateKey()
        let codeM = Pairing.code(a.publicKey.rawRepresentation, mitm.publicKey.rawRepresentation)
        check(codeA == codeB && codeA.count == 7 && codeA != codeM, "ověřovací kód \(codeA) shodný, podvržený klíč dá jiný kód")
        let n1 = Pairing.randomBytes(16), n2 = Pairing.randomBytes(16)
        let sessionKey = Pairing.sessionKey(pairingKey: ka ?? Data(), lowNonce: n1, highNonce: n2)
        let sender = MessageCipher(key: sessionKey, direction: 0), receiver = MessageCipher(key: sessionKey, direction: 0)
        let secret = Data("tajný obsah okna".utf8)
        let sealed1 = (try? sender.seal(secret)) ?? Data()
        let sealed2 = (try? sender.seal(secret)) ?? Data()
        check((try? receiver.open(sealed1)) == secret && (try? receiver.open(sealed2)) == secret
              && sealed1 != sealed2 && sealed1.range(of: secret) == nil, "šifrování zprávy a rozšifrování")
        var tampered = (try? sender.seal(secret)) ?? Data()
        tampered[tampered.startIndex] ^= 0x01
        check((try? receiver.open(tampered)) == nil, "pozměněná zpráva se odmítne")
        let wrongKey = MessageCipher(key: SymmetricKey(size: .bits256), direction: 0)
        check((try? wrongKey.open((try? MessageCipher(key: sessionKey, direction: 0).seal(secret)) ?? Data())) == nil,
              "zprávu s cizím klíčem nejde přečíst")

        // 2. Flatten + encode
        let w = 1440, h = 900
        let background = CIColor(red: 0.9, green: 0.9, blue: 0.9)
        let flattener = Flattener(background: background)
        let lock = NSLock()
        var encoded: [VideoFrame] = []
        guard let encoder = VideoEncoder(width: w, height: h, output: { data, key, sets in
            lock.lock()
            encoded.append(VideoFrame(wid: 1, isKey: key, parameterSets: sets, data: data))
            lock.unlock()
        }) else {
            check(false, "vytvoření kodéru")
            return false
        }
        let t0 = Date()
        for i in 0..<60 {
            guard let src = makeTestBuffer(width: w, height: h, frame: i), let flat = flattener.flatten(src) else {
                check(false, "testovací snímek \(i)")
                return false
            }
            encoder.encode(flat, forceKey: i == 0 || i == 30)
            usleep(4000)
        }
        encoder.flush()
        let elapsed = Date().timeIntervalSince(t0)
        lock.lock(); let frames = encoded; lock.unlock()
        let keys = frames.filter(\.isKey).count
        let total = frames.reduce(0) { $0 + $1.data.count }
        check(frames.count == 60, "zakódováno \(frames.count)/60 snímků \(w)×\(h) za \(String(format: "%.2f", elapsed)) s")
        check(frames.first?.isKey == true && (frames.first?.parameterSets.count ?? 0) >= 2 && keys >= 2,
              "klíčové snímky: \(keys), parametry SPS/PPS: \(frames.first?.parameterSets.count ?? 0)")
        if !frames.isEmpty { print("      průměrná velikost snímku: \(total / frames.count / 1024) kB") }

        // 3. Real TCP loopback through PeerConnection, encrypted
        let linkKey = SymmetricKey(size: .bits256)
        var received: [VideoFrame] = []
        let allReceived = DispatchSemaphore(value: 0)
        let listenerReady = DispatchSemaphore(value: 0)
        var server: PeerConnection?
        guard let listener = try? NWListener(using: PeerManager.parameters(), on: .any) else {
            check(false, "spuštění TCP serveru")
            return false
        }
        listener.newConnectionHandler = { nw in
            let pc = PeerConnection(nw, outgoing: false, raw: true)
            pc.enableTestEncryption(key: linkKey, sendDirection: 1)
            pc.onMessage = { _, type, data in
                guard type == .frame, let f = VideoFrame.decode(data) else { return }
                received.append(f)
                if received.count == frames.count { allReceived.signal() }
            }
            server = pc
            pc.start()
        }
        listener.stateUpdateHandler = { state in if case .ready = state { listenerReady.signal() } }
        listener.start(queue: .global())
        guard listenerReady.wait(timeout: .now() + 3) == .success, let port = listener.port else {
            check(false, "TCP server neběží")
            return false
        }
        let client = PeerConnection(NWConnection(host: "127.0.0.1", port: port, using: PeerManager.parameters()),
                                    outgoing: true, raw: true)
        client.enableTestEncryption(key: linkKey, sendDirection: 0)
        client.onReady = { c in for f in frames { c.send(Wire.pack(.frame, f.encoded())) } }
        let t1 = Date()
        client.start()
        let transferred = allReceived.wait(timeout: .now() + 10) == .success
        check(transferred && received.count == frames.count && client.isEncrypted,
              "šifrovaný přenos přes TCP: \(received.count)/\(frames.count) snímků za \(String(format: "%.3f", Date().timeIntervalSince(t1))) s")
        check(zip(received, frames).allSatisfy { $0.data == $1.data && $0.isKey == $1.isKey }, "přenesená data jsou beze změny")
        _ = server
        client.cancel()
        listener.cancel()

        // 4. Decode what arrived
        var decoded = 0
        var sizeOK = true
        var cornerPixel: (UInt8, UInt8, UInt8)?
        var format: CMVideoFormatDescription?
        var session: VTDecompressionSession?
        for f in received {
            if f.isKey { format = H264.makeFormat(f.parameterSets) }
            guard let fmt = format else { continue }
            if session == nil {
                let attrs = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] as CFDictionary
                VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fmt,
                                             decoderSpecification: nil, imageBufferAttributes: attrs,
                                             outputCallback: nil, decompressionSessionOut: &session)
            }
            guard let session, let sb = H264.makeSampleBuffer(f.data, format: fmt) else { continue }
            VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                guard status == noErr, let image else { return }
                lock.lock()
                decoded += 1
                if CVPixelBufferGetWidth(image) != w || CVPixelBufferGetHeight(image) != h { sizeOK = false }
                CVPixelBufferLockBaseAddress(image, .readOnly)
                if let base = CVPixelBufferGetBaseAddress(image) {
                    let row = CVPixelBufferGetBytesPerRow(image)
                    let p = base.advanced(by: 10 * row + 10 * 4).assumingMemoryBound(to: UInt8.self)
                    cornerPixel = (p[2], p[1], p[0])
                }
                CVPixelBufferUnlockBaseAddress(image, .readOnly)
                lock.unlock()
            }
        }
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
        check(decoded == received.count && decoded > 0 && sizeOK, "dekódováno \(decoded)/\(received.count) snímků")
        if let c = cornerPixel {
            // The transparent corner must come out as the window background (≈230), not black.
            let near = [c.0, c.1, c.2].allSatisfy { abs(Int($0) - 230) < 20 }
            check(near, "průhledný roh okna vyplněn barvou pozadí (RGB \(c.0),\(c.1),\(c.2))")
        } else {
            check(false, "čtení dekódovaného obrazu")
        }

        print(ok ? "== VŠE V POŘÁDKU ==" : "== NĚCO SELHALO ==")
        return ok
    }

    /// BGRA test image with moving bars and a fully transparent top-left corner.
    private static func makeTestBuffer(width: Int, height: Int, frame: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
              let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let row = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<height {
            let line = base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let i = x * 4
                if x < 40 && y < 40 {
                    line[i] = 0; line[i + 1] = 0; line[i + 2] = 0; line[i + 3] = 0
                } else {
                    let bar = UInt8(((x + frame * 8) / 64 % 2) * 120 + 60)
                    line[i] = bar; line[i + 1] = UInt8(y * 255 / height); line[i + 2] = 200; line[i + 3] = 255
                }
            }
        }
        return pb
    }
}

/// `MostOken --autotest <window title>`: sends that window to this same Mac, clicks, types and
/// scrolls in the copy, then gives it back and quits. Needs the permissions.
final class AutoTest {
    static var active = false
    private static var current: AutoTest?

    private let target: String
    private let coordinator: Coordinator
    private let deadline = Date().addingTimeInterval(45)

    private init(target: String, coordinator: Coordinator) {
        self.target = target
        self.coordinator = coordinator
    }

    static func run(target: String, coordinator: Coordinator) {
        active = true
        let t = AutoTest(target: target, coordinator: coordinator)
        current = t
        Log.write("AUTOTEST: start, cílové okno „\(target)“")
        t.waitFor({ coordinator.peers.listenerPort != nil }, "naslouchání") {
            coordinator.peers.startSelfTest()
            t.waitFor({ coordinator.peers.activePeer?.isSelfTest == true }, "spojení sám se sebou") { t.send() }
        }
    }

    private func waitFor(_ condition: @escaping () -> Bool, _ what: String, then: @escaping () -> Void) {
        if condition() { then(); return }
        if Date() > deadline { finish("CHYBA – vypršel čas: \(what)"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.waitFor(condition, what, then: then) }
    }

    private func findTarget() -> WindowInfo? {
        WindowList.onScreen().first { $0.title == target || $0.app == target }
    }

    private func send() {
        waitFor({ self.findTarget() != nil }, "cílové okno") {
            guard let w = self.findTarget() else { return }
            Log.write("AUTOTEST: posílám okno \(w.wid) „\(w.label)“ \(w.bounds)")
            self.coordinator.send(window: w, crossing: 0.4, grab: CGPoint(x: 120, y: 14))
            self.waitFor({ (self.coordinator.remotes.first?.framesShown ?? 0) >= 1 }, "první snímek") {
                Log.write("AUTOTEST: OK – kopie okna zobrazuje obraz")
                if let r = self.coordinator.remotes.first {
                    Log.write("AUTOTEST: kopie okna je na \(NSStringFromRect(r.window.frame))")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.interact() }
            }
        }
    }

    private func interact() {
        guard let r = coordinator.remotes.first else { finish("CHYBA – kopie okna zmizela"); return }
        let send: (InputEvent) -> Void = { r.videoView.onInput?($0) }
        var t: TimeInterval = 0
        func later(_ dt: TimeInterval, _ block: @escaping () -> Void) {
            t += dt
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: block)
        }
        var down = InputEvent(wid: r.wid, kind: .mouseDown)
        down.x = 0.5; down.y = 0.5; down.clicks = 1
        var up = down
        up.kind = .mouseUp
        later(0) { send(down) }
        later(0.08) { send(up) }
        // a, h, o, j
        for code: UInt16 in [0x00, 0x04, 0x1F, 0x26] {
            later(0.15) { send(InputEvent(wid: r.wid, kind: .keyDown, keyCode: code)) }
            later(0.05) { send(InputEvent(wid: r.wid, kind: .keyUp, keyCode: code)) }
        }
        for (i, phase) in [1, 2, 2, 2, 4].enumerated() {
            later(0.05) {
                var s = InputEvent(wid: r.wid, kind: .scroll)
                s.x = 0.5; s.y = 0.5; s.precise = true; s.phase = phase
                s.dy = i == 0 || phase == 4 ? 0 : -60
                send(s)
            }
        }
        later(0.3) {
            // File drop onto the copy.
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("mostoken-autotest.txt")
            try? "Zkušební soubor MostOken".write(to: file, atomically: true, encoding: .utf8)
            r.videoView.onFilesDropped?([file])
        }
        later(0.4) {
            var resize = Geometry(wid: r.wid, width: 700, height: 460)
            resize.width = 700
            r.peer?.send(Wire.json(.resizeRequest, resize))
        }
        later(1.5) {
            Log.write("AUTOTEST: kopie okna má teď \(Int(r.videoView.videoSize.width))×\(Int(r.videoView.videoSize.height)), snímků \(r.framesShown)")
            if let s = self.coordinator.streamers.values.first {
                Log.write("AUTOTEST: původní okno je teď na \(WindowList.bounds(of: s.wid).map { "\($0)" } ?? "?")")
                let dir = FileReceiver.directoryOverride ?? FileManager.default.temporaryDirectory
                let url = dir.appendingPathComponent("autotest-snimek.png")
                s.snapshot(to: url) { ok in Log.write("AUTOTEST: snímek zachyceného okna \(ok ? "uložen: \(url.path)" : "nejde uložit")") }
            }
        }
        later(0.5) { r.returnToOrigin() }
        later(1.0) {
            let returned = self.coordinator.streamers.isEmpty && self.coordinator.remotes.isEmpty
            Log.write(returned ? "AUTOTEST: OK – okno vráceno" : "AUTOTEST: CHYBA – okno se nevrátilo")
            if let w = self.findTarget() { Log.write("AUTOTEST: původní okno po vrácení: \(w.bounds)") }
            self.finish("HOTOVO")
        }
    }

    private func finish(_ result: String) {
        Log.write("AUTOTEST: \(result)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }
}

/// `MostOken --test-source <file>`: a plain text window used as the target of the autotest.
/// Writes what it receives (text, clicks, scrolls, files) to <file>.
final class TestSourceDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate, NSWindowDelegate {
    private let output: URL
    private var window: NSWindow!
    private var textView: CountingTextView!

    init(output: URL) { self.output = output }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.prefix = "[zdroj] "
        window = NSWindow(contentRect: NSRect(x: 180, y: 260, width: 640, height: 420),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "MostOken test"
        window.delegate = self
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        textView = CountingTextView(frame: scroll.bounds)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.string = (1...200).map { "Řádek \($0)" }.joined(separator: "\n")
        textView.delegate = self
        textView.onEvent = { [weak self] in self?.save() }
        scroll.documentView = textView
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        save()
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        textView.openedFiles += filenames
        save()
    }

    func textDidChange(_ notification: Notification) { save() }

    private func save() {
        let visible = textView.enclosingScrollView?.contentView.bounds.origin.y ?? 0
        let state: [String: Any] = [
            "typed": textView.string.replacingOccurrences(of: "Řádek \\d+", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\n", with: ""),
            "clicks": textView.clicks, "keys": textView.keys, "scrolls": textView.scrolls,
            "scrollY": visible, "files": textView.openedFiles,
            "width": window.frame.width,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func windowDidResize(_ notification: Notification) { save() }
}

final class CountingTextView: NSTextView {
    var clicks = 0, keys = 0, scrolls = 0
    var openedFiles: [String] = []
    var onEvent: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        clicks += 1
        super.mouseDown(with: event)
        onEvent?()
    }

    override func keyDown(with event: NSEvent) {
        keys += 1
        super.keyDown(with: event)
        onEvent?()
    }

    override func scrollWheel(with event: NSEvent) {
        scrolls += 1
        super.scrollWheel(with: event)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.onEvent?() }
    }
}
