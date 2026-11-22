<p align="center">
  <img src="docs/icon.png" width="128" alt="Argus icon">
</p>

<h1 align="center">Argus</h1>

<p align="center">
  <b>Close the lid. Screen goes dark. Your Mac keeps working.</b><br>
  合上盖子，屏幕熄灭，Mac 继续工作。
</p>

<p align="center">
  <a href="../../releases/latest"><img src="https://img.shields.io/github/v/release/GZhengHao/Argus?label=download" alt="Download"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-black" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-green" alt="Universal">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT">
</p>

<p align="center"><a href="#中文">中文说明</a></p>

---

Argus is a tiny macOS menu bar app that keeps your MacBook **running with the lid closed**, on battery, with **no external display, keyboard or mouse needed**. And unlike most keep-awake tools, it makes sure the **screen actually turns off** when you close the lid.

Downloads, builds, renders, backups, SSH sessions, local LLMs, AI agents and servers keep going while the lid is shut. The display stays dark and cool.

> **Why the name?** In Greek myth, Argus Panoptes was the hundred-eyed giant who never fully slept: he closed only some of his eyes and the rest kept watch. Your lid is closed, but your Mac is still awake.

## Why another keep-awake app?

There are plenty of good "keep awake" apps for macOS: **Amphetamine**, **KeepingYouAwake**, **Caffeine**, **Lungo**, **Theine**, **InsomniaX**, **NoSleep**, and the built-in `caffeinate` command. They fall into two groups:

1. **Tools built on power assertions** (`caffeinate`, KeepingYouAwake, Caffeine, Lungo, Theine…) stop *idle* sleep. But macOS still forces sleep **the moment you close the lid**, unless you're in Apple's clamshell mode (charger + external display + keyboard/mouse).
2. **Tools that do keep the Mac awake with the lid closed** often leave the **built-in display backlight on** behind the closed lid. That wastes battery, adds heat and can cause burn-in.

Argus was built to fix exactly that:

| | Argus |
|---|---|
| Stays awake with the lid closed, on battery, no external display | ✅ |
| Turns **all screens off** the instant the lid closes | ✅ |
| Turns screens off again if something wakes them while the lid is closed | ✅ |
| Timer (30m / 1h / 2h / 4h / custom), extend on the fly | ✅ |
| Battery guard: auto-off below 10/20/30/50% | ✅ |
| Auto-off when the charger is unplugged (optional) | ✅ |
| One-click toggle, no password after one-time setup | ✅ |
| Restores normal sleep when you quit | ✅ |
| Native SwiftUI + Liquid Glass, ~300 KB, no dependencies, open source | ✅ |

If you're searching for an **Amphetamine alternative**, a **closed-lid / clamshell mode without an external monitor**, or a way to **prevent MacBook sleep when the lid is closed while turning the display off**, this is it.

## Install

1. Download **`Argus-x.y.z.dmg`** from [**Releases**](../../releases/latest), open it, and drag **Argus** onto **Applications**.
2. Open Argus from Applications. Because Argus is a free open-source app that isn't notarized by Apple ($99/year developer program), macOS will say *"Apple could not verify 'Argus' is free of malware"*. Click **Done** (**not** Move to Trash), then:
   - Open **System Settings → Privacy & Security**, scroll down to *"Argus" was blocked…*, and click **Open Anyway** → enter your password → **Open Anyway**.
   - Or run this once in Terminal:
     ```bash
     xattr -dr com.apple.quarantine /Applications/Argus.app
     ```
   You only need to do this once. The full source is in this repo, and you can build it yourself (see below).
3. Click the 👁 icon in the menu bar. Open **Settings → Passwordless toggle** and enter your password once.

### Build from source

Only Xcode Command Line Tools are needed:

```bash
git clone https://github.com/GZhengHao/Argus.git
cd Argus
./build.sh            # → build/Argus.app
./build.sh release    # → also dist/Argus-<version>.zip
```

## How it works

| Step | Mechanism |
|---|---|
| Keep the system awake with the lid closed | `pmset -a disablesleep 1` (the only reliable way; power assertions don't survive a lid close) |
| Detect the lid | `AppleClamshellState` on `IOPMrootDomain` (IOKit), polled every 2 s |
| Turn screens off | `pmset displaysleepnow` on lid close; repeated every 10 s if a display wakes while the lid stays shut |
| Battery / charger | `IOPowerSources` |
| No password prompts | Optional sudoers rule in `/etc/sudoers.d/argus` that allows **only** `pmset -a disablesleep 0` and `pmset -a disablesleep 1`, validated with `visudo` before install. You can remove it from Settings at any time. |

Automatic actions (timer end, low battery, unplugged) **never** show a password dialog. If nobody is there to type a password, a blocking dialog would hang. Without the passwordless rule, Argus tells you it couldn't switch itself off instead.

## ⚠️ Be careful

- **Don't put a running, lid-closed MacBook in a bag.** With no airflow it can get hot. Use the battery guard and a timer.
- `disablesleep` is a system-wide setting that persists across reboots. Argus turns it off when you quit, but if the app is force-killed, turn it off with:
  ```bash
  sudo pmset -a disablesleep 0
  ```

## Requirements

macOS 26 (Tahoe) or later, Apple Silicon or Intel.

## License

MIT

---

<a id="中文"></a>

## 中文

**Argus** 是一个 macOS 菜单栏小工具：**合上 MacBook 盖子后，屏幕熄灭，系统继续运行**。用电池也行，不需要外接显示器、键盘或鼠标。

下载、编译、渲染、备份、SSH、本地大模型、AI Agent、服务器……合盖后照常运行，屏幕全黑，不费电也不发热。

### 为什么要做它

市面上的防休眠软件已经不少：**Amphetamine**、**KeepingYouAwake**、**Caffeine**、**Lungo**、**Theine**、**InsomniaX**、**NoSleep**，还有系统自带的 `caffeinate` 命令。但它们有两个常见问题：

1. **基于电源断言的工具**（caffeinate、KeepingYouAwake、Caffeine、Lungo、Theine 等）只能阻止"闲置睡眠"。**一合盖系统照样会睡**，除非同时接着电源、外接显示器和键盘鼠标，进入苹果官方的"合盖模式"。
2. **能让合盖不休眠的工具**，合盖后**内屏背光往往还亮着**，既费电又发热，还可能烧屏。

Argus 就是为了解决这个问题而做的：**合盖瞬间主动熄灭所有屏幕**。盖子合着期间屏幕如果被唤醒，它会再次熄灭。

### 功能

- 一个开关，一键开启或关闭
- 定时：30 分钟、1 小时、2 小时、4 小时、自定义，运行中可以随时延长
- 电池保护：电量低于 10/20/30/50% 时自动关闭
- 拔掉电源时自动关闭（可选）
- 开机自动启动
- 设置一次免密后，切换不用再输密码
- 退出时自动恢复正常睡眠
- 原生 SwiftUI + Liquid Glass 界面，约 300 KB，无任何依赖，开源

### 安装

1. 从 [**Releases**](../../releases/latest) 下载 **`Argus-x.y.z.dmg`**，双击打开，把 **Argus** 拖到 **应用程序**
2. 从「应用程序」里打开 Argus。因为 Argus 是免费开源软件，没有付费参加苹果的开发者计划（99 美元/年）做公证，系统会提示 **「Apple 无法验证"Argus"是否包含可能危害 Mac 安全或泄漏隐私的恶意软件」**。这时点 **完成**，**不要**点「移到废纸篓」，然后二选一：
   - 打开 **系统设置 → 隐私与安全性**，往下滚到「已阻止"Argus"…」，点 **仍要打开**，输入密码，再点 **仍要打开**
   - 或者在终端运行一次：
     ```bash
     xattr -dr com.apple.quarantine /Applications/Argus.app
     ```
   这一步只需要做一次。全部源码都在这个仓库里，你也可以自己编译。
3. 点击菜单栏的 👁 图标，进入「设置 → 免密切换」，输一次密码

### 注意

- **不要把合着盖、还在运行的 MacBook 放进包里**，没有散热会发烫。建议开启电池保护和定时。
- 如果 App 被强制结束，可以手动恢复正常睡眠：`sudo pmset -a disablesleep 0`

### 名字由来

阿耳戈斯（Argus Panoptes）是希腊神话中的百眼巨人。他睡觉时只合上一部分眼睛，其余的眼睛始终醒着守望。合上盖子，Mac 依然醒着。

---

<sub>Keywords: keep mac awake lid closed, prevent sleep when lid closed, macbook closed lid mode without external display, clamshell mode battery, amphetamine alternative, caffeinate lid closed, keepingyouawake alternative, disable sleep macOS, screen off but keep running, 合盖不休眠, 合盖不睡眠, Mac 防休眠, 合盖屏幕熄灭, Amphetamine 替代</sub>
