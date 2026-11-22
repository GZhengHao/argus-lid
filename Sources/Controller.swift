// 状态与逻辑
import AppKit
import ServiceManagement

final class Controller: ObservableObject {
    static let presets = [0, 30, 60, 120, 240]   // 分钟，0 = 不限时

    private let d = UserDefaults.standard

    // 运行状态
    @Published private(set) var isOn = false
    @Published private(set) var endDate: Date?
    @Published private(set) var startDate: Date?
    @Published private(set) var now = Date()
    @Published private(set) var battery: System.Battery?
    @Published private(set) var hasRule = false
    @Published var notice: String?

    // 定时选择
    @Published var durationMinutes: Int { didSet { d.set(durationMinutes, forKey: "duration") } }
    @Published var customMinutes: Int { didSet { d.set(customMinutes, forKey: "customMinutes") } }

    // 设置
    @Published var keepExternalOn: Bool { didSet { d.set(keepExternalOn, forKey: "keepExternalOn") } }
    @Published var lowBatteryOff: Bool { didSet { d.set(lowBatteryOff, forKey: "lowBatteryOff") } }
    @Published var lowBatteryThreshold: Int { didSet { d.set(lowBatteryThreshold, forKey: "threshold") } }
    @Published var offOnUnplug: Bool { didSet { d.set(offOnUnplug, forKey: "offOnUnplug") } }
    @Published private(set) var launchAtLogin = false

    private var timer: Timer?
    private var tick = 0
    private var lastLidClosed = false
    private var lastOnBattery: Bool?
    private var lastScreenOff = Date.distantPast

    init() {
        d.register(defaults: ["duration": 0, "customMinutes": 90, "keepExternalOn": false,
                              "lowBatteryOff": true, "threshold": 20, "offOnUnplug": false])
        durationMinutes = d.integer(forKey: "duration")
        customMinutes = d.integer(forKey: "customMinutes")
        keepExternalOn = d.bool(forKey: "keepExternalOn")
        lowBatteryOff = d.bool(forKey: "lowBatteryOff")
        lowBatteryThreshold = d.integer(forKey: "threshold")
        offOnUnplug = d.bool(forKey: "offOnUnplug")
        endDate = d.object(forKey: "endDate") as? Date
        startDate = d.object(forKey: "startDate") as? Date

        refresh()
        lastLidClosed = System.isLidClosed
        lastOnBattery = battery?.onBattery
        checkTimer()   // App 重启时，若已超时则立即关闭

        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.onTick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: 派生状态

    var isCustomDuration: Bool { !Self.presets.contains(durationMinutes) }

    var remaining: TimeInterval? {
        guard isOn, let e = endDate else { return nil }
        return max(0, e.timeIntervalSince(now))
    }

    /// 倒计时进度 0...1（已用比例）
    var progress: Double? {
        guard let r = remaining, let s = startDate, let e = endDate else { return nil }
        let total = e.timeIntervalSince(s)
        return total > 0 ? 1 - r / total : nil
    }

    /// 是否需要免密才能完整工作（定时 / 电池保护属于无人值守操作）
    var needsRuleWarning: Bool { !hasRule && (durationMinutes > 0 || lowBatteryOff || offOnUnplug) }

    // MARK: 开关

    func setOn(_ on: Bool) {
        notice = nil
        if on {
            if lowBatteryOff, let b = battery, b.onBattery, b.percent <= lowBatteryThreshold {
                notice = "电量 \(b.percent)%，低于保护阈值 \(lowBatteryThreshold)%，请先接电源"
                return
            }
            guard System.setSleepDisabled(true, interactive: true) else { return }
            startTimerIfNeeded()
        } else {
            guard System.setSleepDisabled(false, interactive: true) else { return }
            clearTimer()
        }
        refresh()
    }

    /// 选择时长；运行中则从现在开始重新计时
    func selectDuration(_ minutes: Int) {
        durationMinutes = minutes
        if isOn { startTimerIfNeeded() }
    }

    func adjustCustom(by delta: Int) {
        customMinutes = min(24 * 60, max(15, customMinutes + delta))
        selectDuration(customMinutes)
    }

    /// 运行中延长 / 缩短
    func extend(by minutes: Int) {
        guard isOn, let e = endDate else { return }
        setEnd(e.addingTimeInterval(TimeInterval(minutes * 60)), keepStart: true)
    }

    private func startTimerIfNeeded() {
        if durationMinutes > 0 {
            setEnd(Date().addingTimeInterval(TimeInterval(durationMinutes * 60)), keepStart: false)
        } else {
            clearTimer()
        }
    }

    private func setEnd(_ end: Date, keepStart: Bool) {
        if !keepStart || startDate == nil { startDate = Date() }
        endDate = end
        d.set(startDate, forKey: "startDate")
        d.set(endDate, forKey: "endDate")
    }

    private func clearTimer() {
        endDate = nil; startDate = nil
        d.removeObject(forKey: "endDate"); d.removeObject(forKey: "startDate")
    }

    /// 无人值守的自动关闭：只用免密，绝不弹密码框
    private func autoOff(_ reason: String) {
        if System.setSleepDisabled(false, interactive: false) {
            clearTimer()
            notice = "已自动关闭：\(reason)"
        } else {
            notice = "\(reason)，但未设置免密，无法自动关闭"
        }
        refresh()
    }

    // MARK: 轮询

    private func onTick() {
        tick += 1
        now = Date()
        checkTimer()
        if tick % 2 == 0 { checkLid() }
        if tick % 5 == 0 { refresh() }
        if tick % 10 == 0 { checkBattery() }
    }

    func refresh() {
        let on = System.isSleepDisabled
        if on != isOn { isOn = on }
        if !on, endDate != nil { clearTimer() }   // 被外部（终端）关掉了
        hasRule = System.hasPasswordlessRule
        battery = System.battery
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func checkTimer() {
        guard isOn, let e = endDate, Date() >= e else { return }
        autoOff("定时结束")
    }

    /// 合盖时熄屏：禁用睡眠后系统不会自己关内屏，所以由 App 负责。
    /// 合盖瞬间立即熄屏；盖子保持合上期间，若屏幕被唤醒（通知、外设等）每 10 秒再熄一次。
    private func checkLid() {
        let closed = System.isLidClosed
        defer { lastLidClosed = closed }
        guard isOn, closed else { return }
        if keepExternalOn, System.hasExternalDisplay { return }
        let justClosed = !lastLidClosed
        if justClosed || (System.anyDisplayAwake && Date().timeIntervalSince(lastScreenOff) >= 10) {
            NSLog("ArgusLid: lid closed → display sleep (\(justClosed ? "lid just closed" : "display woke"))")
            System.displaySleepNow()
            lastScreenOff = Date()
        }
    }

    private func checkBattery() {
        battery = System.battery
        guard let b = battery else { return }
        defer { lastOnBattery = b.onBattery }
        guard isOn else { return }
        if offOnUnplug, b.onBattery, lastOnBattery == false { autoOff("已拔掉电源"); return }
        if lowBatteryOff, b.onBattery, b.percent <= lowBatteryThreshold { autoOff("电量降到 \(b.percent)%") }
    }

    // MARK: 设置

    func setupRule() {
        if System.installRule() { notice = "免密已设置，以后切换无需密码" }
        refresh()
    }

    func removeRule() { _ = System.removeRule(); refresh() }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            notice = "开机启动设置失败：\(error.localizedDescription)"
        }
        refresh()
    }

    func quit() {
        if isOn { _ = System.setSleepDisabled(false, interactive: true) }
        NSApp.terminate(nil)
    }
}

extension TimeInterval {
    var clock: String {
        let s = Int(self.rounded(.up))
        let h = s / 3600, m = s % 3600 / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

func durationLabel(_ minutes: Int) -> String {
    if minutes == 0 { return "不限时" }
    if minutes < 60 { return "\(minutes) 分钟" }
    return minutes % 60 == 0 ? "\(minutes / 60) 小时" : String(format: "%.1f 小时", Double(minutes) / 60)
}
