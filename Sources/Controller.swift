// 状态与逻辑
//
// 两层模型：
//   1. 总开关 enabled：ArgusLid 是否接管合盖行为（熄屏、锁屏、外接屏处理）
//   2. 保持运行时长 durationMinutes：合盖后系统是否保持运行
//        none(-1) = 不保持，合盖照常睡眠；0 = 不限时；>0 = 定时（分钟）
// 只有 enabled 且时长不是「睡眠」时，才会 pmset disablesleep 1。
import AppKit
import ServiceManagement

final class Controller: ObservableObject {
    static let none = -1
    static let presets = [none, 0, 30, 60, 120, 240, 480]

    private let d = UserDefaults.standard

    // 运行状态
    @Published private(set) var enabled: Bool { didSet { d.set(enabled, forKey: "enabled") } }
    @Published private(set) var keepingAwake = false        // 系统实际的 SleepDisabled
    @Published private(set) var endDate: Date?
    @Published private(set) var startDate: Date?
    @Published private(set) var now = Date()
    @Published private(set) var battery: System.Battery?
    @Published private(set) var hasRule = false
    @Published var notice: String?

    // 时长
    @Published private(set) var durationMinutes: Int { didSet { d.set(durationMinutes, forKey: "duration2") } }
    @Published var customMinutes: Int { didSet { d.set(customMinutes, forKey: "customMinutes") } }

    // 设置
    @Published var keepExternalOn: Bool { didSet { d.set(keepExternalOn, forKey: "keepExternalOn") } }
    @Published var lockOnLid: Bool { didSet { d.set(lockOnLid, forKey: "lockOnLid") } }
    @Published private(set) var systemLockDescription = ""
    @Published var lowBatteryOff: Bool { didSet { d.set(lowBatteryOff, forKey: "lowBatteryOff") } }
    @Published var lowBatteryThreshold: Int { didSet { d.set(lowBatteryThreshold, forKey: "threshold") } }
    @Published var offOnUnplug: Bool { didSet { d.set(offOnUnplug, forKey: "offOnUnplug") } }
    @Published private(set) var launchAtLogin = false

    private var timer: Timer?
    private var tick = 0
    private var lastLidClosed = false
    private var lastOnBattery: Bool?
    private var lastScreenOff = Date.distantPast
    private var lastLock = Date.distantPast
    private let power = PowerEvents()

    init() {
        d.register(defaults: ["enabled": false, "duration2": 0, "customMinutes": 90,
                              "keepExternalOn": false, "lockOnLid": true,
                              "lowBatteryOff": true, "threshold": 20, "offOnUnplug": false])
        enabled = d.bool(forKey: "enabled")
        // 旧版本只有「不限时 / 定时」，沿用其选择
        durationMinutes = d.object(forKey: "duration2") as? Int ?? d.object(forKey: "duration") as? Int ?? 0
        customMinutes = d.integer(forKey: "customMinutes")
        keepExternalOn = d.bool(forKey: "keepExternalOn")
        lockOnLid = d.bool(forKey: "lockOnLid")
        lowBatteryOff = d.bool(forKey: "lowBatteryOff")
        lowBatteryThreshold = d.integer(forKey: "threshold")
        offOnUnplug = d.bool(forKey: "offOnUnplug")
        endDate = d.object(forKey: "endDate") as? Date
        startDate = d.object(forKey: "startDate") as? Date

        refresh()
        // 从旧版本升级、或在终端里开过：系统已在保持运行，视为已开启
        if keepingAwake && !enabled { enabled = true }
        lastLidClosed = System.isLidClosed
        lastOnBattery = battery?.onBattery
        checkTimer()   // 重启 App 时若已超时则立即结束

        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.onTick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // 事件驱动：合盖瞬间处理；系统即将睡眠时先锁屏（保证「睡眠」模式下合盖也一定锁上）
        power.onLidChange = { [weak self] closed in self?.handleLid(closed: closed) }
        power.onWillSleep = { [weak self] in
            guard let self, self.enabled, self.lockOnLid, System.isLidClosed else { return }
            self.lock(reason: "system will sleep")
        }
    }

    // MARK: 派生状态

    var wantsKeepAwake: Bool { durationMinutes != Self.none }
    var isCustomDuration: Bool { !Self.presets.contains(durationMinutes) }

    var remaining: TimeInterval? {
        guard enabled, keepingAwake, let e = endDate else { return nil }
        return max(0, e.timeIntervalSince(now))
    }

    /// 倒计时进度 0...1（已用比例）
    var progress: Double? {
        guard let r = remaining, let s = startDate, let e = endDate else { return nil }
        let total = e.timeIntervalSince(s)
        return total > 0 ? 1 - r / total : nil
    }

    /// 定时 / 电池保护属于无人值守操作，需要免密才能自动结束
    var needsRuleWarning: Bool {
        enabled && !hasRule && wantsKeepAwake && (durationMinutes > 0 || lowBatteryOff || offOnUnplug)
    }

    // MARK: 总开关

    func setEnabled(_ on: Bool) {
        notice = nil
        if on {
            if wantsKeepAwake {
                if batteryAllowsKeepAwake() {
                    guard System.setSleepDisabled(true, interactive: true) else { return }
                    startTimer()
                } else {
                    // 电量太低：照常接管合盖（熄屏/锁屏），但不保持运行
                    durationMinutes = Self.none
                }
            }
            enabled = true
            lastLidClosed = System.isLidClosed
        } else {
            if keepingAwake { guard System.setSleepDisabled(false, interactive: true) else { return } }
            clearTimer()
            enabled = false
        }
        refresh()
    }

    // MARK: 时长

    /// 选择时长。已开启时立即生效（从现在开始重新计时）；未开启时只记下来
    func selectDuration(_ minutes: Int) {
        notice = nil
        guard enabled else { durationMinutes = minutes; return }
        if minutes == Self.none {
            if keepingAwake { guard System.setSleepDisabled(false, interactive: true) else { return } }
            durationMinutes = minutes
            clearTimer()
        } else {
            if !keepingAwake {
                guard batteryAllowsKeepAwake() else { return }
                guard System.setSleepDisabled(true, interactive: true) else { return }
            }
            durationMinutes = minutes
            startTimer()
        }
        refresh()
    }

    func adjustCustom(by delta: Int) {
        customMinutes = min(24 * 60, max(15, customMinutes + delta))
        selectDuration(customMinutes)
    }

    /// 运行中延长
    func extend(by minutes: Int) {
        guard let e = endDate, remaining != nil else { return }
        setEnd(e.addingTimeInterval(TimeInterval(minutes * 60)), keepStart: true)
    }

    private func batteryAllowsKeepAwake() -> Bool {
        if lowBatteryOff, let b = battery, b.onBattery, b.percent <= lowBatteryThreshold {
            notice = "电量 \(b.percent)%，低于保护阈值 \(lowBatteryThreshold)%，暂不保持运行，请先接电源"
            return false
        }
        return true
    }

    private func startTimer() {
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

    /// 无人值守地结束「保持运行」：只用免密，绝不弹密码框。总开关保持开启，时长回到「睡眠」
    private func stopKeepAwake(_ reason: String) {
        if System.setSleepDisabled(false, interactive: false) {
            clearTimer()
            durationMinutes = Self.none
            notice = "\(reason)，已恢复合盖睡眠"
            // 盖子已经合着：恢复睡眠设置不会自己触发睡眠，需要主动睡下去。
            // 接着外接屏时（系统原生的合盖模式）不强制睡眠，避免打断外接屏使用。
            if System.isLidClosed, !System.hasExternalDisplay {
                NSLog("ArgusLid: keep-awake ended with lid closed → sleep now")
                if lockOnLid { lock(reason: "before sleep") }
                System.sleepNow()
            }
        } else {
            notice = "\(reason)，但未设置免密，无法自动恢复睡眠"
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
        let awake = System.isSleepDisabled
        if awake != keepingAwake { keepingAwake = awake }
        // 在外部（终端）被关掉了：同步成「睡眠」
        if enabled, !awake, wantsKeepAwake, tick > 0 {
            durationMinutes = Self.none
            clearTimer()
        }
        hasRule = System.hasPasswordlessRule
        battery = System.battery
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func checkTimer() {
        guard keepingAwake, let e = endDate, Date() >= e else { return }
        stopKeepAwake("保持时间已到")
    }

    /// 合盖处理（总开关开启即生效，与是否保持运行无关）。
    /// 由合盖事件立即触发；每 2 秒的轮询作兜底，并在合盖期间屏幕被唤醒时每 10 秒再熄一次。
    private func checkLid() { handleLid(closed: System.isLidClosed) }

    private func handleLid(closed: Bool) {
        let justClosed = closed && !lastLidClosed
        lastLidClosed = closed
        guard enabled, closed else { return }
        // 锁屏与熄屏相互独立：「合盖锁屏」任何情况下都生效，包括接着外接屏
        if justClosed, lockOnLid { lock(reason: "lid closed") }
        if keepExternalOn, System.hasExternalDisplay { return }
        if justClosed || (System.anyDisplayAwake && Date().timeIntervalSince(lastScreenOff) >= 10) {
            NSLog("ArgusLid: lid closed → display sleep (\(justClosed ? "lid just closed" : "display woke"))")
            System.displaySleepNow()
            lastScreenOff = Date()
        }
    }

    /// 锁屏（3 秒内不重复锁）
    private func lock(reason: String) {
        guard Date().timeIntervalSince(lastLock) > 3 else { return }
        NSLog("ArgusLid: lock screen (\(reason))")
        System.lockScreen()
        lastLock = Date()
    }

    private func checkBattery() {
        battery = System.battery
        guard let b = battery else { return }
        defer { lastOnBattery = b.onBattery }
        guard keepingAwake, enabled else { return }
        if offOnUnplug, b.onBattery, lastOnBattery == false { stopKeepAwake("已拔掉电源"); return }
        if lowBatteryOff, b.onBattery, b.percent <= lowBatteryThreshold { stopKeepAwake("电量降到 \(b.percent)%") }
    }

    // MARK: 设置

    func refreshSystemLock() { systemLockDescription = System.screenLockDescription }

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

    /// 退出：恢复正常睡眠，并关闭总开关
    func quit() {
        if keepingAwake { _ = System.setSleepDisabled(false, interactive: true) }
        enabled = false
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
    if minutes == Controller.none { return "睡眠" }
    if minutes == 0 { return "一直运行" }
    if minutes < 60 { return "\(minutes) 分钟" }
    return minutes % 60 == 0 ? "\(minutes / 60) 小时" : String(format: "%.1f 小时", Double(minutes) / 60)
}
