# Chrome Multi Manager

Chrome Multi Manager is a cross-platform Chrome profile launcher and controller. The Windows version is implemented in PowerShell/WPF, and the native macOS version is implemented in SwiftUI.

## Features

- Create and edit Chrome profile configurations
- Launch selected profiles or all profiles
- Arrange Chrome windows into a grid
- Import proxy lists
- Group-control navigation and JavaScript execution through Chrome DevTools Protocol
- Synchronized mouse and keyboard control across Chrome windows with automatic current-window master detection
- In-page badge showing each Chrome window number and current public exit IP
- Optional low-memory launch mode for high-volume Chrome profile sessions
- Basic per-profile fingerprint configuration for user agent, language, timezone, window size, platform, and WebRTC leak protection
- Automatic cleanup of managed Chrome windows when the manager app exits

## Download / Run

Windows release package:

[Chrome多开管理器_v1.0_发布版.zip](https://github.com/cryptoresetlife/chrome-multi-manager/raw/main/Chrome%E5%A4%9A%E5%BC%80%E7%AE%A1%E7%90%86%E5%99%A8_v1.0_%E5%8F%91%E5%B8%83%E7%89%88.zip)

Direct executable:

[Chrome多开管理器.exe](https://github.com/cryptoresetlife/chrome-multi-manager/raw/main/Chrome%E5%A4%9A%E5%BC%80%E7%AE%A1%E7%90%86%E5%99%A8.exe)

Native macOS package:

[Chrome多开管理器_mac_发布版.zip](https://github.com/cryptoresetlife/chrome-multi-manager/raw/main/Chrome%E5%A4%9A%E5%BC%80%E7%AE%A1%E7%90%86%E5%99%A8_mac_%E5%8F%91%E5%B8%83%E7%89%88.zip)

The current public macOS package is an ad-hoc signed test package unless the repository is configured with Apple Developer ID signing secrets. macOS Gatekeeper may block ad-hoc packages with "Apple cannot verify this app". For a customer-facing release, use a Developer ID Application certificate and notarization as described below.

## macOS 用户使用说明

普通用户推荐按下面流程使用：

1. 从本仓库下载 `Chrome多开管理器_mac_发布版.zip`。
2. 解压下载包。
3. 把 `Chrome 多开管理器.app` 拖到 macOS 的 `应用程序` 文件夹。
4. 打开 `Chrome 多开管理器.app`。
5. 新建或导入 Chrome 配置，然后点击 `全部启动` 或 `启动选中`。
6. 点击 `排列窗口`，把所有受管理的 Chrome 窗口按屏幕大小排好。
7. 在要操作的窗口上点击 `设为主控`，再点击 `同步鼠标/键盘`。

macOS 的完整鼠标/键盘同步需要用户首次授权：

- `辅助功能`: 用来控制其他 Chrome 窗口。
- `输入监控`: 用来在同步开启时读取键盘输入。

软件弹出授权提示时，打开 macOS `系统设置`，在 `隐私与安全性 > 辅助功能` 和 `隐私与安全性 > 输入监控` 里都打开 `Chrome 多开管理器`。授权完成后，退出并重新打开软件一次。macOS 不允许任何软件或安装包静默打开这些权限，所以每台用户电脑都需要手动确认一次。

如果软件已经使用 Apple Developer ID 证书签名并通过 Apple 公证，用户下载后可以正常打开；但第一次使用完整鼠标/键盘同步时，仍然需要授权 `辅助功能` 和 `输入监控`。

如果下载后提示 `Apple 无法验证此 App`，说明当前包还是 ad-hoc 签名的测试包，不是最终面向客户发布的正式包。仅限可信内部测试时，可以在 `系统设置 > 隐私与安全性` 里点击 `仍要打开`，或者执行：

```bash
xattr -dr com.apple.quarantine "/Applications/Chrome 多开管理器.app"
```

正式对外发布时，不建议让客户执行上面的命令；应配置 Apple Developer ID 签名和公证，让用户下载后直接正常打开。

联网状态取决于每个配置里的代理。如果 Chrome 窗口显示无法联网，请检查代理是否可用、用户网络是否能连接该代理，以及代理格式是否正确，例如 `host:port` 或 `user:password@host:port`。

主程序正常退出时，会关闭由本软件启动并跟踪的 Chrome 窗口。不是由本软件启动的普通 Chrome 窗口不会被关闭。

Run the native macOS app from source:

```bash
./script/build_and_run.sh
```

If the Windows executable is blocked or does not start, use:

```text
启动(备用).bat
```

## Requirements

- Windows: Google Chrome installed in the default installation path, PowerShell 5.1 or later
- macOS native app: macOS 13 or later, Google Chrome, Swift 6 / Xcode Command Line Tools
- macOS full-window mouse/keyboard sync: Accessibility and Input Monitoring permissions

## Privacy

This repository does not include accounts, proxies, cookies, browser profile data, or user configuration.

Windows user configuration is stored locally under:

```text
%APPDATA%\ChromeManager
```

macOS user configuration is stored locally under:

```text
~/Library/Application Support/ChromeMultiManager
```

Proxy information must be entered or imported by each user.

## Source

The Windows source file is:

```text
ChromeManager.ps1
```

The Windows executable is built from that PowerShell script with ps2exe.

The native macOS SwiftUI source is:

```text
Package.swift
Sources/ChromeMultiManagerMac
```

Build and run the native macOS app from the repository root:

```bash
./script/build_and_run.sh
```

Create a macOS package:

```bash
./script/package_macos_release.sh
```

Local debug and ad-hoc packages may make macOS ask for Accessibility/Input Monitoring again after rebuilds. For a user-facing macOS release, sign with a Developer ID Application certificate and notarize the app:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="your-notarytool-keychain-profile" \
./script/package_macos_release.sh
```

Apple requires the user to approve Input Monitoring and Accessibility. The app can open the right Settings panes and explain which app to add, but it cannot silently grant those permissions. Once the Developer ID signed build is approved by the user, normal updates keep the same signing identity and should not require re-adding the app.

## macOS Release Signing

To publish a macOS package that opens normally after download, the app must be signed with an Apple Developer ID Application certificate and notarized by Apple. Ad-hoc signing is only suitable for local testing.

Configure these GitHub repository secrets before running the `Build macOS Package` workflow:

```text
MACOS_CERTIFICATE_P12_BASE64
MACOS_CERTIFICATE_PASSWORD
APPLE_ID
APPLE_TEAM_ID
APPLE_APP_SPECIFIC_PASSWORD
```

`MACOS_CERTIFICATE_P12_BASE64` is the base64 text of an exported `Developer ID Application` `.p12` certificate. On macOS:

```bash
base64 -i DeveloperIDApplication.p12 | pbcopy
```

`APPLE_APP_SPECIFIC_PASSWORD` is an app-specific password from the Apple ID account used for notarization. After these secrets are set, re-run the workflow. The generated `Chrome多开管理器_mac_发布版.zip` should pass:

```bash
spctl -a -vv --type execute "Chrome 多开管理器.app"
```

Windows low-memory mode is available from the left sidebar. It is saved locally and only affects newly started Chrome windows. It disables Chrome extensions and several background services, limits renderer processes, and reduces media/disk cache sizes.

Basic fingerprint settings are available in each profile edit dialog. They are saved per profile and are applied through Chrome launch flags plus Chrome DevTools Protocol for future page loads.

Mouse and keyboard sync automatically treats the currently operated managed Chrome window as the master while sync is enabled.

When the manager app exits normally, it closes Chrome windows started and tracked by this tool. It does not close ordinary Chrome windows that were not launched as managed profiles.

The native macOS app supports independent Chrome profiles, proxy import, batch launch/close, group navigation/JS, PID-based window arrangement, the window number/IP badge, and mouse/keyboard synchronization. Full-window synchronization uses macOS Event Tap permissions; without those permissions, the app can fall back to webpage-content synchronization through Chrome DevTools Protocol.

## License

MIT License. See [LICENSE](LICENSE).
