// 系统电源事件：合盖/开盖、即将睡眠
// 事件驱动（不靠轮询），合盖瞬间就能响应；即将睡眠时系统会等我们处理完（先锁屏）再睡。
import Foundation
import IOKit
import IOKit.pwr_mgt

final class PowerEvents {
    var onLidChange: ((_ closed: Bool) -> Void)?
    var onWillSleep: (() -> Void)?

    // IOKit 宏在 Swift 中不可用，直接用数值
    private static let msgClamshellStateChange: natural_t = 0xE003_4100   // kIOPMMessageClamshellStateChange
    private static let msgCanSystemSleep: natural_t = 0xE000_0270         // kIOMessageCanSystemSleep
    private static let msgSystemWillSleep: natural_t = 0xE000_0280        // kIOMessageSystemWillSleep

    private var rootPort: io_connect_t = 0
    private var sleepPort: IONotificationPortRef?
    private var sleepNotifier: io_object_t = 0
    private var lidPort: IONotificationPortRef?
    private var lidNotifier: io_object_t = 0

    init() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // 1. 系统睡眠通知
        rootPort = IORegisterForSystemPower(refcon, &sleepPort, { refcon, _, type, arg in
            guard let refcon else { return }
            Unmanaged<PowerEvents>.fromOpaque(refcon).takeUnretainedValue().handleSystem(type, arg)
        }, &sleepNotifier)
        if let p = sleepPort { IONotificationPortSetDispatchQueue(p, .main) }

        // 2. 合盖状态变化通知
        lidPort = IONotificationPortCreate(kIOMainPortDefault)
        if let p = lidPort { IONotificationPortSetDispatchQueue(p, .main) }
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        if root != 0 {
            IOServiceAddInterestNotification(lidPort, root, kIOGeneralInterest, { refcon, _, type, arg in
                guard let refcon, type == PowerEvents.msgClamshellStateChange else { return }
                let closed = (Int(bitPattern: arg) & 1) != 0      // kClamshellStateBit
                Unmanaged<PowerEvents>.fromOpaque(refcon).takeUnretainedValue().onLidChange?(closed)
            }, refcon, &lidNotifier)
            IOObjectRelease(root)
        }
    }

    private func handleSystem(_ type: natural_t, _ arg: UnsafeMutableRawPointer?) {
        switch type {
        case Self.msgCanSystemSleep:
            IOAllowPowerChange(rootPort, Int(bitPattern: arg))
        case Self.msgSystemWillSleep:
            onWillSleep?()
            IOAllowPowerChange(rootPort, Int(bitPattern: arg))
        default:
            break
        }
    }
}
