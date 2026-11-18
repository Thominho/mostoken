import AppKit
import SwiftUI

final class SettingsModel: ObservableObject {
    @Published var side: Side {
        didSet { if side != oldValue && !applying { onSideChanged?(side) } }
    }
    @Published var edgeDrag: Bool { didSet { Settings.edgeDrag = edgeDrag } }
    @Published var park: Bool { didSet { Settings.parkOriginal = park } }
    @Published var cursorMouse: Bool { didSet { Settings.mouseMode = cursorMouse ? "cursor" : "background" } }
    @Published var autoUpdate: Bool { didSet { Settings.autoUpdate = autoUpdate } }
    @Published var launchAtLogin: Bool {
        didSet { if launchAtLogin != oldValue && !applying { LoginItem.set(launchAtLogin) } }
    }
    @Published var peerName: String?
    @Published var screenOK = false
    @Published var accessibilityOK = false

    let myName: String
    let version = AppInfo.version
    var onSideChanged: ((Side) -> Void)?
    var onCheckUpdates: (() -> Void)?
    var onForgetPaired: (() -> Void)?
    @Published var encrypted = false
    private var applying = false

    init(myName: String) {
        self.myName = myName
        side = Settings.peerSide
        edgeDrag = Settings.edgeDrag
        park = Settings.parkOriginal
        cursorMouse = Settings.mouseMode == "cursor"
        autoUpdate = Settings.autoUpdate
        launchAtLogin = LoginItem.isEnabled
    }

    func refresh(peerName: String?) {
        applying = true
        if side != Settings.peerSide { side = Settings.peerSide }
        if launchAtLogin != LoginItem.isEnabled { launchAtLogin = LoginItem.isEnabled }
        applying = false
        self.peerName = peerName
        screenOK = Permissions.screenRecording
        accessibilityOK = Permissions.accessibility
    }
}

/// Drag the other Mac to the side where it really stands (like System Settings → Displays).
struct ArrangementCanvas: View {
    @Binding var side: Side
    let myName: String
    let peerName: String

    @State private var drag: CGSize = .zero
    private let box = CGSize(width: 150, height: 96)
    private let gap: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let peer = peerCenter(center)
            ZStack {
                macBox(name: myName, subtitle: "Tento Mac", highlighted: false)
                    .position(center)
                macBox(name: peerName, subtitle: "Druhý Mac – přetáhni", highlighted: true)
                    .position(x: peer.x + drag.width, y: peer.y + drag.height)
                    .gesture(
                        DragGesture()
                            .onChanged { value in drag = value.translation }
                            .onEnded { value in
                                let dx = peer.x + value.translation.width - center.x
                                let dy = peer.y + value.translation.height - center.y
                                let newSide: Side = abs(dx) / box.width >= abs(dy) / box.height
                                    ? (dx >= 0 ? .right : .left)
                                    : (dy >= 0 ? .bottom : .top)
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    side = newSide
                                    drag = .zero
                                }
                            }
                    )
            }
        }
    }

    private func peerCenter(_ c: CGPoint) -> CGPoint {
        switch side {
        case .left: return CGPoint(x: c.x - box.width - gap, y: c.y)
        case .right: return CGPoint(x: c.x + box.width + gap, y: c.y)
        case .top: return CGPoint(x: c.x, y: c.y - box.height - gap)
        case .bottom: return CGPoint(x: c.x, y: c.y + box.height + gap)
        }
    }

    private func macBox(name: String, subtitle: String, highlighted: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: highlighted ? "desktopcomputer" : "laptopcomputer")
                .font(.system(size: 24))
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 6)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .frame(width: box.width, height: box.height)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(highlighted ? Color.accentColor.opacity(0.16) : Color.gray.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(highlighted ? Color.accentColor : Color.gray.opacity(0.5), lineWidth: highlighted ? 2 : 1))
        .contentShape(Rectangle())
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox(label: Text("Kde stojí druhý Mac").font(.headline)) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Přetáhni druhý Mac na stranu, kde opravdu stojí. Okna pak přetahuješ přes tento okraj obrazovky. Nastavení se samo přenese i na druhý Mac.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ArrangementCanvas(side: $model.side, myName: model.myName,
                                      peerName: model.peerName ?? "Druhý Mac")
                        .frame(height: 310)
                    Picker("Druhý Mac je", selection: $model.side) {
                        ForEach(Side.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("Tip: stejně rozlož Macy i v Nastavení systému → Monitory, aby myš přecházela přes stejný okraj.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
            }

            GroupBox(label: Text("Chování").font(.headline)) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Posílat okna přetažením k okraji obrazovky", isOn: $model.edgeDrag)
                    Toggle("Odsunout původní okno stranou, dokud je na druhém Macu", isOn: $model.park)
                    Toggle("Klikat přes kurzor (jen když některá aplikace na kliknutí nereaguje)", isOn: $model.cursorMouse)
                    Text("⌃⌥⌘ + šipka pošle aktivní okno na druhý Mac nebo ho vrátí zpět.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Divider()
                    Toggle("Spouštět MostOken po přihlášení", isOn: $model.launchAtLogin)
                    HStack {
                        Toggle("Automaticky instalovat aktualizace", isOn: $model.autoUpdate)
                        Spacer()
                        Text("verze \(model.version)").font(.caption).foregroundColor(.secondary)
                        Button("Zkontrolovat") { model.onCheckUpdates?() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            GroupBox(label: Text("Stav").font(.headline)) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        status(model.peerName != nil,
                               model.peerName.map { "Připojeno k Macu „\($0)“\(model.encrypted ? " – šifrovaně" : "")" }
                                   ?? "Druhý Mac zatím není připojený")
                        Spacer()
                        Button("Zapomenout spárované Macy") { model.onForgetPaired?() }
                    }
                    HStack {
                        status(model.screenOK, "Záznam obrazovky (posílání oken)")
                        Spacer()
                        if !model.screenOK { Button("Otevřít…") { Permissions.open("Privacy_ScreenCapture") } }
                    }
                    HStack {
                        status(model.accessibilityOK, "Zpřístupnění (ovládání oken z druhého Macu)")
                        Spacer()
                        if !model.accessibilityOK { Button("Otevřít…") { Permissions.open("Privacy_Accessibility") } }
                    }
                    if !model.screenOK || !model.accessibilityOK {
                        Text("Po povolení MostOken ukonči a spusť znovu.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func status(_ ok: Bool, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundColor(ok ? .green : .orange)
            Text(text)
        }
    }
}

enum SettingsWindow {
    private static var window: NSWindow?

    static func show(model: SettingsModel) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = "MostOken – nastavení"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
