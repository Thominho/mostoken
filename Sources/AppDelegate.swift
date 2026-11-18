import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let coordinator = Coordinator()
    private var statusItem: NSStatusItem!
    private let edge = EdgeDragMonitor()
    private var hotKeys: [HotKey] = []
    private let updater = Updater()
    private lazy var settingsModel = SettingsModel(myName: coordinator.peers.myName)

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.reset()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        Log.write("MostOken \(version) spuštěn – macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        Log.write("Oprávnění: záznam obrazovky=\(Permissions.screenRecording), zpřístupnění=\(Permissions.accessibility)")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "MostOken")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        settingsModel.onSideChanged = { [weak self] side in self?.coordinator.setArrangement(side) }
        settingsModel.onCheckUpdates = { [weak self] in self?.updater.check(manual: true) }
        settingsModel.onForgetPaired = { [weak self] in
            self?.coordinator.returnAll()
            self?.coordinator.peers.forgetPairedMacs()
            HUD.show("Spárované Macy zapomenuty – při dalším spojení se znovu ukáže kód")
        }
        updater.canInstallNow = { [weak self] in
            guard let c = self?.coordinator else { return true }
            return c.streamers.isEmpty && c.remotes.isEmpty
        }
        coordinator.onSettingsChanged = { [weak self] in self?.refresh() }
        coordinator.peers.onChange = { [weak self] in self?.refresh() }
        coordinator.peers.start()
        refresh()

        let mods = cmdKey | optionKey | controlKey
        hotKeys = [kVK_RightArrow, kVK_LeftArrow, kVK_UpArrow, kVK_DownArrow].enumerated().map { i, key in
            HotKey(keyCode: key, modifiers: mods, id: UInt32(i + 1)) { [weak self] in self?.coordinator.moveActiveWindow() }
        }

        edge.isRemoteWindow = { [weak self] w in self?.coordinator.remote(for: w) != nil }
        edge.onSend = { [weak self] w, origin, crossing, grab in
            self?.coordinator.send(window: w, dragOrigin: origin, crossing: crossing, grab: grab)
        }
        edge.onReturn = { [weak self] w, crossing, grab in
            self?.coordinator.remote(for: w)?.returnToOrigin(crossing: crossing, grab: grab)
        }
        edge.start()

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--autotest"), i + 1 < args.count {
            AutoTest.run(target: args[i + 1], coordinator: coordinator)
            return
        }
        updater.start()
        if !Settings.didShowWelcome {
            Settings.didShowWelcome = true
            // Installed copies start at login by default (can be turned off in Settings).
            if Bundle.main.bundlePath.hasPrefix("/Applications/") && !LoginItem.isEnabled {
                LoginItem.set(true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.showWelcome() }
        } else {
            Permissions.requestMissing()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.returnAll()
    }

    private func refresh() {
        let peer = coordinator.peers.activePeer
        statusItem?.button?.appearsDisabled = peer == nil
        settingsModel.refresh(peerName: peer.map { $0.isSelfTest ? "\($0.peerName) (test)" : $0.peerName })
        settingsModel.encrypted = peer?.isEncrypted ?? false
    }

    private func showWelcome() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Vítej v MostOken"
        alert.informativeText = """
        MostOken spojí tento Mac s druhým tak, že se chovají jako jeden počítač se dvěma obrazovkami. Musí běžet na obou Macích.

        • Okno pošleš tak, že ho přetáhneš k okraji obrazovky směrem k druhému Macu a chvilku ho tam podržíš. Nebo stiskni ⌃⌥⌘ + šipku.
        • Okno vrátíš přetažením za lištu zpět přes okraj nebo znovu stiskem ⌃⌥⌘ + šipky. Červené tlačítko okno zavře, jako na jednom počítači.
        • Soubory přetažené do okna z druhého Macu se přenesou na ten Mac.

        Teď se macOS zeptá na oprávnění Záznam obrazovky a Zpřístupnění. Povol obě a MostOken pak spusť znovu. V Nastavení si potom nastav, kde druhý Mac stojí.

        MostOken se spouští po přihlášení a sám se aktualizuje. Obojí jde vypnout v Nastavení.
        """
        alert.addButton(withTitle: "Pokračovat")
        alert.runModal()
        Permissions.requestMissing()
        SettingsWindow.show(model: settingsModel)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let peers = coordinator.peers
        let status: String
        if let p = peers.activePeer {
            status = p.isSelfTest ? "Test: posílám okna sám sobě" : "Připojeno: \(p.peerName) (\(Settings.peerSide.label.lowercased()))"
        } else {
            status = peers.discoveredCount > 0 ? "Připojuji se k druhému Macu…" : "Hledám druhý Mac…"
        }
        menu.addItem(disabled(status))
        menu.addItem(.separator())

        let sendActive = item("Poslat aktivní okno", #selector(sendActive))
        if let arrow = UnicodeScalar(NSRightArrowFunctionKey) {
            sendActive.keyEquivalent = String(Character(arrow))
            sendActive.keyEquivalentModifierMask = [.command, .option, .control]
        }
        menu.addItem(sendActive)

        let windowsItem = NSMenuItem(title: "Poslat okno", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let windows = WindowList.onScreen()
        if windows.isEmpty {
            sub.addItem(disabled(Permissions.screenRecording ? "Žádná okna" : "Chybí oprávnění Záznam obrazovky"))
        }
        for w in windows.prefix(40) {
            let it = item(truncate(w.label, 60), #selector(sendWindowItem(_:)))
            it.tag = Int(w.wid)
            if coordinator.streamers[w.wid] != nil { it.state = .on }
            sub.addItem(it)
        }
        windowsItem.submenu = sub
        menu.addItem(windowsItem)

        if !coordinator.sentWindows.isEmpty || !coordinator.receivedWindows.isEmpty {
            menu.addItem(.separator())
            if !coordinator.sentWindows.isEmpty { menu.addItem(disabled("Na druhém Macu:")) }
            for s in coordinator.sentWindows {
                let it = item("Vrátit „\(truncate(s.info.label, 50))“", #selector(returnStreamed(_:)))
                it.tag = Int(s.wid)
                it.indentationLevel = 1
                menu.addItem(it)
            }
            if !coordinator.receivedWindows.isEmpty { menu.addItem(disabled("Z druhého Macu:")) }
            for (i, r) in coordinator.receivedWindows.enumerated() {
                let it = item("Vrátit „\(truncate(r.title, 50))“", #selector(returnRemote(_:)))
                it.tag = i
                it.indentationLevel = 1
                menu.addItem(it)
            }
            menu.addItem(item("Vrátit všechna okna", #selector(returnAll)))
        }

        menu.addItem(.separator())
        menu.addItem(item("Nastavení…", #selector(openSettings), key: ","))
        menu.addItem(item("Zkontrolovat aktualizace (verze \(AppInfo.version))", #selector(checkUpdates)))
        let test = item("Vyzkoušet na tomto Macu", #selector(toggleSelfTest))
        test.state = peers.selfTestEnabled ? .on : .off
        menu.addItem(test)
        menu.addItem(item("Otevřít protokol", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(item("Ukončit MostOken", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    private func truncate(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n - 1)) + "…" : s
    }

    @objc private func sendActive() { coordinator.moveActiveWindow() }

    @objc private func sendWindowItem(_ sender: NSMenuItem) {
        let wid = CGWindowID(sender.tag)
        if coordinator.streamers[wid] != nil {
            coordinator.stopStreaming(wid, notifyPeer: true)
        } else if let w = WindowList.onScreen().first(where: { $0.wid == wid }) {
            coordinator.send(window: w)
        }
    }

    @objc private func returnStreamed(_ sender: NSMenuItem) {
        coordinator.stopStreaming(CGWindowID(sender.tag), notifyPeer: true)
    }

    @objc private func returnRemote(_ sender: NSMenuItem) {
        let received = coordinator.receivedWindows
        guard received.indices.contains(sender.tag) else { return }
        received[sender.tag].returnToOrigin()
    }

    @objc private func returnAll() { coordinator.returnAll() }

    @objc private func openSettings() {
        refresh()
        SettingsWindow.show(model: settingsModel)
    }

    @objc private func toggleSelfTest() {
        if coordinator.peers.selfTestEnabled {
            coordinator.returnAll()
            coordinator.peers.stopSelfTest()
        } else {
            coordinator.peers.startSelfTest()
            HUD.show("Test: okna se pošlou do nového okna na tomto Macu")
        }
    }

    @objc private func openLog() { NSWorkspace.shared.open(Log.url) }

    @objc private func checkUpdates() { updater.check(manual: true) }

    @objc private func quit() { NSApp.terminate(nil) }
}
