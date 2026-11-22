// 界面：macOS 26 Liquid Glass + 终端绿
import SwiftUI

/// 强调色：系统绿（随深浅色自动调整），终端风格
let accent = Color.green
private let mono = Font.system(.callout, design: .monospaced)

struct RootView: View {
    @EnvironmentObject var c: Controller
    @State private var showSettings = false

    var body: some View {
        ZStack {
            if showSettings {
                SettingsView(back: { withAnimation(.snappy) { showSettings = false } })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                MainView(openSettings: { withAnimation(.snappy) { showSettings = true } })
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(width: 320)
        .onAppear { c.refresh() }
    }
}

// MARK: - 主页

struct MainView: View {
    @EnvironmentObject var c: Controller
    var openSettings: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 14) {
                HeaderCard()
                if let n = c.notice { Banner(icon: "info.circle", text: n) { c.notice = nil } }
                if c.needsRuleWarning { RuleBanner() }
                DurationPicker()
                StatusRows()
                Footer(openSettings: openSettings)
            }
            .padding(14)
        }
    }
}

struct HeaderCard: View {
    @EnvironmentObject var c: Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: c.isOn ? "eye.fill" : "eye.slash")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(c.isOn ? accent : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.tint(c.isOn ? accent.opacity(0.25) : nil), in: .circle)
                    .shadow(color: c.isOn ? accent.opacity(0.5) : .clear, radius: 8)

                VStack(alignment: .leading, spacing: 3) {
                    Text("ArgusLid").font(.headline)
                    HStack(spacing: 5) {
                        Circle().fill(c.isOn ? accent : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                        Text(subtitle).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                GeekSwitch(isOn: Binding(get: { c.isOn }, set: { c.setOn($0) }), size: .large)
            }

            if let r = c.remaining {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(r.clock)
                            .font(.system(size: 30, weight: .medium, design: .monospaced))
                            .foregroundStyle(accent)
                            .contentTransition(.numericText(countsDown: true))
                        Text("后恢复").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("+30m") { c.extend(by: 30) }
                        Button("+1h") { c.extend(by: 60) }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .font(.system(.caption, design: .monospaced))
                    ProgressBar(value: c.progress ?? 0)
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .animation(.snappy, value: c.isOn)
        .animation(.snappy, value: c.endDate)
    }

    var subtitle: String {
        if !c.isOn { return "OFF · 合盖正常睡眠" }
        if let e = c.endDate { return "ON · \(e.formatted(date: .omitted, time: .shortened)) 自动关闭" }
        return "ON · 合盖熄屏，系统运行"
    }
}

struct DurationPicker: View {
    @EnvironmentObject var c: Controller
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(c.isOn ? "保持时长 · 点选从现在重新计时" : "保持时长")
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(Controller.presets, id: \.self) { m in
                    Chip(title: shortLabel(m), selected: c.durationMinutes == m) { c.selectDuration(m) }
                }
                Chip(title: "自定义", selected: c.isCustomDuration) { c.selectDuration(c.customMinutes) }
            }
            if c.isCustomDuration {
                HStack {
                    Button { c.adjustCustom(by: -15) } label: { Image(systemName: "minus").frame(width: 16) }
                    Spacer()
                    Text(durationLabel(c.customMinutes)).font(mono.weight(.medium))
                    Spacer()
                    Button { c.adjustCustom(by: 15) } label: { Image(systemName: "plus").frame(width: 16) }
                }
                .buttonStyle(.glass)
            }
        }
    }

    func shortLabel(_ m: Int) -> String {
        m == 0 ? "∞ 不限时" : (m < 60 ? "\(m)m" : "\(m / 60)h")
    }
}

struct StatusRows: View {
    @EnvironmentObject var c: Controller

    var body: some View {
        VStack(spacing: 8) {
            if let b = c.battery {
                InfoRow(icon: batteryIcon(b), text: "电量",
                        detail: "\(b.percent)% · " + (b.onBattery ? "电池" : (b.charging ? "充电中" : "电源")),
                        warn: b.onBattery && c.lowBatteryOff && b.percent <= c.lowBatteryThreshold + 10)
            }
            InfoRow(icon: "shield.lefthalf.filled", text: "电池保护",
                    detail: c.lowBatteryOff ? "≤\(c.lowBatteryThreshold)% 自动关闭" : "未开启", warn: false)
            InfoRow(icon: "laptopcomputer", text: "合盖熄屏",
                    detail: c.keepExternalOn ? "保留外接屏" : "全部熄灭", warn: false)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    func batteryIcon(_ b: System.Battery) -> String {
        if !b.onBattery { return "powerplug" }
        switch b.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

struct Footer: View {
    @EnvironmentObject var c: Controller
    var openSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button { System.displaySleepNow() } label: {
                Label("立即熄屏", systemImage: "display")
            }
            .buttonStyle(.glass)
            .help("马上熄灭所有屏幕，不影响系统运行")
            Spacer()
            Button(action: openSettings) { Image(systemName: "gearshape") }
                .buttonStyle(.glass).help("设置")
            Button { c.quit() } label: { Image(systemName: "power") }
                .buttonStyle(.glass).help("退出（会恢复正常睡眠）")
        }
    }
}

// MARK: - 设置页

struct SettingsView: View {
    @EnvironmentObject var c: Controller
    var back: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button(action: back) { Image(systemName: "chevron.left") }.buttonStyle(.glass)
                    Spacer()
                    Text("设置").font(.headline)
                    Spacer()
                    Color.clear.frame(width: 32, height: 1)
                }

                Group_("合盖") {
                    SwitchRow(title: "接外接显示器时保持亮屏",
                              caption: "默认合盖熄灭所有屏幕；开启后，接着外接屏时只让系统保持运行，不熄屏",
                              isOn: $c.keepExternalOn)
                }

                Group_("电池保护") {
                    SwitchRow(title: "低电量自动关闭", caption: "防止合盖跑任务把电耗光", isOn: $c.lowBatteryOff)
                    if c.lowBatteryOff {
                        HStack(spacing: 6) {
                            ForEach([10, 20, 30, 50], id: \.self) { v in
                                Chip(title: "\(v)%", selected: c.lowBatteryThreshold == v, compact: true) {
                                    c.lowBatteryThreshold = v
                                }
                            }
                        }
                    }
                    Divider().opacity(0.5)
                    SwitchRow(title: "拔掉电源自动关闭", caption: "只想在插电时合盖工作", isOn: $c.offOnUnplug)
                }

                Group_("通用") {
                    SwitchRow(title: "开机自动启动", caption: nil,
                              isOn: Binding(get: { c.launchAtLogin }, set: { c.setLaunchAtLogin($0) }))
                }

                Group_("权限") {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("免密切换")
                                if c.hasRule {
                                    Text("READY").font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(accent)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .overlay(Capsule().strokeBorder(accent.opacity(0.6)))
                                }
                            }
                            Text(c.hasRule ? "sudo 仅放行 pmset disablesleep 0/1"
                                           : "只需输一次密码；定时、低电量才能自动关闭")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if c.hasRule {
                            Button("移除") { c.removeRule() }.buttonStyle(.glass).controlSize(.small)
                        } else {
                            Button("设置") { c.setupRule() }
                                .buttonStyle(.glassProminent).tint(accent).controlSize(.small)
                        }
                    }
                }

                if let n = c.notice { Banner(icon: "info.circle", text: n) { c.notice = nil } }
            }
            .padding(14)
        }
    }
}

// MARK: - 组件

/// 自定义开关：玻璃轨道，开启时亮绿色并发光
struct GeekSwitch: View {
    @Binding var isOn: Bool
    enum Size { case small, large }
    var size: Size = .small

    var body: some View {
        let w: CGFloat = size == .large ? 54 : 40
        let h: CGFloat = size == .large ? 30 : 22
        let knob = h - 6

        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? AnyShapeStyle(accent.gradient) : AnyShapeStyle(Color.primary.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(.white.opacity(isOn ? 0.35 : 0.15), lineWidth: 0.5))
                    .shadow(color: isOn ? accent.opacity(0.55) : .clear, radius: 6)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                    .frame(width: knob, height: knob)
                    .padding(3)
            }
            .frame(width: w, height: h)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isOn)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "开" : "关")
    }
}

struct ProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(accent.gradient)
                    .frame(width: max(4, g.size.width * value))
                    .shadow(color: accent.opacity(0.5), radius: 3)
            }
        }
        .frame(height: 4)
    }
}

struct SectionTitle: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.leading, 4)
    }
}

struct Group_<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ t: String, @ViewBuilder content: () -> Content) { title = t; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
    }
}

struct SwitchRow: View {
    let title: String
    let caption: String?
    @Binding var isOn: Bool
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            GeekSwitch(isOn: $isOn)
        }
    }
}

struct Chip: View {
    let title: String
    let selected: Bool
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(compact ? .caption : .callout, design: .monospaced).weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? accent : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, compact ? 5 : 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(accent.opacity(0.18)).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? accent.opacity(0.7) : .clear, lineWidth: 1)
        )
        .animation(.snappy(duration: 0.15), value: selected)
    }
}

struct InfoRow: View {
    let icon: String, text: String, detail: String, warn: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(warn ? .red : .secondary)
            Text(text).font(.callout)
            Spacer()
            Text(detail).font(.system(.caption, design: .monospaced)).foregroundStyle(warn ? .red : .secondary)
        }
    }
}

struct Banner: View {
    let icon: String, text: String
    var close: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let close {
                Button(action: close) { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.borderless)
            }
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

struct RuleBanner: View {
    @EnvironmentObject var c: Controller
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "key").foregroundStyle(.yellow)
            Text("设置免密后，定时和低电量才能自动关闭").font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("设置") { c.setupRule() }.buttonStyle(.glass).controlSize(.small)
        }
        .padding(10)
        .glassEffect(.regular.tint(.yellow.opacity(0.12)), in: .rect(cornerRadius: 12))
    }
}
