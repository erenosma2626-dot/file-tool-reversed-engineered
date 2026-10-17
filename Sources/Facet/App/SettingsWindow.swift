import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, formats, folders, about
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .formats: return "square.grid.2x2"
        case .folders: return "folder"
        case .about: return "info.circle"
        }
    }
}

final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private let selection = TabSelection()

    final class TabSelection: ObservableObject { @Published var tab: SettingsTab = .general }

    func show(tab: SettingsTab? = nil) {
        if let tab { selection.tab = tab }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: SettingsView(selection: selection))
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar-only app once Settings is closed.
        NSApp.setActivationPolicy(.accessory)
    }
}

struct SettingsView: View {
    @ObservedObject var selection: SettingsWindow.TabSelection

    var body: some View {
        VStack(spacing: 0) {
            TabBar(selection: $selection.tab)
                .padding(.top, 34)
                .padding(.bottom, 8)
            Group {
                switch selection.tab {
                case .general: GeneralPane()
                case .formats: FormatsPane()
                case .folders: FoldersPane()
                case .about: AboutPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 560, height: 620)
        .background(.regularMaterial)
    }
}

private struct TabBar: View {
    @Binding var selection: SettingsTab
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = tab }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.symbol)
                            .symbolVariant(selection == tab ? .fill : .none)
                        Text(tab.title)
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .foregroundStyle(selection == tab ? Color.primary : Color.secondary)
                    .background {
                        if selection == tab {
                            Capsule()
                                .fill(Color.accentColor.opacity(0.22))
                                .matchedGeometryEffect(id: "tab", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .facetSurface(Capsule())
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Style", selection: $prefs.style) {
                    ForEach(AppearanceStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Show in menu bar", isOn: $prefs.showMenuBarIcon)
            }

            Section {
                Toggle("Launch at login", isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.launchAtLogin = $0 }))
                Toggle("Sound and haptic feedback", isOn: $prefs.feedback)
            }

            Section {
                keyPicker("Conversion wheel", selection: $prefs.convertKey)
                keyPicker("Tools wheel", selection: $prefs.toolsKey)
                keyPicker("Actions wheel", selection: $prefs.actionsKey)
            } header: {
                Text("Drag modifiers")
            } footer: {
                if hasConflict {
                    Label("Two wheels use the same keys.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Text("Start dragging files, then tap the keys. Tap again to close the wheel; drop on the centre to cancel.")
                }
            }

            Section {
                Picker("Float", selection: $prefs.floatBehavior) {
                    ForEach(FloatBehavior.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Shake while dragging to open a shelf", isOn: $prefs.shakeToFloat)
                Toggle("Dragging out moves the file (cut & paste)", isOn: $prefs.floatCutMode)
            } header: {
                Text("Float")
            } footer: {
                Text("Hold ⌥ while dragging out of a shelf to copy instead of move.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var hasConflict: Bool {
        let keys = [prefs.convertKey, prefs.toolsKey, prefs.actionsKey]
        return Set(keys).count < keys.count
    }

    private func keyPicker(_ title: String, selection: Binding<ModifierCombo>) -> some View {
        Picker(title, selection: selection) {
            ForEach(ModifierCombo.choices) { combo in
                Text("\(combo.symbols)  \(combo.name)").tag(combo)
            }
        }
    }
}

// MARK: - Formats

private struct FormatsPane: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        Form {
            ForEach(Category.allCases) { category in
                Section {
                    chips(category, Catalog.convertFormats(for: category).map { WheelItem.convert($0) }, label: "Convert")
                    let tools = Catalog.tools(for: category, count: 2).map { WheelItem.tool($0) }
                    if !tools.isEmpty { chips(category, tools, label: "Tools") }
                } header: {
                    Label(category.title, systemImage: category.symbol)
                }
            }
            Section {
                Text("Turned-off items are hidden from the wheels. Formats that need Pages or ffmpeg appear only when those are installed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func chips(_ category: Category, _ items: [WheelItem], label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(items) { item in
                    let on = prefs.isEnabled(category: category, itemID: item.id)
                    Button {
                        prefs.setEnabled(!on, category: category, itemID: item.id)
                    } label: {
                        HStack(spacing: 4) {
                            if let symbol = item.symbol { Image(systemName: symbol).font(.system(size: 10)) }
                            Text(item.title)
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .background(Capsule().fill(on ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05)))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(on ? 0 : 0.12), lineWidth: 0.5))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Wrapping row layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

// MARK: - Folders

private struct FoldersPane: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        Form {
            Section("Save results") {
                Picker("Location", selection: $prefs.outputLocation) {
                    Text("Next to the original").tag(OutputLocation.besideOriginal)
                    Text("In a folder").tag(OutputLocation.folder)
                }
                .pickerStyle(.radioGroup)
                if prefs.outputLocation == .folder {
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                        Text((prefs.outputFolder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                    }
                }
            }
            Section {
                Toggle("Reveal results in Finder", isOn: $prefs.revealOutput)
                Toggle("Move originals to the Trash after converting", isOn: $prefs.trashOriginals)
            } footer: {
                Text("Facet never overwrites a file: names get a number when taken.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { prefs.outputFolder = url.path }
    }
}

// MARK: - About

private struct AboutPane: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                VStack(spacing: 3) {
                    Text("Facet").font(.system(size: 22, weight: .semibold))
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    keyCard(prefs.convertKey, "Convert")
                    keyCard(prefs.toolsKey, "Tools")
                    keyCard(prefs.actionsKey, "Actions")
                }
                Text("Start dragging any file, then tap a key. The wheel stays open until you drop.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 0) {
                    statusRow("Media engine (ffmpeg)", ok: FFmpeg.isAvailable,
                              detail: FFmpeg.path.map { ($0 as NSString).abbreviatingWithTildeInPath }
                                ?? "Optional · adds MKV, WebM and MP3")
                    Divider().padding(.leading, 36)
                    statusRow("Pages", ok: PagesBridge.isInstalled,
                              detail: PagesBridge.isInstalled ? "Used to save .pages files" : "Optional · free on the App Store")
                }
                .padding(.vertical, 4)
                .facetSurface(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 40)

                Text("Everything runs on this Mac. Nothing is uploaded.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private func keyCard(_ combo: ModifierCombo, _ label: String) -> some View {
        VStack(spacing: 8) {
            Text(combo.symbols)
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .frame(width: 62, height: 50)
                .facetSurface(RoundedRectangle(cornerRadius: 12, style: .continuous), tint: Tint.subtle)
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    private func statusRow(_ title: String, ok: Bool, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? Color.green : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
