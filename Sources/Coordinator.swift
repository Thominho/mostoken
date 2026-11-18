import AppKit

/// Glue between the network, the windows this Mac sends and the windows it shows.
final class Coordinator {
    let peers = PeerManager()
    private(set) var streamers: [CGWindowID: WindowStreamer] = [:]
    private(set) var remotes: [RemoteWindowController] = []
    private let files = FileReceiver()
    var onSettingsChanged: (() -> Void)?

    init() {
        peers.onMessage = { [weak self] c, type, data in self?.handle(c, type, data) }
        peers.onPeerReady = { [weak self] c in self?.sendArrangement(to: c) }
        peers.onPeerLost = { [weak self] c in self?.peerLost(c) }
        files.onComplete = { [weak self] url, wid in self?.fileArrived(url, wid: wid) }
    }

    // MARK: Arrangement (kept in sync between both Macs)

    private func sendArrangement(to c: PeerConnection) {
        c.send(Wire.json(.arrangement, Arrangement(side: Settings.peerSide.rawValue,
                                                   changedAt: Settings.peerSideChangedAt)))
    }

    func setArrangement(_ side: Side) {
        Settings.setPeerSide(side, changedAt: Date().timeIntervalSince1970)
        Log.write("Rozložení: druhý Mac je \(side.label.lowercased())")
        for c in peers.connections where c.helloReceived && !c.isSelfTest { sendArrangement(to: c) }
        onSettingsChanged?()
    }

    private func applyArrangement(_ a: Arrangement, from c: PeerConnection) {
        guard let theirs = Side(rawValue: a.side) else { return }
        let mine = Settings.peerSideChangedAt
        // Newest choice wins; on a tie (nobody chose yet) the Mac with the smaller ID wins.
        guard a.changedAt > mine || (a.changedAt == mine && (c.peerID ?? "") < peers.myID) else { return }
        let side = theirs.opposite
        if side != Settings.peerSide {
            Log.write("Rozložení převzato z \(c.peerName): druhý Mac je \(side.label.lowercased())")
        }
        Settings.setPeerSide(side, changedAt: a.changedAt)
        onSettingsChanged?()
    }

    // MARK: Sending windows

    func send(window w: WindowInfo, dragOrigin: CGRect? = nil, crossing: Double? = nil, grab: CGPoint? = nil) {
        guard let peer = peers.activePeer else {
            HUD.show("Druhý Mac není připojený")
            NSSound.beep()
            return
        }
        guard Permissions.screenRecording else {
            HUD.show("Chybí oprávnění Záznam obrazovky – viz Nastavení MostOken")
            Permissions.requestMissing()
            return
        }
        guard streamers[w.wid] == nil else { return }

        let s = WindowStreamer(info: w, peer: peer)
        s.onEnded = { [weak self] s in self?.stopStreaming(s.wid, notifyPeer: true) }
        s.onPopups = { [weak self] parent, popups in self?.syncPopups(of: parent, popups) }
        streamers[w.wid] = s
        let open = WindowOpen(wid: w.wid, title: w.title, app: w.app,
                              width: Double(w.bounds.width), height: Double(w.bounds.height),
                              crossing: crossing,
                              grabX: grab.map { Double($0.x) }, grabY: grab.map { Double($0.y) },
                              chrome: AX.chrome(pid: w.pid, wid: w.wid))
        peer.send(Wire.json(.windowOpen, open))
        Log.write("Posílám okno \(w.wid) „\(w.label)“ na \(peer.peerName)")
        if grab == nil { HUD.show("„\(w.app)“ → \(peer.peerName)") }

        Task { @MainActor in
            do {
                try await s.start()
                if let origin = dragOrigin {
                    s.park(afterDragFrom: origin)
                } else if Settings.parkOriginal {
                    s.park()
                }
            } catch {
                Log.write("Okno nejde zachytit: \(error.localizedDescription)")
                self.stopStreaming(w.wid, notifyPeer: true)
                HUD.show("Okno nejde zachytit – zkontroluj oprávnění")
            }
        }
    }

    func stopStreaming(_ wid: CGWindowID, notifyPeer: Bool, returnCrossing: Double? = nil, grab: CGPoint? = nil) {
        guard let s = streamers.removeValue(forKey: wid) else { return }
        for popup in streamers.values where popup.parentWid == wid { stopStreaming(popup.wid, notifyPeer: notifyPeer) }
        s.stop(returnCrossing: returnCrossing, grab: grab)
        if notifyPeer { s.peer?.send(Wire.json(.windowClose, WindowRef(wid: wid))) }
    }

    /// Menus and pop-ups of a sent window are mirrored as their own small windows.
    private func syncPopups(of parent: WindowStreamer, _ popups: [WindowInfo]) {
        let current = Set(popups.map(\.wid))
        for s in streamers.values where s.parentWid == parent.wid && !current.contains(s.wid) {
            stopStreaming(s.wid, notifyPeer: true)
        }
        guard let peer = parent.peer, peer.capabilities.contains(Capability.popups) else { return }
        for p in popups where streamers[p.wid] == nil {
            let s = WindowStreamer(info: p, peer: peer, parent: parent.wid)
            s.onEnded = { [weak self] s in self?.stopStreaming(s.wid, notifyPeer: true) }
            streamers[p.wid] = s
            var open = WindowOpen(wid: p.wid, title: p.title, app: p.app,
                                  width: Double(p.bounds.width), height: Double(p.bounds.height), parent: parent.wid)
            if let click = parent.injector.lastClick {
                open.offsetX = Double(p.bounds.minX - click.x)
                open.offsetY = Double(p.bounds.minY - click.y)
            }
            peer.send(Wire.json(.windowOpen, open))
            Task { @MainActor in
                do { try await s.start() } catch {
                    Log.write("Nabídku nejde zachytit: \(error.localizedDescription)")
                    self.stopStreaming(p.wid, notifyPeer: true)
                }
            }
        }
    }

    /// ⌃⌥⌘ + arrow: send the active window over, or give it back if it came from the other Mac.
    func moveActiveWindow() {
        if NSApp.isActive, let key = NSApp.keyWindow, let r = remote(for: key) {
            r.returnToOrigin()
            return
        }
        guard let w = WindowList.frontmost() else { NSSound.beep(); return }
        if streamers[w.wid] != nil {
            stopStreaming(w.wid, notifyPeer: true)
            return
        }
        send(window: w)
    }

    func returnAll() {
        for (wid, s) in streamers where !s.isPopup { stopStreaming(wid, notifyPeer: true) }
        for r in remotes where !r.isPopup { r.returnToOrigin() }
    }

    /// Windows sent to the other Mac (not counting their menus).
    var sentWindows: [WindowStreamer] { streamers.values.filter { !$0.isPopup } }
    /// Windows shown here from the other Mac (not counting their menus).
    var receivedWindows: [RemoteWindowController] { remotes.filter { !$0.isPopup } }

    func remote(for window: NSWindow) -> RemoteWindowController? {
        remotes.first { $0.window === window && !$0.isPopup }
    }

    private func remote(_ c: PeerConnection, _ wid: UInt32) -> RemoteWindowController? {
        remotes.first { $0.peer === c && $0.wid == wid }
    }

    // MARK: Messages from the other Mac

    private func handle(_ c: PeerConnection, _ type: MsgType, _ data: Data) {
        switch type {
        case .windowOpen:
            guard let o = Wire.parse(WindowOpen.self, data), remote(c, o.wid) == nil else { return }
            openRemote(o, from: c)
        case .geometry:
            guard let g = Wire.parse(Geometry.self, data) else { return }
            remote(c, g.wid)?.applyGeometry(g)
        case .frame:
            guard let f = VideoFrame.decode(data) else { return }
            remote(c, f.wid)?.handleFrame(f)
        case .windowClose:
            guard let r = Wire.parse(WindowRef.self, data) else { return }
            remote(c, r.wid)?.closeFromRemote()
        case .input:
            guard let e = Wire.parse(InputEvent.self, data), let s = streamers[e.wid], s.peer === c else { return }
            s.injector.inject(e)
        case .returnWindow:
            guard let r = Wire.parse(ReturnWindow.self, data), streamers[r.wid]?.peer === c else { return }
            var grab: CGPoint?
            if let gx = r.grabX, let gy = r.grabY { grab = CGPoint(x: gx, y: gy) }
            stopStreaming(r.wid, notifyPeer: false, returnCrossing: r.crossing, grab: grab)
            if r.crossing == nil { HUD.show("Okno se vrátilo") }
        case .keyframeRequest:
            guard let r = Wire.parse(WindowRef.self, data), streamers[r.wid]?.peer === c else { return }
            streamers[r.wid]?.requestKeyframe()
        case .resizeRequest:
            guard let g = Wire.parse(Geometry.self, data), streamers[g.wid]?.peer === c else { return }
            streamers[g.wid]?.resize(to: CGSize(width: g.width, height: g.height))
        case .arrangement:
            guard !c.isSelfTest, let a = Wire.parse(Arrangement.self, data) else { return }
            applyArrangement(a, from: c)
        case .fileBegin:
            guard let b = Wire.parse(FileBegin.self, data), streamers[b.wid]?.peer === c else { return }
            files.begin(b)
        case .fileChunk:
            files.chunk(data)
        case .fileEnd:
            guard let e = Wire.parse(FileEnd.self, data) else { return }
            files.end(e)
        case .viewInfo:
            guard let v = Wire.parse(ViewInfo.self, data), streamers[v.wid]?.peer === c else { return }
            streamers[v.wid]?.setReceiverScale(CGFloat(v.scale))
        case .visibility:
            guard let v = Wire.parse(Visibility.self, data), let s = streamers[v.wid], s.peer === c else { return }
            s.setVisible(v.visible)
            for popup in streamers.values where popup.parentWid == v.wid { popup.setVisible(v.visible) }
        case .closeWindow:
            guard let r = Wire.parse(WindowRef.self, data), let s = streamers[r.wid], s.peer === c else { return }
            if !AX.pressCloseButton(pid: s.info.pid, wid: s.wid) {
                // No close button exposed: ⌘W, like a person would.
                s.injector.inject(InputEvent(wid: r.wid, kind: .keyDown, keyCode: 0x0D, flags: UInt64(CGEventFlags.maskCommand.rawValue)))
                s.injector.inject(InputEvent(wid: r.wid, kind: .keyUp, keyCode: 0x0D, flags: UInt64(CGEventFlags.maskCommand.rawValue)))
            }
        case .focus:
            guard let r = Wire.parse(WindowRef.self, data), let s = streamers[r.wid], s.peer === c else { return }
            s.injector.prepareFocus()
        case .hello, .auth, .pairAccept:
            break
        }
    }

    private func openRemote(_ o: WindowOpen, from c: PeerConnection) {
        let parent = o.parent.flatMap { remote(c, $0) }
        if o.parent != nil && parent == nil { return }
        let r = RemoteWindowController(open: o, peer: c, anchor: parent?.videoView.lastClickScreen)
        r.onClosed = { [weak self] r in
            guard let self else { return }
            self.remotes.removeAll { $0 === r }
            // A window's menus go with it.
            for popup in self.remotes where popup.parentWid == r.wid && popup.peer === r.peer { popup.closeFromRemote() }
        }
        r.videoView.onFilesDropped = { [weak r] urls in
            guard let r, let peer = r.peer else { return }
            HUD.show(urls.count == 1 ? "Posílám soubor…" : "Posílám \(urls.count) soubory…")
            FileSender.send(urls, wid: r.wid, over: peer) { sent, skipped in
                HUD.show(skipped > 0 ? "Odesláno: \(sent), přeskočeno: \(skipped) (složky zatím neumím)"
                                     : "Soubory jsou na Macu \(peer.peerName)")
            }
        }
        remotes.append(r)
        r.show()
        Log.write("Přijato \(o.parent == nil ? "okno" : "nabídka") \(o.wid) „\(o.app)“ od \(c.peerName)")
    }

    /// A file dropped onto our window on the other Mac: open it in that window's app.
    private func fileArrived(_ url: URL, wid: UInt32) {
        HUD.show("Přijat soubor „\(url.lastPathComponent)“")
        if AutoTest.active { return }
        let risky: Set<String> = ["command", "sh", "zsh", "bash", "tool", "app", "pkg", "mpkg", "scpt",
                                  "applescript", "workflow", "terminal", "dmg", "jar", "py", "rb", "pl"]
        let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
                                      "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "io.alacritty"]
        guard let s = streamers[wid],
              let app = NSRunningApplication(processIdentifier: s.info.pid),
              let appURL = app.bundleURL,
              app.bundleIdentifier != "com.apple.finder",
              !terminals.contains(app.bundleIdentifier ?? ""),
              !risky.contains(url.pathExtension.lowercased()) else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { _, error in
            if let error {
                Log.write("Soubor nejde otevřít v \(app.localizedName ?? "aplikaci"): \(error.localizedDescription)")
                DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    private func peerLost(_ c: PeerConnection) {
        for (wid, s) in streamers where s.peer === c || s.peer == nil { stopStreaming(wid, notifyPeer: false) }
        for r in remotes where r.peer === c || r.peer == nil { r.closeFromRemote() }
        files.abortAll()
    }
}
