// 系统层：pmset、盖子状态、电池、免密规则
import AppKit
import IOKit
import IOKit.ps

enum System {
    static let pmset = "/usr/bin/pmset"
    static let sudoersPath = "/etc/sudoers.d/arguslid"
    /// 旧版本（LidAwake / Argus）安装的规则，兼容识别并一并移除
    static let legacySudoersPaths = ["/etc/sudoers.d/argus", "/etc/sudoers.d/lidawake"]

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// 弹出系统授权框，以管理员身份执行
    static func runAsAdmin(_ shell: String) -> Bool {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "\"", with: "\\\"")
        NSApp.activate(ignoringOtherApps: true)
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?
            .executeAndReturnError(&err)
        return err == nil
    }

    /// 系统睡眠是否已禁用（pmset SleepDisabled）
    static var isSleepDisabled: Bool {
        for line in run(pmset, ["-g"]).output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "SleepDisabled" { return parts[1] == "1" }
        }
        return false
    }

    static var hasPasswordlessRule: Bool {
        ([sudoersPath] + legacySudoersPaths).contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// 设置 SleepDisabled。interactive=false 时绝不弹密码框（用于定时/低电量等无人值守场景）
    static func setSleepDisabled(_ disable: Bool, interactive: Bool) -> Bool {
        let v = disable ? "1" : "0"
        if hasPasswordlessRule, run("/usr/bin/sudo", ["-n", pmset, "-a", "disablesleep", v]).status == 0 {
            return true
        }
        guard interactive else { return false }
        return runAsAdmin("\(pmset) -a disablesleep \(v)")
    }

    /// 盖子是否合上
    static var isLidClosed: Bool {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard svc != 0 else { return false }
        defer { IOObjectRelease(svc) }
        let v = IORegistryEntryCreateCFProperty(svc, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (v as? Bool) ?? false
    }

    /// 立刻熄灭所有屏幕（无需管理员权限）
    static func displaySleepNow() { run(pmset, ["displaysleepnow"]) }

    /// 立即锁屏（与 ⌃⌘Q 相同）。使用 login.framework 的 SACLockScreenImmediate，不需要任何权限
    static func lockScreen() {
        typealias Fn = @convention(c) () -> Int32
        guard let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let sym = dlsym(h, "SACLockScreenImmediate") else { return }
        _ = unsafeBitCast(sym, to: Fn.self)()
    }

    /// 系统「熄屏后多久需要密码」，如 "立即"、"5 分钟后"、"不锁定"
    static var screenLockDescription: String {
        let out = run("/usr/sbin/sysadminctl", ["-screenLock", "status"]).output
        if out.contains("immediate") { return "熄屏后立即锁屏" }
        if out.contains("is off") { return "熄屏后不锁屏" }
        if let r = out.range(of: #"delay is (\d+) seconds"#, options: .regularExpression),
           let n = Int(out[r].filter(\.isNumber)) {
            return n >= 60 ? "熄屏 \(n / 60) 分钟后锁屏" : "熄屏 \(n) 秒后锁屏"
        }
        return "取决于「系统设置 → 锁定屏幕」"
    }

    private static var onlineDisplays: [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &n) == .success else { return [] }
        return Array(ids.prefix(Int(n)))
    }

    /// 是否有屏幕还亮着
    static var anyDisplayAwake: Bool { onlineDisplays.contains { CGDisplayIsAsleep($0) == 0 } }

    /// 是否接了外接显示器
    static var hasExternalDisplay: Bool { onlineDisplays.contains { CGDisplayIsBuiltin($0) == 0 } }

    struct Battery: Equatable { var percent: Int; var onBattery: Bool; var charging: Bool }

    static var battery: Battery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return Battery(percent: cur * 100 / max,
                           onBattery: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue,
                           charging: (d[kIOPSIsChargingKey] as? Bool) ?? false)
        }
        return nil
    }

    /// 安装免密规则：只放行 pmset -a disablesleep 0/1 两条命令，先 visudo 校验再安装
    static func installRule() -> Bool {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return false }
        let rule = "\(user) ALL=(root) NOPASSWD: \(pmset) -a disablesleep 0, \(pmset) -a disablesleep 1"
        // mktemp 生成随机临时文件，避免以 root 身份写入可预测路径（符号链接攻击）
        let cmd = "T=$(/usr/bin/mktemp /tmp/arguslid.XXXXXX) && printf '%s\\n' '\(rule)' > \"$T\" && "
                + "/usr/sbin/visudo -cf \"$T\" && /usr/sbin/chown root:wheel \"$T\" && /bin/chmod 0440 \"$T\" && "
                + "/bin/mv \"$T\" \(sudoersPath) && /bin/rm -f \(legacySudoersPaths.joined(separator: " ")) || { /bin/rm -f \"$T\"; exit 1; }"
        return runAsAdmin(cmd)
    }

    static func removeRule() -> Bool { runAsAdmin("/bin/rm -f \(sudoersPath) \(legacySudoersPaths.joined(separator: " "))") }
}
