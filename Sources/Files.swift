import AppKit

/// Sends files dropped onto a window that lives on the other Mac.
enum FileSender {
    private static let queue = DispatchQueue(label: "mostoken.files")
    private static var nextID: UInt32 = 1

    static func send(_ urls: [URL], wid: UInt32, over peer: PeerConnection, done: @escaping (Int, Int) -> Void) {
        queue.async {
            var sent = 0, skipped = 0
            for url in urls {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
                      let handle = try? FileHandle(forReadingFrom: url) else {
                    skipped += 1
                    continue
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                let tid = nextID
                nextID += 1
                peer.send(Wire.json(.fileBegin, FileBegin(tid: tid, wid: wid, name: url.lastPathComponent, size: size)))
                var ok = true
                while true {
                    // Leave room on the connection for video frames.
                    while peer.pendingBytes > 2_000_000 && !peer.isClosed { usleep(4000) }
                    if peer.isClosed { ok = false; break }
                    let chunk = handle.readData(ofLength: 1 << 20)
                    if chunk.isEmpty { break }
                    var w = ByteWriter()
                    w.u32(tid)
                    w.bytes(chunk)
                    peer.send(Wire.pack(.fileChunk, w.data))
                }
                try? handle.close()
                guard ok else { break }
                peer.send(Wire.json(.fileEnd, FileEnd(tid: tid)))
                sent += 1
                Log.write("Soubor odeslán: \(url.lastPathComponent) (\(size / 1024) kB)")
            }
            DispatchQueue.main.async { done(sent, skipped) }
        }
    }
}

/// Receives files on the Mac that owns the window and stores them in Downloads/MostOken.
final class FileReceiver {
    static var directoryOverride: URL?

    var onComplete: ((URL, UInt32) -> Void)?
    private var open: [UInt32: (handle: FileHandle, url: URL, wid: UInt32)] = [:]

    private var directory: URL {
        if let d = Self.directoryOverride { return d }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return downloads.appendingPathComponent("MostOken", isDirectory: true)
    }

    func begin(_ b: FileBegin) {
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var name = (b.name as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        if name.isEmpty || name.hasPrefix(".") { name = "soubor" + name }
        var url = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            Log.write("Soubor nejde vytvořit: \(url.path)")
            return
        }
        open[b.tid] = (handle, url, b.wid)
    }

    func chunk(_ data: Data) {
        var r = ByteReader(data)
        guard let tid = r.u32(), let entry = open[tid] else { return }
        entry.handle.write(r.rest())
    }

    func end(_ e: FileEnd) {
        guard let entry = open.removeValue(forKey: e.tid) else { return }
        try? entry.handle.close()
        Log.write("Soubor přijat: \(entry.url.path)")
        onComplete?(entry.url, entry.wid)
    }

    /// Connection lost: delete half-received files.
    func abortAll() {
        for (_, entry) in open {
            try? entry.handle.close()
            try? FileManager.default.removeItem(at: entry.url)
        }
        open.removeAll()
    }
}
