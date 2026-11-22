// ArgusLid — 合上盖子，Mac 继续工作
// 名字取自希腊神话中的百眼巨人阿耳戈斯（Argus Panoptes）：
// 他睡觉时只合上一部分眼睛，其余的眼睛始终醒着守望。
import SwiftUI

@main
struct ArgusLidApp: App {
    @StateObject private var c = Controller()

    var body: some Scene {
        MenuBarExtra {
            RootView().environmentObject(c)
        } label: {
            if c.isOn {
                Image(systemName: "eye.fill")
                if let r = c.remaining { Text(shortRemaining(r)) }
            } else {
                Image(systemName: "eye.slash")
            }
        }
        .menuBarExtraStyle(.window)
    }

    private func shortRemaining(_ r: TimeInterval) -> String {
        let m = Int((r / 60).rounded(.up))
        return m >= 60 ? "\(m / 60)h\(m % 60 > 0 ? "\(m % 60)m" : "")" : "\(m)m"
    }
}
