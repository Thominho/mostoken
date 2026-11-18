import AppKit
import Network
import CryptoKit
import SystemConfiguration

/// One TCP connection to the other Mac.
///
/// Handshake (plaintext): hello → auth. If both Macs already share a pairing key, every later
/// message is encrypted with a fresh per-connection key. Otherwise both Macs show the same
/// six-digit code; after the person confirms on both, the new pairing key is stored and the
/// connection switches to encryption.
final class PeerConnection {
    private enum Stage { case handshake, pairing, secure }

    let nw: NWConnection
    let outgoing: Bool
    /// Raw mode (self-test only): no handshake, every message goes straight to `onMessage`.
    let raw: Bool
    var expectedID: String?
    var isSelfTest = false
    /// Set on the main thread once the manager has accepted the secure connection.
    var helloReceived = false
    var awaitingPairing = false

    // Filled in by the manager before start().
    var myID = ""
    var myName = ""
    var allowSelf: () -> Bool = { false }

    var onMessage: ((PeerConnection, MsgType, Data) -> Void)?
    var onReady: ((PeerConnection) -> Void)?
    var onSecure: ((PeerConnection) -> Void)?
    var onPairingNeeded: ((PeerConnection, String) -> Void)?
    var onClosed: ((PeerConnection) -> Void)?

    private static let queue = DispatchQueue(label: "mostoken.connection", qos: .userInteractive)

    // Protected by `lock` (touched from several threads).
    private let lock = NSLock()
    private var pending = 0
    private var closed = false
    private var txCipher: MessageCipher?
    private var _peerID: String?
    private var _peerName = "druhý Mac"
    private var _capabilities: Set<String> = []

    // Confined to `queue`.
    private var stage = Stage.handshake
    private var rxCipher: MessageCipher?
    private var decryptedAny = false
    private let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    private let myNonce = Pairing.randomBytes(16)
    private var peerNonce = Data()
    private var peerPublic = Data()
    private var haveKey = false
    private var candidateKey: Data?
    private var localAccepted = false
    private var remoteAccepted = false

    init(_ nw: NWConnection, outgoing: Bool, raw: Bool = false) {
        self.nw = nw
        self.outgoing = outgoing
        self.raw = raw
    }

    var peerID: String? {
        lock.lock(); defer { lock.unlock() }
        return _peerID
    }

    /// Features the other Mac's build supports (empty for 1.0.x).
    var capabilities: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return _capabilities
    }

    var peerName: String {
        lock.lock(); defer { lock.unlock() }
        return _peerName
    }

    /// Bytes handed to the network stack but not yet sent. Used for back-pressure on video.
    var pendingBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return pending
    }

    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    var isEncrypted: Bool {
        lock.lock(); defer { lock.unlock() }
        return txCipher != nil
    }

    func start() {
        nw.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Log.write("Spojení navázáno (\(self.outgoing ? "odchozí" : "příchozí")): \(self.nw.endpoint)")
                if self.raw {
                    DispatchQueue.main.async { self.onReady?(self) }
                } else {
                    self.send(Wire.json(.hello, Hello(id: self.myID, name: self.myName, version: 2,
                                                      nonce: self.myNonce,
                                                      pairKey: self.ephemeral.publicKey.rawRepresentation,
                                                      capabilities: Capability.all)))
                }
                self.readHeader()
            case .failed(let error):
                Log.write("Spojení selhalo: \(error)")
                self.close()
            case .cancelled:
                self.close()
            case .waiting(let error):
                Log.write("Spojení čeká: \(error)")
                if self.outgoing {
                    Self.queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                        if let self, case .waiting = self.nw.state { self.cancel() }
                    }
                }
            default:
                break
            }
        }
        nw.start(queue: Self.queue)
    }

    /// Takes a packed message (`Wire.pack`), encrypts it once the connection is secure.
    func send(_ packed: Data, completion: (() -> Void)? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, packed.count >= 5 else { completion?(); return }
        var out = packed
        if let tx = txCipher {
            let plain = packed.subdata(in: (packed.startIndex + 4)..<packed.endIndex)
            guard let sealed = try? tx.seal(plain) else { completion?(); return }
            var w = ByteWriter()
            w.data.reserveCapacity(sealed.count + 4)
            w.u32(UInt32(sealed.count))
            w.bytes(sealed)
            out = w.data
        }
        let n = out.count
        pending += n
        // Sending under the lock keeps the wire order equal to the nonce order.
        nw.send(content: out, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.lock(); self.pending -= n; self.lock.unlock()
            completion?()
            if let error {
                Log.write("Chyba při odesílání: \(error)")
                self.cancel()
            }
        })
    }

    func cancel() { nw.cancel() }

    /// Self-test only: encrypt both directions with a known key.
    func enableTestEncryption(key: SymmetricKey, sendDirection: UInt8) {
        Self.queue.sync {
            rxCipher = MessageCipher(key: key, direction: 1 - sendDirection)
        }
        lock.lock()
        txCipher = MessageCipher(key: key, direction: sendDirection)
        lock.unlock()
    }

    /// The person confirmed the pairing code on this Mac.
    func acceptPairing() {
        Self.queue.async {
            guard self.stage == .pairing, !self.localAccepted else { return }
            self.localAccepted = true
            self.send(Wire.pack(.pairAccept, Data([1])))
            if self.remoteAccepted { self.finishPairing() }
        }
    }

    private func close() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        guard !wasClosed else { return }
        nw.cancel()
        DispatchQueue.main.async { self.onClosed?(self) }
    }

    private func readHeader() {
        nw.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil, let data, data.count == 4 else { self.close(); return }
            let length = data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length >= 1, length <= 128_000_000 else { self.close(); return }
            self.readBody(Int(length))
        }
    }

    private func readBody(_ n: Int) {
        nw.receive(minimumIncompleteLength: n, maximumLength: n) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil, var body = data, body.count == n else { self.close(); return }
            if let rx = self.rxCipher {
                do {
                    body = try rx.open(body)
                    self.decryptedAny = true
                } catch {
                    Log.write("Zprávu nejde rozšifrovat – klíče Maců nesouhlasí")
                    // A key that never worked on this connection is stale: pair again next time.
                    if !self.decryptedAny, !self.isSelfTest, let id = self.peerID { TrustStore.shared.set(nil, for: id) }
                    self.close()
                    return
                }
            }
            guard body.count >= 1, let type = MsgType(rawValue: body[body.startIndex]) else {
                self.readHeader()
                return
            }
            let payload = body.subdata(in: (body.startIndex + 1)..<body.endIndex)
            if self.raw || self.stage == .secure {
                if type != .hello && type != .auth && type != .pairAccept {
                    DispatchQueue.main.async { self.onMessage?(self, type, payload) }
                }
            } else {
                self.handshake(type, payload)
            }
            if !self.isClosed { self.readHeader() }
        }
    }

    // MARK: Handshake (runs on `queue`)

    private func handshake(_ type: MsgType, _ payload: Data) {
        switch type {
        case .hello:
            guard peerID == nil, let hello = Wire.parse(Hello.self, payload) else { return }
            lock.lock()
            _peerID = hello.id
            _peerName = hello.name
            _capabilities = Set(hello.capabilities ?? [])
            lock.unlock()
            peerNonce = hello.nonce ?? Data()
            peerPublic = hello.pairKey ?? Data()
            if hello.id == myID {
                guard allowSelf() else {
                    Log.write("Odmítám spojení sám se sebou")
                    close()
                    return
                }
                isSelfTest = true
                stage = .secure
                DispatchQueue.main.async { self.onSecure?(self) }
                return
            }
            haveKey = TrustStore.shared.key(for: hello.id) != nil
            send(Wire.json(.auth, Auth(paired: haveKey)))

        case .auth:
            guard let peerID, let auth = Wire.parse(Auth.self, payload) else { return }
            if haveKey && auth.paired, let key = TrustStore.shared.key(for: peerID) {
                enableEncryption(pairingKey: key, peerID: peerID)
                stage = .secure
                Log.write("Šifrované spojení s \(peerName)")
                DispatchQueue.main.async { self.onSecure?(self) }
            } else {
                guard peerPublic.count == 32, peerNonce.count == 16,
                      let key = try? Pairing.pairingKey(ephemeral, peerPublic: peerPublic) else {
                    Log.write("Druhý Mac poslal neplatné údaje pro párování")
                    close()
                    return
                }
                candidateKey = key
                stage = .pairing
                let code = Pairing.code(ephemeral.publicKey.rawRepresentation, peerPublic)
                DispatchQueue.main.async { self.onPairingNeeded?(self, code) }
            }

        case .pairAccept:
            guard stage == .pairing else { return }
            remoteAccepted = true
            if localAccepted { finishPairing() }

        default:
            break
        }
    }

    private func finishPairing() {
        guard let peerID, let key = candidateKey else { return }
        TrustStore.shared.set(key, for: peerID)
        enableEncryption(pairingKey: key, peerID: peerID)
        stage = .secure
        Log.write("Spárováno s \(peerName), spojení je šifrované")
        DispatchQueue.main.async { self.onSecure?(self) }
    }

    private func enableEncryption(pairingKey: Data, peerID: String) {
        let iAmLow = myID < peerID
        let session = Pairing.sessionKey(pairingKey: pairingKey,
                                         lowNonce: iAmLow ? myNonce : peerNonce,
                                         highNonce: iAmLow ? peerNonce : myNonce)
        let mine: UInt8 = iAmLow ? 0 : 1
        rxCipher = MessageCipher(key: session, direction: 1 - mine)
        lock.lock()
        txCipher = MessageCipher(key: session, direction: mine)
        lock.unlock()
    }
}

/// Advertises this Mac over Bonjour, finds the other Mac and keeps one connection to it.
/// All state lives on the main thread.
final class PeerManager {
    static let serviceType = "_mostoken._tcp"

    let myID = Settings.instanceID
    let myName: String = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"

    private(set) var connections: [PeerConnection] = []
    private(set) var activePeer: PeerConnection?
    private(set) var listenerPort: UInt16?
    private(set) var selfTestEnabled = false
    var discoveredCount: Int { discovered.count }

    var onMessage: ((PeerConnection, MsgType, Data) -> Void)?
    var onPeerReady: ((PeerConnection) -> Void)?
    var onPeerLost: ((PeerConnection) -> Void)?
    var onChange: (() -> Void)?

    private var pairingPromptFor: Set<String> = []
    private var rejected: Set<String> = []
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var discovered: [String: NWEndpoint] = [:]
    private var firstSeen: [String: Date] = [:]
    private var lastAttempt: [String: Date] = [:]
    private var retryTimer: Timer?
    private let queue = DispatchQueue(label: "mostoken.peers")

    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let p = NWParameters(tls: nil, tcp: tcp)
        p.includePeerToPeer = true
        p.serviceClass = .interactiveVideo
        return p
    }

    func start() {
        startListener()
        startBrowser()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.connectIfNeeded()
        }
    }

    private func startListener() {
        do {
            let l = try NWListener(using: Self.parameters())
            l.service = NWListener.Service(name: myName, type: Self.serviceType, domain: nil,
                                           txtRecord: NWTXTRecord(["id": myID]))
            l.newConnectionHandler = { [weak self] nw in
                DispatchQueue.main.async { self?.adopt(nw, outgoing: false, expected: nil) }
            }
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let port = l.port?.rawValue
                    Log.write("Čekám na spojení na portu \(port ?? 0) jako „\(self?.myName ?? "")“")
                    DispatchQueue.main.async { self?.listenerPort = port }
                case .failed(let error):
                    Log.write("Naslouchání selhalo: \(error)")
                    l.cancel()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.startListener() }
                default:
                    break
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            Log.write("Nelze začít naslouchat: \(error)")
        }
    }

    private func startBrowser() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: Self.parameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async { self?.update(results) }
        }
        b.stateUpdateHandler = { state in
            switch state {
            case .failed(let error): Log.write("Hledání Maců selhalo: \(error)")
            case .waiting(let error): Log.write("Hledání Maců čeká: \(error)")
            default: break
            }
        }
        b.start(queue: queue)
        browser = b
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var found: [String: NWEndpoint] = [:]
        for r in results {
            guard case .bonjour(let txt) = r.metadata, let id = txt["id"], id != myID else { continue }
            found[id] = r.endpoint
        }
        discovered = found
        Log.write("Nalezené Macy v okolí: \(found.count)")
        connectIfNeeded()
        onChange?()
    }

    /// The Mac with the smaller ID dials; the other one waits, but dials anyway after a few
    /// seconds in case the first one cannot see it (e.g. Local Network permission denied).
    func connectIfNeeded() {
        let now = Date()
        for (id, endpoint) in discovered where !rejected.contains(id) {
            if connections.contains(where: { !$0.isSelfTest && ($0.peerID == id || $0.expectedID == id) }) { continue }
            let seen = firstSeen[id] ?? now
            firstSeen[id] = seen
            if let last = lastAttempt[id], now.timeIntervalSince(last) < 5 { continue }
            if myID < id || now.timeIntervalSince(seen) > 6 {
                lastAttempt[id] = now
                Log.write("Připojuji se k Macu \(id.prefix(8))…")
                adopt(NWConnection(to: endpoint, using: Self.parameters()), outgoing: true, expected: id)
            }
        }
    }

    private func adopt(_ nw: NWConnection, outgoing: Bool, expected: String?, selfTest: Bool = false) {
        let c = PeerConnection(nw, outgoing: outgoing)
        c.expectedID = expected
        c.isSelfTest = selfTest
        c.myID = myID
        c.myName = myName
        c.allowSelf = { [weak self] in self?.selfTestEnabled ?? false }
        c.onSecure = { [weak self] c in self?.secured(c) }
        c.onPairingNeeded = { [weak self] c, code in self?.pairingNeeded(c, code: code) }
        c.onMessage = { [weak self] c, type, data in
            if c.helloReceived { self?.onMessage?(c, type, data) }
        }
        c.onClosed = { [weak self] c in self?.closed(c) }
        connections.append(c)
        c.start()
    }

    // MARK: Pairing

    private func pairingNeeded(_ c: PeerConnection, code: String) {
        guard let id = c.peerID, !c.isClosed else { return }
        if rejected.contains(id) { c.cancel(); return }
        // Both Macs must confirm the same connection (= the same code): prefer the one dialed by
        // the Mac with the smaller ID, fall back to another one only if it does not show up.
        let preferredInitiator = min(myID, id)
        let initiator = c.outgoing ? myID : id
        if initiator != preferredInitiator {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !c.isClosed else { return }
                if self.connections.contains(where: { $0 !== c && $0.peerID == id && !$0.isClosed }) {
                    c.cancel()
                } else {
                    self.askPairing(c, code: code)
                }
            }
            return
        }
        askPairing(c, code: code)
    }

    private func askPairing(_ c: PeerConnection, code: String) {
        guard let id = c.peerID, !pairingPromptFor.contains(id), !c.isClosed else { return }
        pairingPromptFor.insert(id)
        c.awaitingPairing = true
        Log.write("Párování s \(c.peerName), kód \(code)")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Spárovat s Macem „\(c.peerName)“?"
        alert.informativeText = """
        Ověřovací kód:  \(code)

        Zkontroluj, že druhý Mac ukazuje úplně stejný kód, a pak klikni na Spárovat na obou Macích. Spáruj jen svůj vlastní Mac.

        Po spárování je spojení mezi Macy šifrované.
        """
        alert.addButton(withTitle: "Spárovat")
        alert.addButton(withTitle: "Zrušit")
        let accepted = alert.runModal() == .alertFirstButtonReturn
        pairingPromptFor.remove(id)
        c.awaitingPairing = false
        if accepted {
            c.acceptPairing()
            HUD.show("Čekám na potvrzení na druhém Macu…")
        } else {
            rejected.insert(id)
            Log.write("Párování s \(c.peerName) zrušeno")
            c.cancel()
        }
    }

    func forgetPairedMacs() {
        TrustStore.shared.removeAll()
        rejected.removeAll()
        for c in connections where !c.isSelfTest { c.cancel() }
        Log.write("Spárované Macy zapomenuty")
    }

    // MARK: Connection lifecycle

    private func secured(_ c: PeerConnection) {
        guard !c.isClosed, let peerID = c.peerID else { return }
        if !c.isSelfTest, let other = connections.first(where: {
            $0 !== c && $0.helloReceived && !$0.isSelfTest && $0.peerID == peerID
        }) {
            // Both Macs dialed each other: keep the connection opened by the smaller ID.
            let preferred = min(myID, peerID)
            let initiator: (PeerConnection) -> String = { $0.outgoing ? self.myID : peerID }
            if initiator(c) == preferred && initiator(other) != preferred {
                other.cancel()
            } else {
                c.cancel()
                return
            }
        }
        c.helloReceived = true
        Log.write("Připojeno k: \(c.peerName)\(c.isSelfTest ? " (test na tomto Macu)" : "")")
        if c.isSelfTest {
            if c.outgoing { activePeer = c }
        } else {
            if activePeer == nil || activePeer?.isClosed == true || (activePeer?.isSelfTest == true && !selfTestEnabled) {
                activePeer = c
            }
            HUD.show("Propojeno s Macem „\(c.peerName)“")
            onPeerReady?(c)
        }
        onChange?()
    }

    private func closed(_ c: PeerConnection) {
        connections.removeAll { $0 === c }
        if c.helloReceived { Log.write("Odpojeno od: \(c.peerName)") }
        if activePeer === c {
            activePeer = selfTestEnabled
                ? connections.first { $0.isSelfTest && $0.outgoing && $0.helloReceived }
                : connections.first { $0.helloReceived && !$0.isSelfTest }
        }
        onPeerLost?(c)
        onChange?()
    }

    func startSelfTest() {
        selfTestEnabled = true
        guard let port = listenerPort, let p = NWEndpoint.Port(rawValue: port) else {
            Log.write("Test nelze spustit – naslouchání ještě neběží")
            return
        }
        adopt(NWConnection(host: "127.0.0.1", port: p, using: Self.parameters()),
              outgoing: true, expected: myID, selfTest: true)
        onChange?()
    }

    func stopSelfTest() {
        selfTestEnabled = false
        for c in connections where c.isSelfTest { c.cancel() }
        activePeer = connections.first { $0.helloReceived && !$0.isSelfTest }
        onChange?()
    }
}
