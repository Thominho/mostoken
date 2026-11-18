import Foundation

/// Message types exchanged between the two Macs.
/// Every message on the wire is: [UInt32 big-endian length][UInt8 type][payload].
enum MsgType: UInt8 {
    case hello = 1
    case windowOpen = 2
    case geometry = 3
    case frame = 4
    case windowClose = 5
    case input = 6
    case returnWindow = 7
    case keyframeRequest = 8
    case resizeRequest = 9
    case arrangement = 10
    case fileBegin = 11
    case fileChunk = 12
    case fileEnd = 13
    case auth = 14
    case pairAccept = 15
    case viewInfo = 16
    case focus = 17
    case visibility = 18
    case closeWindow = 19
}

/// What this build understands; sent in Hello so both Macs only use features both support.
enum Capability {
    static let hevcAlpha = "hevc-alpha"
    static let popups = "popups"
    static let all: [String] = VideoEncoder.hevcAlphaSupported ? [popups, hevcAlpha] : [popups]
}

/// First message on every connection (plaintext). `nonce` and `pairKey` feed the key agreement.
struct Hello: Codable {
    var id: String
    var name: String
    var version: Int
    var nonce: Data?
    var pairKey: Data?
    var capabilities: [String]?
}

/// Where the window's own title bar buttons are (points from the window's top-left, [x, y, w, h]).
struct Chrome: Codable {
    var close: [Double]?
    var minimize: [Double]?
    var zoom: [Double]?
    var titleHeight: Double?
}

/// Receiver → sender: the backing scale of the screen the window is shown on.
struct ViewInfo: Codable {
    var wid: UInt32
    var scale: Double
}

/// Receiver → sender: whether the window can be seen at all (not minimized / covered).
struct Visibility: Codable {
    var wid: UInt32
    var visible: Bool
}

/// Second message (plaintext): whether this Mac already has a pairing key for the other one.
struct Auth: Codable {
    var paired: Bool
}

/// Sent when a window moves to the other Mac. `crossing` is where along the shared edge the
/// pointer left this Mac (0...1, top→bottom for left/right, left→right for top/bottom);
/// `grabX/grabY` is the point of the window under the pointer, in points from its top-left.
struct WindowOpen: Codable {
    var wid: UInt32
    var title: String
    var app: String
    var width: Double
    var height: Double
    var crossing: Double?
    var grabX: Double?
    var grabY: Double?
    /// Set for menus and other pop-up windows: the window they belong to, and their position
    /// relative to the last click in that window.
    var parent: UInt32?
    var offsetX: Double?
    var offsetY: Double?
    var chrome: Chrome?
}

/// The receiving Mac gives the window back, optionally at a given edge position.
struct ReturnWindow: Codable {
    var wid: UInt32
    var crossing: Double?
    var grabX: Double?
    var grabY: Double?
}

/// "You are on my <side>", chosen by a person at `changedAt`.
struct Arrangement: Codable {
    var side: String
    var changedAt: Double
}

struct FileBegin: Codable {
    var tid: UInt32
    var wid: UInt32
    var name: String
    var size: Int64
}

struct FileEnd: Codable {
    var tid: UInt32
}

struct Geometry: Codable {
    var wid: UInt32
    var width: Double
    var height: Double
    var chrome: Chrome?
}

struct WindowRef: Codable {
    var wid: UInt32
}

/// Mouse / keyboard event captured on the receiving Mac and replayed on the sending Mac.
/// x / y are normalized (0...1) from the window's top-left corner.
struct InputEvent: Codable {
    enum Kind: String, Codable {
        case mouseDown, mouseUp, mouseDrag, mouseMove, scroll, keyDown, keyUp, flags
    }
    var wid: UInt32
    var kind: Kind
    var x: Double = 0
    var y: Double = 0
    var button: Int = 0
    var clicks: Int = 1
    var dx: Double = 0
    var dy: Double = 0
    var precise: Bool = false
    var phase: Int = 0
    var momentum: Int = 0
    var keyCode: UInt16 = 0
    var flags: UInt64 = 0
    var isRepeat: Bool = false
}

struct ByteWriter {
    var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) {
        data.append(UInt8(v >> 8)); data.append(UInt8(v & 0xff))
    }
    mutating func u32(_ v: UInt32) {
        data.append(UInt8((v >> 24) & 0xff)); data.append(UInt8((v >> 16) & 0xff))
        data.append(UInt8((v >> 8) & 0xff)); data.append(UInt8(v & 0xff))
    }
    mutating func bytes(_ d: Data) { data.append(d) }
}

struct ByteReader {
    let data: Data
    var offset: Int

    init(_ d: Data) { data = d; offset = d.startIndex }

    var remaining: Int { data.endIndex - offset }

    mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return data[offset]
    }
    mutating func u16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        let v = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
        offset += 2
        return v
    }
    mutating func u32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(data[offset + i]) }
        offset += 4
        return v
    }
    mutating func bytes(_ n: Int) -> Data? {
        guard n >= 0, remaining >= n else { return nil }
        let d = data.subdata(in: offset..<(offset + n))
        offset += n
        return d
    }
    mutating func rest() -> Data {
        let d = data.subdata(in: offset..<data.endIndex)
        offset = data.endIndex
        return d
    }
}

/// One compressed H.264 frame (AVCC, 4-byte NAL length prefixes).
/// Keyframes carry the SPS/PPS parameter sets so the receiver can (re)build its decoder.
/// H.264: keyframes carry SPS/PPS in `parameterSets`.
/// HEVC with alpha (`isHEVC`): keyframes carry one serialized format description instead.
struct VideoFrame {
    var wid: UInt32
    var isKey: Bool
    var parameterSets: [Data]
    var data: Data
    var isHEVC = false

    func encoded() -> Data {
        var w = ByteWriter()
        w.data.reserveCapacity(data.count + 64)
        w.u32(wid)
        w.u8((isKey ? 1 : 0) | (isHEVC ? 2 : 0))
        w.u8(UInt8(min(parameterSets.count, 255)))
        for p in parameterSets.prefix(255) {
            w.u16(UInt16(min(p.count, 65535)))
            w.bytes(p.prefix(65535))
        }
        w.bytes(data)
        return w.data
    }

    static func decode(_ d: Data) -> VideoFrame? {
        var r = ByteReader(d)
        guard let wid = r.u32(), let flags = r.u8(), let n = r.u8() else { return nil }
        var sets: [Data] = []
        for _ in 0..<n {
            guard let l = r.u16(), let p = r.bytes(Int(l)) else { return nil }
            sets.append(p)
        }
        return VideoFrame(wid: wid, isKey: flags & 1 != 0, parameterSets: sets, data: r.rest(), isHEVC: flags & 2 != 0)
    }
}

enum Wire {
    static func pack(_ type: MsgType, _ payload: Data) -> Data {
        var w = ByteWriter()
        w.data.reserveCapacity(payload.count + 5)
        w.u32(UInt32(payload.count + 1))
        w.u8(type.rawValue)
        w.bytes(payload)
        return w.data
    }

    static func json<T: Encodable>(_ type: MsgType, _ value: T) -> Data {
        pack(type, (try? JSONEncoder().encode(value)) ?? Data())
    }

    static func parse<T: Decodable>(_ type: T.Type, _ data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}
