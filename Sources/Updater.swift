// 自动更新：从 GitHub Releases 检查新版本，下载 → 校验 SHA-256 → 原地替换 → 重启
// App 自己用 URLSession 下载的文件不带隔离标记，所以更新后打开不会被 Gatekeeper 拦截。
import AppKit
import CryptoKit

@MainActor
final class Updater: ObservableObject {
    static let repo = "GZhengHao/argus-lid"
    static let assetName = "ArgusLid.zip"

    enum State: Equatable {
        case idle, checking, upToDate, downloading, installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var latestVersion: String?   // 仅当比当前版本新时非 nil
    @Published var autoCheck: Bool { didSet { UserDefaults.standard.set(autoCheck, forKey: "autoUpdateCheck") } }

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private var timer: Timer?

    init() {
        UserDefaults.standard.register(defaults: ["autoUpdateCheck": true])
        autoCheck = UserDefaults.standard.bool(forKey: "autoUpdateCheck")
        // 启动 10 秒后检查一次，之后每 12 小时检查一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.autoCheckIfEnabled() }
        let t = Timer(timeInterval: 12 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autoCheckIfEnabled() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // 测试用：ArgusLid --update-now 启动后立即检查并安装更新
        if CommandLine.arguments.contains("--update-now") {
            Task { await check(userInitiated: true); await installLatest() }
        }
    }

    var isBusy: Bool { state == .checking || state == .downloading || state == .installing }

    private func autoCheckIfEnabled() {
        guard autoCheck, !isBusy else { return }
        Task { await check(userInitiated: false) }
    }

    // MARK: 检查

    func check(userInitiated: Bool) async {
        state = .checking
        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("ArgusLid-Updater", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 20
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { throw UpdateError("无法读取版本信息") }
            let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            if Self.isNewer(v, than: currentVersion) {
                latestVersion = v
                state = .idle
            } else {
                latestVersion = nil
                state = userInitiated ? .upToDate : .idle
            }
        } catch {
            state = userInitiated ? .failed("检查失败：\(error.localizedDescription)") : .idle
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: 安装

    func installLatest() async {
        guard let v = latestVersion else { return }
        let dest = Bundle.main.bundleURL
        let parent = dest.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            state = .failed("没有权限写入 \(parent.path)，请用安装命令更新")
            return
        }

        state = .downloading
        do {
            let base = "https://github.com/\(Self.repo)/releases/download/v\(v)/"
            let (zipURL, _) = try await URLSession.shared.download(from: URL(string: base + Self.assetName)!)
            let (sumData, _) = try await URLSession.shared.data(from: URL(string: base + Self.assetName + ".sha256")!)

            let expected = String(decoding: sumData, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
            let actual = SHA256.hash(data: try Data(contentsOf: zipURL)).map { String(format: "%02x", $0) }.joined()
            guard !expected.isEmpty, expected.lowercased() == actual else { throw UpdateError("校验失败，已取消更新") }

            state = .installing
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("ArgusLid-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let unzip = System.run("/usr/bin/ditto", ["-x", "-k", zipURL.path, work.path])
            let newApp = work.appendingPathComponent("ArgusLid.app")
            guard unzip.status == 0,
                  let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
                  info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
                throw UpdateError("安装包内容不对，已取消更新")
            }

            // 交给一个独立脚本：等本进程退出 → 替换 → 重新打开
            let script = work.appendingPathComponent("swap.sh")
            let sh = """
            #!/bin/bash
            while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
            rm -rf "\(dest.path)"
            /usr/bin/ditto "\(newApp.path)" "\(dest.path)"
            /usr/bin/xattr -dr com.apple.quarantine "\(dest.path)" 2>/dev/null
            /usr/bin/open "\(dest.path)"
            rm -rf "\(work.path)"
            """
            try sh.write(to: script, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path]
            try p.run()

            // 直接退出，不恢复睡眠设置：新版本启动后会读到当前状态继续工作
            NSApp.terminate(nil)
        } catch {
            state = .failed((error as? UpdateError)?.message ?? "更新失败：\(error.localizedDescription)")
        }
    }
}

struct UpdateError: Error {
    let message: String
    init(_ m: String) { message = m }
}
