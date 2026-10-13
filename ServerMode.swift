import AppKit
import IOKit
import ServiceManagement
import UserNotifications

struct Status {
    var serverMode = false
    var sleepDisabled = false
    var ssh = false
    var screenSharing = false
    var power = ""
    var screensaver = ""
    var fileVault = false
    var appNap = ""
    var tailscale = ""
    var tailscaleIP = ""
}

// MARK: - Virtual display

struct Resolution: Equatable {
    let width: Int
    let height: Int

    static let presets = [
        Resolution(width: 1280, height: 800),
        Resolution(width: 1440, height: 900),
        Resolution(width: 1920, height: 1080),
    ]

    var label: String { "\(width)×\(height)" }
    var key: String { "\(width)x\(height)" }

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    init?(key: String) {
        let parts = key.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        self.init(width: parts[0], height: parts[1])
    }
}

/// Keeps a virtual monitor alive so a closed-lid Mac still has a screen for computer use.
final class VirtualDisplayController {
    private var display: CGVirtualDisplay?
    private(set) var resolution: Resolution?

    var isOn: Bool { display != nil }
    var displayID: CGDirectDisplayID? { display?.displayID }

    func start(_ resolution: Resolution) -> Bool {
        stop()
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "Server Mode Display"
        descriptor.maxPixelsWide = UInt32(resolution.width)
        descriptor.maxPixelsHigh = UInt32(resolution.height)
        // Pretend to be a ~96 dpi monitor.
        let pixelsPerMillimeter = 96.0 / 25.4
        descriptor.sizeInMillimeters = CGSize(
            width: Double(resolution.width) / pixelsPerMillimeter,
            height: Double(resolution.height) / pixelsPerMillimeter
        )
        descriptor.vendorID = 0x5352
        descriptor.productID = 0x0001
        descriptor.serialNum = 1
        descriptor.terminationHandler = { [weak self] _, _ in
            self?.display = nil
            self?.resolution = nil
        }

        let display = CGVirtualDisplay(descriptor: descriptor)
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [
            CGVirtualDisplayMode(
                width: UInt32(resolution.width),
                height: UInt32(resolution.height),
                refreshRate: 60
            ),
        ]
        guard let display, display.apply(settings) else { return false }
        self.display = display
        self.resolution = resolution
        return true
    }

    func stop() {
        display = nil
        resolution = nil
    }
}

/// Off, always on, or on only while the lid is closed and no other screen is connected.
enum VirtualDisplayMode: String {
    case off, on, auto
}

/// True when there is a screen other than the built-in one (a monitor, a dummy plug or our virtual display).
func hasNonBuiltinDisplay(excluding excluded: CGDirectDisplayID? = nil) -> Bool {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids.contains { CGDisplayIsBuiltin($0) == 0 && $0 != excluded }
}

func isLidClosed() -> Bool {
    let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard rootDomain != 0 else { return false }
    defer { IOObjectRelease(rootDomain) }
    let state = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
    return state?.takeRetainedValue() as? Bool ?? false
}

/// Calls `onChange` on the main queue when the lid opens or closes or a screen comes or goes.
/// Bursts of events are coalesced, and the clamshell state is read a moment later so it has settled.
final class DisplayWatcher {
    private let onChange: () -> Void
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var pending: DispatchWorkItem?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()

        // The root power domain sends a message on every lid open and close.
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        if rootDomain != 0, let port = IONotificationPortCreate(kIOMainPortDefault) {
            IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
            notifyPort = port
            IOServiceAddInterestNotification(port, rootDomain, kIOGeneralInterest, { context, _, _, _ in
                context.map { Unmanaged<DisplayWatcher>.fromOpaque($0).takeUnretainedValue().schedule() }
            }, context, &notifier)
            IOObjectRelease(rootDomain)
        }

        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            context.map { Unmanaged<DisplayWatcher>.fromOpaque($0).takeUnretainedValue().schedule() }
        }, context)
    }

    private func schedule() {
        DispatchQueue.main.async {
            self.pending?.cancel()
            let work = DispatchWorkItem(block: self.onChange)
            self.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let virtualDisplayKey = "virtualDisplay"
    private static let virtualDisplayModeKey = "virtualDisplayMode"

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let virtualDisplay = VirtualDisplayController()
    private var displayWatcher: DisplayWatcher?
    private var status = Status()
    private var isRefreshing = false
    private var needsRefresh = false
    private var timer: Timer?
    private var battery: BatteryInfo?
    private var chargeLimit: Int?
    private var healthBaseline: HealthLog.Entry?
    private var warnedHot = false

    private var scriptPath: String {
        Bundle.main.path(forResource: "server-mode", ofType: nil)!
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        statusItem.menu = menu
        displayWatcher = DisplayWatcher { [weak self] in self?.applyVirtualDisplayMode() }
        applyVirtualDisplayMode()
        updateUI()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
            // In case a lid or display event was missed.
            self?.applyVirtualDisplayMode()
        }
    }

    // MARK: Virtual display

    /// Before Auto existed, a saved resolution alone meant "on".
    private var virtualDisplayMode: VirtualDisplayMode {
        get {
            if let raw = UserDefaults.standard.string(forKey: Self.virtualDisplayModeKey),
               let mode = VirtualDisplayMode(rawValue: raw) {
                return mode
            }
            return UserDefaults.standard.string(forKey: Self.virtualDisplayKey) == nil ? .off : .on
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.virtualDisplayModeKey) }
    }

    private var virtualDisplayResolution: Resolution {
        UserDefaults.standard.string(forKey: Self.virtualDisplayKey).flatMap(Resolution.init(key:))
            ?? Resolution.presets[1]
    }

    /// Auto wants the display only while the lid is closed and nothing else gives the Mac a screen.
    private var wantsVirtualDisplay: Bool {
        switch virtualDisplayMode {
        case .off: return false
        case .on: return true
        case .auto: return isLidClosed() && !hasNonBuiltinDisplay(excluding: virtualDisplay.displayID)
        }
    }

    /// Starts or stops the display to match the mode. Returns false if macOS refused to create it.
    @discardableResult
    private func applyVirtualDisplayMode() -> Bool {
        defer { updateUI() }
        let resolution = virtualDisplayResolution
        guard wantsVirtualDisplay else {
            if virtualDisplay.isOn { virtualDisplay.stop() }
            return true
        }
        guard virtualDisplay.resolution != resolution else { return true }
        return virtualDisplay.start(resolution)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    // MARK: State

    /// Reads status in the background (the script takes most of a second) and updates the menu when done.
    private func refresh() {
        guard !isRefreshing else {
            // Re-check once the current run finishes, so a toggle is never shown stale.
            needsRefresh = true
            return
        }
        isRefreshing = true
        needsRefresh = false
        let path = scriptPath
        DispatchQueue.global(qos: .userInitiated).async {
            let status = Self.readStatus(scriptPath: path)
            let battery = BatteryInfo.read()
            let chargeLimit = ChargeLimit.current()
            let baseline = battery.flatMap(HealthLog.record)
            DispatchQueue.main.async {
                // On a timeout, keep showing the last known status and try again next time.
                if let status { self.status = status }
                self.battery = battery
                self.chargeLimit = chargeLimit
                self.healthBaseline = baseline
                self.warnIfHot()
                self.isRefreshing = false
                self.updateUI()
                if self.needsRefresh { self.refresh() }
            }
        }
    }

    /// Returns nil if the script doesn't finish in time, so one hung check can't freeze the menu.
    private static func readStatus(scriptPath: String) -> Status? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath, "status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return Status()
        }

        var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        guard done.wait(timeout: .now() + 15) == .success else {
            process.terminate()
            return nil
        }
        process.waitUntilExit()

        var values: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            values[parts[0]] = parts.count == 2 ? parts[1] : ""
        }
        return Status(
            serverMode: values["server-mode"] == "on",
            sleepDisabled: values["sleep-disabled"] == "on",
            ssh: values["ssh"] == "on",
            screenSharing: values["screen-sharing"] == "on",
            power: values["power"] ?? "",
            screensaver: values["screensaver"] ?? "",
            fileVault: values["filevault"] == "on",
            appNap: values["app-nap"] ?? "",
            tailscale: values["tailscale"] ?? "",
            tailscaleIP: values["tailscale-ip"] ?? ""
        )
    }

    private func updateUI() {
        // The Xserve glyph is drawn smaller than the laptop; at 15 pt it fills the same box.
        let symbol = status.serverMode ? "xserve" : "laptopcomputer"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Server Mode")?
            .withSymbolConfiguration(.init(pointSize: status.serverMode ? 15 : 13, weight: .regular))
        image?.isTemplate = true
        statusItem.button?.image = image
        rebuildMenu()
    }

    // MARK: Menu

    /// Status arrives while the menu is open, and swapping out items of an open menu leaves
    /// it with a stale height. So when the layout is unchanged, update the existing items in place.
    private func rebuildMenu() {
        let items = makeMenuItems()
        let sameLayout = menu.items.count == items.count
            && zip(menu.items, items).allSatisfy { $0.isSeparatorItem == $1.isSeparatorItem }
        guard sameLayout else {
            menu.removeAllItems()
            items.forEach(menu.addItem)
            return
        }
        for (old, new) in zip(menu.items, items) where !old.isSeparatorItem {
            old.title = new.title
            old.action = new.action
            old.target = new.target
            old.state = new.state
            old.isEnabled = new.isEnabled
            old.image = new.image
            old.representedObject = new.representedObject
            if let submenu = new.submenu {
                new.submenu = nil
                old.submenu = submenu
            }
        }
    }

    private func makeMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        items.append(info(serverModeLabel))
        items.append(action(
            status.serverMode ? "Turn Server Mode Off" : "Turn Server Mode On",
            #selector(toggleServerMode)
        ))
        items.append(virtualDisplayItem())
        items.append(.separator())

        items.append(checklistItem())
        if let battery {
            items.append(batteryCareItem(battery))
        }
        items.append(.separator())

        let login = action("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        items.append(login)
        items.append(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return items
    }

    /// The guard daemon only blocks sleep on AC power, so "on" can still be paused.
    private var serverModeLabel: String {
        guard status.serverMode else { return "Server Mode: Off" }
        return status.sleepDisabled ? "Server Mode: On" : "Server Mode: On (paused on battery)"
    }

    private func virtualDisplayItem() -> NSMenuItem {
        let mode = virtualDisplayMode
        let resolution = virtualDisplayResolution
        let title: String
        switch mode {
        case .off: title = "Virtual Display: Off"
        case .on: title = "Virtual Display: \(resolution.label)"
        case .auto: title = "Virtual Display: Auto, \(virtualDisplay.isOn ? resolution.label : "Standing By")"
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        for (option, label) in [(VirtualDisplayMode.off, "Off"), (.on, "On"), (.auto, "Auto")] {
            let row = action(label, #selector(selectVirtualDisplayMode(_:)))
            row.representedObject = option.rawValue
            if option == .auto { row.toolTip = "On only while the lid is closed and no monitor is connected" }
            row.state = mode == option ? .on : .off
            submenu.addItem(row)
        }
        submenu.addItem(.separator())
        for preset in Resolution.presets {
            let row = action(preset.label, #selector(selectVirtualDisplayResolution(_:)))
            row.representedObject = preset.key
            row.state = preset == resolution ? .on : .off
            submenu.addItem(row)
        }
        item.submenu = submenu
        return item
    }

    /// The checklist lives in a submenu; its title says whether anything needs fixing.
    private func checklistItem() -> NSMenuItem {
        let checks = checklistChecks()
        let problems = checks.filter { !$0.ready }.count
        let item = NSMenuItem(
            title: problems == 0 ? "Checklist: All Set" : "Checklist: \(problems) to Fix",
            action: nil,
            keyEquivalent: ""
        )
        item.image = symbol(problems == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                            problems == 0 ? .systemGreen : .systemOrange)
        let submenu = NSMenu()
        for check in checks {
            let row = NSMenuItem(title: check.title, action: check.action, keyEquivalent: "")
            row.target = self
            row.image = symbol(check.ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                               check.ready ? .systemGreen : .systemOrange)
            submenu.addItem(row)
        }
        submenu.addItem(.separator())
        submenu.addItem(info(status.fileVault ? "FileVault on: unlock over SSH after a reboot" : "FileVault off"))
        item.submenu = submenu
        return item
    }

    private func checklistChecks() -> [(ready: Bool, title: String, action: Selector?)] {
        var checks: [(ready: Bool, title: String, action: Selector?)] = []
        func check(_ ready: Bool, _ title: String, _ action: Selector? = nil) {
            checks.append((ready, title, action))
        }

        check(status.power == "AC Power", status.power == "AC Power" ? "On AC Power" : "On Battery")
        // In Auto the virtual display is only there while the lid is closed, which is enough.
        let hasDisplay = virtualDisplayMode == .auto || hasNonBuiltinDisplay()
        check(hasDisplay, hasDisplay ? "Display for Closed Lid" : "No Display for Closed Lid: Turn On Virtual Display")
        check(status.ssh, status.ssh ? "SSH" : "SSH Off", #selector(openSharing))
        check(status.screenSharing, status.screenSharing ? "Screen Sharing" : "Screen Sharing Off", #selector(openSharing))

        switch status.tailscale {
        case "Running":
            check(true, "Tailscale \(status.tailscaleIP) — Click to Copy", #selector(copyTailscaleIP))
        case "missing":
            check(false, "Tailscale Not Installed", #selector(openTailscale))
        case "":
            check(false, "Tailscale: Checking…")
        default:
            check(false, "Tailscale \(status.tailscale)", #selector(openTailscale))
        }

        let screensaverOff = status.screensaver == "0"
        check(screensaverOff, screensaverOff ? "Screen Saver Off" : "Screen Saver On — Click to Turn Off", #selector(disableScreensaver))
        let appNapOff = status.appNap == "off"
        let napping = status.appNap.replacingOccurrences(of: ",", with: ", ")
        check(appNapOff, appNapOff ? "App Nap Off" : "App Nap On in \(napping) — Click to Turn Off", #selector(disableAppNap))
        return checks
    }

    private func batteryCareItem(_ battery: BatteryInfo) -> NSMenuItem {
        let temperature = battery.temperature.map { "\(Int($0.rounded())) °C" }
        let limited = (chargeLimit ?? 100) < 100
        let title: String
        if battery.isHot, let temperature {
            title = "Battery Care: Hot, \(temperature)"
        } else if let chargeLimit {
            title = limited ? "Battery Care: Limit \(chargeLimit)%" : "Battery Care: No Limit"
        } else {
            title = "Battery Care"
        }
        // Charging to 100% and sitting there all day is what wears out a server's battery.
        let ok = !battery.isHot && (limited || !status.serverMode)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = symbol(ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill", ok ? .systemGreen : .systemOrange)

        let submenu = NSMenu()
        let state: String
        if !battery.onAC {
            state = "on battery"
        } else if battery.isCharging {
            state = "charging"
        } else if limited {
            state = "held at the limit"
        } else {
            state = "not charging"
        }
        submenu.addItem(info("Charge: \(battery.percent)%, \(state)"))
        if let health = battery.health {
            submenu.addItem(info(String(format: "Health: %.1f%%, %d cycles", health, battery.cycles)))
            if let baseline = healthBaseline, abs(baseline.health - health) >= 0.1 {
                submenu.addItem(info(String(format: "Since %@: %+.1f%%", baseline.date, health - baseline.health)))
            }
        }
        if let temperature {
            submenu.addItem(info("Temperature: \(temperature)\(battery.isHot ? ", too hot" : "")"))
        }

        if let chargeLimit {
            submenu.addItem(.separator())
            submenu.addItem(info("Charge Limit"))
            for percent in ChargeLimit.options + [100] {
                let option = action(percent == 100 ? "Off (100%)" : "\(percent)%", #selector(selectChargeLimit(_:)))
                option.representedObject = percent
                option.state = percent == chargeLimit ? .on : .off
                submenu.addItem(option)
            }
            submenu.addItem(.separator())
            let full = action("Charge to Full Now", #selector(chargeToFullNow))
            full.isEnabled = limited
            submenu.addItem(full)
        }
        item.submenu = submenu
        return item
    }

    private func symbol(_ name: String, _ color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(hierarchicalColor: color))
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: Actions

    @objc private func toggleServerMode() {
        let command = status.serverMode ? "off" : "on"
        let escapedPath = scriptPath.replacingOccurrences(of: "'", with: "'\\''")
        let source = "do shell script \"/bin/bash '\(escapedPath)' \(command)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        // -128 means the user cancelled the password prompt.
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {
            showAlert("Couldn’t switch server mode", error[NSAppleScript.errorMessage] as? String ?? "\(error)")
        }
        refresh()
    }

    @objc private func selectVirtualDisplayMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = VirtualDisplayMode(rawValue: raw) else { return }
        virtualDisplayMode = mode
        applyVirtualDisplay()
    }

    /// Picking a resolution while the display is off also turns it on.
    @objc private func selectVirtualDisplayResolution(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        UserDefaults.standard.set(key, forKey: Self.virtualDisplayKey)
        if virtualDisplayMode == .off { virtualDisplayMode = .on }
        applyVirtualDisplay()
    }

    private func applyVirtualDisplay() {
        if !applyVirtualDisplayMode() {
            virtualDisplayMode = .off
            showAlert("Couldn’t create the virtual display", "macOS rejected the display settings.")
        }
        // Give macOS a moment to add or remove the screen before re-checking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.updateUI() }
    }

    @objc private func copyTailscaleIP() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(status.tailscaleIP, forType: .string)
    }

    @objc private func openTailscale() {
        if status.tailscale == "missing" {
            NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macsys")
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macos") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }

    @objc private func selectChargeLimit(_ sender: NSMenuItem) {
        guard let percent = sender.representedObject as? Int else { return }
        if !ChargeLimit.set(percent) {
            showAlert("Couldn’t change the charge limit", "Set it in System Settings → Battery → Charging instead.")
        }
        refresh()
    }

    @objc private func chargeToFullNow() {
        if !ChargeLimit.chargeToFullNow() {
            showAlert("Couldn’t start a full charge", "Use “Charge to Full Now” in the battery menu instead.")
        }
        refresh()
    }

    /// A closed lid traps heat, and heat ages a battery faster than anything else, so say when it gets hot.
    private func warnIfHot() {
        guard let battery, let temperature = battery.temperature else { return }
        if battery.isHot, !warnedHot {
            warnedHot = true
            let content = UNMutableNotificationContent()
            content.title = "Battery is hot: \(Int(temperature.rounded())) °C"
            content.body = "Give the Mac some air: open the lid or stand it on its side."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "hot", content: content, trigger: nil))
        } else if temperature < BatteryInfo.hotTemperature - 3 {
            warnedHot = false
        }
    }

    @objc private func disableAppNap() {
        for app in ["T3 Code (Alpha)", "Helm"] {
            guard let id = Bundle(path: "/Applications/\(app).app")?.bundleIdentifier else { continue }
            UserDefaults(suiteName: id)?.set(true, forKey: "NSAppSleepDisabled")
        }
        refresh()
    }

    @objc private func openSharing() {
        openSettings("com.apple.Sharing-Settings.extension")
    }

    @objc private func disableScreensaver() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["-currentHost", "write", "com.apple.screensaver", "idleTime", "-int", "0"]
        try? process.run()
        process.waitUntilExit()
        refresh()
    }

    private func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:\(pane)")!)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert("Couldn’t change launch at login", error.localizedDescription)
        }
        rebuildMenu()
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
