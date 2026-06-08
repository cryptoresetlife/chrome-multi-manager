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
