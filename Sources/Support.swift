import Foundation

enum Log {
    static let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MostOken.log")
    static var echo = false
    static var prefix = ""
    private static let queue = DispatchQueue(label: "mostoken.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func reset() {
        queue.sync {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data().write(to: url)
        }
    }

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(prefix)\(message)\n"
        if echo { print(line, terminator: "") }
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url)
            }
        }
    }
}

/// Where the other Mac stands relative to this one.
enum Side: String, CaseIterable {
    case left, right, top, bottom

    var opposite: Side {
        switch self {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }

    var label: String {
        switch self {
        case .left: return "Vlevo"
        case .right: return "Vpravo"
        case .top: return "Nahoře"
        case .bottom: return "Dole"
        }
    }
}

enum Settings {
    private static var d: UserDefaults { .standard }

    static var peerSide: Side {
        Side(rawValue: d.string(forKey: "peerSide") ?? "") ?? .right
    }
    /// When the arrangement was last chosen by a person (on either Mac). Newest wins when syncing.
    static var peerSideChangedAt: Double {
        d.double(forKey: "peerSideChangedAt")
    }
    static func setPeerSide(_ side: Side, changedAt: Double) {
        d.set(side.rawValue, forKey: "peerSide")
        d.set(changedAt, forKey: "peerSideChangedAt")
    }

    static var edgeDrag: Bool {
        get { d.object(forKey: "edgeDrag") as? Bool ?? true }
        set { d.set(newValue, forKey: "edgeDrag") }
    }
    static var parkOriginal: Bool {
        get { d.object(forKey: "parkOriginal") as? Bool ?? true }
        set { d.set(newValue, forKey: "parkOriginal") }
    }
    static var injectViaCursor: Bool {
        get { d.bool(forKey: "injectViaCursor") }
        set { d.set(newValue, forKey: "injectViaCursor") }
    }
    static var autoUpdate: Bool {
        get { d.object(forKey: "autoUpdate") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoUpdate") }
    }
    static var didShowWelcome: Bool {
        get { d.bool(forKey: "didShowWelcome") }
        set { d.set(newValue, forKey: "didShowWelcome") }
    }
    static var instanceID: String {
        if let s = d.string(forKey: "instanceID") { return s }
        let s = UUID().uuidString
        d.set(s, forKey: "instanceID")
        return s
    }
}
