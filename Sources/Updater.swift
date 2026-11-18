import AppKit
import CryptoKit
import Security
import ServiceManagement

enum AppInfo {
    static let repo = "Thominho/mostoken"
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Checks GitHub Releases, downloads a newer build, verifies it is signed by the same key as the
/// running app, swaps the app bundle and relaunches.
final class Updater {
    /// Returns false while windows are being shared, so an update never interrupts work.
    var canInstallNow: () -> Bool = { true }
    private var timer: Timer?
    private var busy = false

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { self.check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { [weak self] _ in
            self?.check(manual: false)
        }
    }

    func check(manual: Bool) {
        guard !busy, manual || Settings.autoUpdate else { return }
        busy = true
        if manual { HUD.show("Hledám aktualizace…") }
        Task {
            do {
                let release = try await Self.latestRelease()
                guard Self.isNewer(release.version, than: AppInfo.version) else {
                    self.finish("Máš nejnovější verzi \(AppInfo.version)", manual: manual)
                    return
                }
                Log.write("Nalezena nová verze \(release.version) (teď \(AppInfo.version))")
                let allowed = await MainActor.run { self.canInstallNow() }
                guard allowed || manual else {
                    Log.write("Aktualizaci nainstaluji, až nebudou sdílená žádná okna")
                    self.finish(nil, manual: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 600) { self.check(manual: false) }
                    return
                }
                let app = try await Self.download(release)
                try Self.verifySignature(of: app)
                await MainActor.run { self.install(app, version: release.version) }
            } catch {
                self.finish("Aktualizace se nepovedla: \(error.localizedDescription)", manual: manual)
            }
        }
    }

    private func finish(_ message: String?, manual: Bool) {
        DispatchQueue.main.async {
            self.busy = false
            if let message {
                Log.write(message)
                if manual { HUD.show(message) }
            }
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private struct Release {
        let version: String
        let zip: URL
        let checksum: URL?
    }

    private static func latestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppInfo.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MostOken-updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw UpdateError("GitHub odpověděl \(code)") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else { throw UpdateError("Neznámá odpověď GitHubu") }
        func asset(_ name: String) -> URL? {
            guard let a = assets.first(where: { $0["name"] as? String == name }),
                  let s = a["browser_download_url"] as? String else { return nil }
            return URL(string: s)
        }
        guard let zip = asset("MostOken.zip") else { throw UpdateError("Vydání neobsahuje MostOken.zip") }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, zip: zip, checksum: asset("MostOken.zip.sha256"))
    }

    private static func download(_ r: Release) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MostOken-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (downloaded, _) = try await URLSession.shared.download(from: r.zip)
        let zip = dir.appendingPathComponent("MostOken.zip")
        try FileManager.default.moveItem(at: downloaded, to: zip)

        if let checksumURL = r.checksum {
            let (data, _) = try await URLSession.shared.data(from: checksumURL)
            let expected = String(decoding: data, as: UTF8.self).split(whereSeparator: { $0 == " " || $0 == "\n" })
                .first.map { $0.lowercased() } ?? ""
            let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
            guard expected == actual else { throw UpdateError("Kontrolní součet staženého souboru nesouhlasí") }
        }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, dir.path]
        try unzip.run()
        unzip.waitUntilExit()
        let app = dir.appendingPathComponent("MostOken.app")
        guard unzip.terminationStatus == 0, FileManager.default.fileExists(atPath: app.path) else {
            throw UpdateError("Stažený archiv nejde rozbalit")
        }
        return app
    }

    /// The new app must satisfy the running app's designated requirement, i.e. be signed with the
    /// same certificate. Local development builds (ad-hoc signed) therefore never auto-update.
    private static func verifySignature(of app: URL) throws {
        var me: SecCode?
        var meStatic: SecStaticCode?
        var requirement: SecRequirement?
        var candidate: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &meStatic) == errSecSuccess, let meStatic,
              SecCodeCopyDesignatedRequirement(meStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate else {
            throw UpdateError("Podpis nejde ověřit")
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSCheckNestedCode)
                               | UInt32(kSecCSStrictValidate))
        let status = SecStaticCodeCheckValidity(candidate, flags, requirement)
        guard status == errSecSuccess else {
            throw UpdateError("Nová verze není podepsaná stejným klíčem (\(status)) – u vývojové verze je to v pořádku")
        }
    }

    private func install(_ newApp: URL, version: String) {
        let current = Bundle.main.bundleURL
        guard current.pathExtension == "app" else { finish("Aplikace neběží z balíčku .app", manual: true); return }
        do {
            _ = try FileManager.default.replaceItemAt(current, withItemAt: newApp)
        } catch {
            finish("Aktualizaci nejde nainstalovat: \(error.localizedDescription)", manual: true)
            return
        }
        Log.write("Nainstalována verze \(version), restartuji")
        HUD.show("MostOken \(version) nainstalován, restartuji…")
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1.5; /usr/bin/open \"$0\"", current.path]
        try? relaunch.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Log.write("Spouštění po přihlášení: \(enabled ? "zapnuto" : "vypnuto")")
        } catch {
            Log.write("Spouštění po přihlášení nejde změnit: \(error.localizedDescription)")
        }
    }
}
