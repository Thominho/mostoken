import AppKit

let arguments = CommandLine.arguments

if arguments.contains("--selftest") {
    Log.echo = false
    DispatchQueue.global().async {
        let ok = SelfTest.run()
        exit(ok ? 0 : 1)
    }
    dispatchMain()
} else if let i = arguments.firstIndex(of: "--test-source") {
    let path = i + 1 < arguments.count ? arguments[i + 1] : NSTemporaryDirectory() + "mostoken-test.json"
    let app = NSApplication.shared
    let delegate = TestSourceDelegate(output: URL(fileURLWithPath: path))
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
} else {
    if let i = arguments.firstIndex(of: "--downloads"), i + 1 < arguments.count {
        FileReceiver.directoryOverride = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    // `pkill MostOken` (installer, updates) should still put parked windows back.
    signal(SIGTERM, SIG_IGN)
    let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    terminationSource.setEventHandler { NSApp.terminate(nil) }
    terminationSource.resume()
    app.run()
}
