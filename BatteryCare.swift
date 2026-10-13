import Foundation
import IOKit

/// A snapshot of the battery, read without admin rights.
struct BatteryInfo {
    var percent = 0
    var isCharging = false
    var onAC = false
    /// Nominal capacity as a percentage of the design capacity, the number System Settings calls "Maximum Capacity".
    var health: Double?
    var cycles = 0
    var temperature: Double?

    static let hotTemperature = 40.0

    var isHot: Bool { (temperature ?? 0) >= Self.hotTemperature }

    static func read() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }

        var info = BatteryInfo()
        info.percent = props["CurrentCapacity"] as? Int ?? 0
        info.isCharging = props["IsCharging"] as? Bool ?? false
        info.onAC = props["ExternalConnected"] as? Bool ?? false
        info.cycles = props["CycleCount"] as? Int ?? 0
        let data = props["BatteryData"] as? [String: Any] ?? [:]
        if let nominal = data["NominalChargeCapacity"] as? Int,
           let design = (data["DesignCapacity"] ?? props["DesignCapacity"]) as? Int, design > 0 {
            info.health = Double(nominal) / Double(design) * 100
        }
        // macOS 27 no longer puts the temperature in the registry, so ask the SMC.
        info.temperature = SMC.readFloat("TB0T")
        return info
    }
}

// MARK: - SMC

/// Reads float keys from the System Management Controller.
enum SMC {
    private static let readBytes: UInt8 = 5
    private static let readKeyInfo: UInt8 = 9

    static func readFloat(_ key: String) -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(connection) }

        var input = SMCParam()
        input.key = key.utf8.reduce(0) { $0 << 8 | UInt32($1) }
        input.data8 = CChar(bitPattern: readKeyInfo)
        guard let info = call(connection, &input), info.keyInfo.dataType == fourCC("flt "),
              info.keyInfo.dataSize == 4 else { return nil }

        input.keyInfo.dataSize = info.keyInfo.dataSize
        input.data8 = CChar(bitPattern: readBytes)
        guard let output = call(connection, &input) else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(4)) }
        let value = bytes.withUnsafeBytes { $0.load(as: Float.self) }
        return Double(value)
    }

    private static func call(_ connection: io_connect_t, _ input: inout SMCParam) -> SMCParam? {
        var output = SMCParam()
        var size = MemoryLayout<SMCParam>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCParam>.stride, &output, &size)
        guard result == KERN_SUCCESS, output.result == 0 else { return nil }
        return output
    }

    private static func fourCC(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}

// MARK: - Charge limit

/// The macOS charge limit (System Settings → Battery → Charging), set through the private PowerUI framework,
/// the same way third-party battery apps do it on macOS 27. No admin rights needed.
/// Each selector's type encoding is checked before calling, so a changed signature fails safely instead of crashing.
enum ChargeLimit {
    static let options = [80, 85, 90, 95]

    private typealias ErrorOut = UnsafeMutablePointer<NSError?>?
    private typealias GetLimit = @convention(c) (AnyObject, Selector, ErrorOut) -> UInt8
    private typealias GetFlag = @convention(c) (AnyObject, Selector, ErrorOut) -> UInt64
    private typealias SetLimit = @convention(c) (AnyObject, Selector, UInt8, ErrorOut) -> Bool
    private typealias Action = @convention(c) (AnyObject, Selector, ErrorOut) -> Bool

    private static let client: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW) != nil,
              let type = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type else { return nil }
        let instance = type.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject
        return instance?
            .perform(NSSelectorFromString("initWithClientName:"), with: "ServerMode")?
            .takeUnretainedValue() as? NSObject
    }()

    private static func method<T>(_ name: String, _ encoding: String, as _: T.Type) -> (NSObject, Selector, T)? {
        let selector = NSSelectorFromString(name)
        guard let client, let method = class_getInstanceMethod(type(of: client), selector),
              let types = method_getTypeEncoding(method), String(cString: types) == encoding else { return nil }
        return (client, selector, unsafeBitCast(method_getImplementation(method), to: T.self))
    }

    /// The limit in percent, 100 when it's off, or nil when this Mac or macOS has no charge limit.
    static func current() -> Int? {
        guard let (client, enabledSel, isEnabled) = method("isMCLCurrentlyEnabled:", "Q24@0:8^@16", as: GetFlag.self),
              let (_, limitSel, getLimit) = method("getMCLLimitWithError:", "C24@0:8^@16", as: GetLimit.self) else {
            return nil
        }
        var error: NSError?
        let enabled = isEnabled(client, enabledSel, &error)
        guard error == nil else { return nil }
        let limit = Int(getLimit(client, limitSel, &error))
        guard error == nil else { return nil }
        return enabled == 0 ? 100 : limit
    }

    /// Sets the limit; 100 turns it off.
    static func set(_ percent: Int) -> Bool {
        var error: NSError?
        if percent >= 100 {
            guard let (client, sel, disable) = method("disableMCL:", "B24@0:8^@16", as: Action.self) else { return false }
            return disable(client, sel, &error)
        }
        // The firmware refuses limits below 80%.
        guard options.contains(percent),
              let (client, setSel, setLimit) = method("setMCLLimit:error:", "B28@0:8C16^@20", as: SetLimit.self),
              let (_, enableSel, enable) = method("enableMCL:", "B24@0:8^@16", as: Action.self) else { return false }
        return setLimit(client, setSel, UInt8(percent), &error) && enable(client, enableSel, &error)
    }

    /// Charges to 100% once, like "Charge to Full Now" in the battery menu.
    static func chargeToFullNow() -> Bool {
        guard let (client, sel, override) = method("temporarilyDisableMCL:", "B24@0:8^@16", as: Action.self) else {
            return false
        }
        var error: NSError?
        return override(client, sel, &error)
    }
}

// MARK: - Health log

/// One line per day in a CSV, so a slow decline in battery health is visible over months.
enum HealthLog {
    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ServerMode/battery-health.csv")
    }

    struct Entry {
        let date: String
        let health: Double
    }

    /// Records today's health once, and returns the oldest entry to compare against.
    static func record(_ info: BatteryInfo) -> Entry? {
        let entries = read()
        let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: .withFullDate)
        if let health = info.health, entries.last?.date != today {
            let line = String(format: "%@,%.1f,%d\n", today, health, info.cycles)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(("date,health,cycles\n" + line).utf8).write(to: url)
            }
        }
        return entries.first
    }

    private static func read() -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").dropFirst().compactMap { line in
            let fields = line.split(separator: ",")
            guard fields.count >= 2, let health = Double(fields[1]) else { return nil }
            return Entry(date: String(fields[0]), health: health)
        }
    }
}
