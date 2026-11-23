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

        keepingAwake = System.isSleepDisabled
        hasRule = System.hasPasswordlessRule
        battery = System.battery
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

    // MARK: 系统调用（放到后台队列，避免点击时卡住动画）

    private let sysQueue = DispatchQueue(label: "arguslid.system", qos: .userInitiated)
    private var pendingOps = 0     // 进行中的切换；期间不做「外部被改」的同步，避免误判

    /// 设置 SleepDisabled。有免密：后台执行，不阻塞界面；没有免密且允许交互：主线程弹授权框
    private func applySleep(_ disable: Bool, interactive: Bool, done: @escaping (Bool) -> Void) {
        pendingOps += 1
        let finish: (Bool) -> Void = { [weak self] ok in
            guard let self else { return }
            self.pendingOps -= 1
            if ok { self.keepingAwake = disable }
            done(ok)
        }
        if hasRule || !interactive {
            sysQueue.async {
                let ok = System.setSleepDisabled(disable, interactive: false)
                DispatchQueue.main.async { finish(ok) }
            }
        } else {
            // 先让这次点击的动画跑起来，再弹授权框
            DispatchQueue.main.async { finish(System.setSleepDisabled(disable, interactive: true)) }
        }
    }

    // MARK: 总开关

    func setEnabled(_ on: Bool) {
        notice = nil
        if on {
            enabled = true                       // 先更新界面
            lastLidClosed = System.isLidClosed
            guard wantsKeepAwake else { return }
            guard batteryAllowsKeepAwake() else { durationMinutes = Self.none; return }
            applySleep(true, interactive: true) { [weak self] ok in
                guard let self else { return }
                if ok { self.startTimer() } else { self.enabled = false }   // 取消授权：退回关闭
            }
        } else {
            enabled = false
            clearTimer()
            guard keepingAwake else { return }
            applySleep(false, interactive: true) { [weak self] ok in
                if !ok { self?.enabled = true }
            }
        }
    }

    // MARK: 时长

    /// 选择时长。界面立即切换；需要改系统设置时在后台完成，失败则退回原来的选择
    func selectDuration(_ minutes: Int) {
        notice = nil
        let previous = durationMinutes
        durationMinutes = minutes
        guard enabled else { return }

        if minutes == Self.none {
            clearTimer()
            guard keepingAwake else { return }
            applySleep(false, interactive: true) { [weak self] ok in
                if !ok { self?.durationMinutes = previous }
            }
        } else if keepingAwake {
            startTimer()                         // 已在保持运行：只换时长，不碰系统
        } else {
            guard batteryAllowsKeepAwake() else { durationMinutes = previous; return }
            applySleep(true, interactive: true) { [weak self] ok in
                guard let self else { return }
                if ok { self.startTimer() } else { self.durationMinutes = previous }
            }
        }
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
        now = Date()
        d.set(startDate, forKey: "startDate")
        d.set(endDate, forKey: "endDate")
    }

    private func clearTimer() {
        endDate = nil; startDate = nil
        d.removeObject(forKey: "endDate"); d.removeObject(forKey: "startDate")
    }

    /// 无人值守地结束「保持运行」：只用免密，绝不弹密码框。总开关保持开启，时长回到「睡眠」
    private var stopping = false
    private func stopKeepAwake(_ reason: String) {
        guard !stopping else { return }
        stopping = true
        applySleep(false, interactive: false) { [weak self] ok in
            guard let self else { return }
            self.stopping = false
            guard ok else {
                self.notice = "\(reason)，但未设置免密，无法自动恢复睡眠"
                return
            }
            self.clearTimer()
            self.durationMinutes = Self.none
            self.notice = "\(reason)，已恢复合盖睡眠"
            // 盖子已经合着：恢复睡眠设置不会自己触发睡眠，需要主动睡下去。
            // 接着外接屏时（系统原生的合盖模式）不强制睡眠，避免打断外接屏使用。
            if System.isLidClosed, !System.hasExternalDisplay {
                NSLog("ArgusLid: keep-awake ended with lid closed → sleep now")
                if self.lockOnLid { self.lock(reason: "before sleep") }
                System.sleepNow()
            }
        }
    }

    // MARK: 轮询

    private func onTick() {
        tick += 1
        // 只有显示倒计时时才每秒刷新界面，否则不触发重绘
        if endDate != nil { now = Date() }
        checkTimer()
        if tick % 2 == 0 { checkLid() }
        if tick % 5 == 0 { refresh() }
        if tick % 10 == 0 { checkBattery() }
    }

    /// 读取系统状态（pmset、电池、登录项）在后台完成，结果回到主线程更新
    func refresh() {
        sysQueue.async { [weak self] in
            let awake = System.isSleepDisabled
            let rule = System.hasPasswordlessRule
            let bat = System.battery
            let login = SMAppService.mainApp.status == .enabled
            DispatchQueue.main.async {
                guard let self else { return }
                if self.hasRule != rule { self.hasRule = rule }
                if self.battery != bat { self.battery = bat }
                if self.launchAtLogin != login { self.launchAtLogin = login }
                guard self.pendingOps == 0 else { return }   // 正在切换：以切换结果为准
                if awake != self.keepingAwake { self.keepingAwake = awake }
                // 在外部（终端）被关掉了：同步成「睡眠」
                if self.enabled, !awake, self.wantsKeepAwake, self.tick > 0 {
                    self.durationMinutes = Self.none
                    self.clearTimer()
                }
            }
        }
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
        if System.installRule() { hasRule = true; notice = "免密已设置，以后切换无需密码" }
        refresh()
    }

    func removeRule() { if System.removeRule() { hasRule = false }; refresh() }

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
