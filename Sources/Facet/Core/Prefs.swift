import AppKit
import ServiceManagement

/// A modifier-key combination that opens a wheel while dragging.
struct ModifierCombo: Hashable, Identifiable {
    static let relevant: NSEvent.ModifierFlags = [.shift, .command, .option, .control]

    let flags: NSEvent.ModifierFlags
    var id: UInt { flags.rawValue }

    init(_ flags: NSEvent.ModifierFlags) { self.flags = flags.intersection(Self.relevant) }

    static let shift = ModifierCombo(.shift)
    static let command = ModifierCombo(.command)
    static let option = ModifierCombo(.option)
    static let control = ModifierCombo(.control)

    static let choices: [ModifierCombo] = [
        .shift, .command, .option, .control,
        ModifierCombo([.option, .shift]), ModifierCombo([.control, .shift]),
        ModifierCombo([.command, .shift]), ModifierCombo([.control, .option]),
    ]

    var symbols: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    var name: String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("Control") }
        if flags.contains(.option) { parts.append("Option") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.command) { parts.append("Command") }
        return parts.joined(separator: " + ")
    }

    static func == (a: ModifierCombo, b: ModifierCombo) -> Bool { a.flags.rawValue == b.flags.rawValue }
    func hash(into h: inout Hasher) { h.combine(flags.rawValue) }
}

enum AppearanceStyle: String, CaseIterable, Identifiable {
    case glass, solid
    var id: String { rawValue }
    var title: String { self == .glass ? "Glass" : "Solid" }
}

enum FloatBehavior: String, CaseIterable, Identifiable {
    case newShelf, addToRecent
    var id: String { rawValue }
    var title: String { self == .newShelf ? "Create a new shelf" : "Add to the last shelf" }
}

enum OutputLocation: String, CaseIterable, Identifiable {
    case besideOriginal, folder
    var id: String { rawValue }
}

/// User preferences, persisted in UserDefaults.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    @Published var style: AppearanceStyle { didSet { d.set(style.rawValue, forKey: "style") } }
    @Published var feedback: Bool { didSet { d.set(feedback, forKey: "feedback") } }
    @Published var showMenuBarIcon: Bool { didSet { d.set(showMenuBarIcon, forKey: "menuBarIcon"); AppDelegate.shared?.updateStatusItem() } }
    @Published var convertKey: ModifierCombo { didSet { d.set(convertKey.flags.rawValue, forKey: "key.convert") } }
    @Published var toolsKey: ModifierCombo { didSet { d.set(toolsKey.flags.rawValue, forKey: "key.tools") } }
    @Published var actionsKey: ModifierCombo { didSet { d.set(actionsKey.flags.rawValue, forKey: "key.actions") } }
    @Published var floatBehavior: FloatBehavior { didSet { d.set(floatBehavior.rawValue, forKey: "floatBehavior") } }
    @Published var shakeToFloat: Bool { didSet { d.set(shakeToFloat, forKey: "shakeToFloat") } }
    @Published var floatCutMode: Bool { didSet { d.set(floatCutMode, forKey: "floatCutMode") } }
    @Published var outputLocation: OutputLocation { didSet { d.set(outputLocation.rawValue, forKey: "output") } }
    @Published var outputFolder: String { didSet { d.set(outputFolder, forKey: "outputFolder") } }
    @Published var trashOriginals: Bool { didSet { d.set(trashOriginals, forKey: "trashOriginals") } }
    @Published var revealOutput: Bool { didSet { d.set(revealOutput, forKey: "revealOutput") } }
    @Published private(set) var disabled: Set<String> { didSet { d.set(Array(disabled), forKey: "disabledItems") } }

    private init() {
        style = AppearanceStyle(rawValue: d.string(forKey: "style") ?? "") ?? .glass
        feedback = d.object(forKey: "feedback") as? Bool ?? true
        showMenuBarIcon = d.object(forKey: "menuBarIcon") as? Bool ?? true
        convertKey = Prefs.combo(d, "key.convert", .shift)
        toolsKey = Prefs.combo(d, "key.tools", .command)
        actionsKey = Prefs.combo(d, "key.actions", .control)
        floatBehavior = FloatBehavior(rawValue: d.string(forKey: "floatBehavior") ?? "") ?? .newShelf
        shakeToFloat = d.object(forKey: "shakeToFloat") as? Bool ?? true
        floatCutMode = d.object(forKey: "floatCutMode") as? Bool ?? true
        outputLocation = OutputLocation(rawValue: d.string(forKey: "output") ?? "") ?? .besideOriginal
        outputFolder = d.string(forKey: "outputFolder") ?? (NSSearchPathForDirectoriesInDomains(.downloadsDirectory, .userDomainMask, true).first ?? NSHomeDirectory())
        trashOriginals = d.bool(forKey: "trashOriginals")
        revealOutput = d.bool(forKey: "revealOutput")
        disabled = Set(d.stringArray(forKey: "disabledItems") ?? [])
    }

    private static func combo(_ d: UserDefaults, _ key: String, _ fallback: ModifierCombo) -> ModifierCombo {
        guard let raw = d.object(forKey: key) as? UInt else { return fallback }
        let c = ModifierCombo(NSEvent.ModifierFlags(rawValue: raw))
        return c.flags.isEmpty ? fallback : c
    }

    func key(for kind: WheelKind) -> ModifierCombo {
        switch kind {
        case .convert: return convertKey
        case .tools: return toolsKey
        case .actions: return actionsKey
        }
    }

    func isEnabled(category: Category, itemID: String) -> Bool {
        !disabled.contains(category.rawValue + "." + itemID)
    }

    func setEnabled(_ on: Bool, category: Category, itemID: String) {
        let key = category.rawValue + "." + itemID
        if on { disabled.remove(key) } else { disabled.insert(key) }
    }

    // MARK: Launch at login (ServiceManagement, no helper app needed)

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Facet: launch at login failed: \(error)")
            }
            objectWillChange.send()
        }
    }
}
