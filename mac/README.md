# macOS Version

The native macOS version is implemented as a SwiftUI app in:

```text
Package.swift
Sources/ChromeMultiManagerMac
```

## Run From Source

From the repository root:

```bash
./script/build_and_run.sh
```

This builds the SwiftUI macOS app, installs `~/Applications/Chrome 多开管理器.app`, and opens it as a normal foreground Mac app.

## Download Package

[Chrome多开管理器_mac_发布版.zip](https://github.com/cryptoresetlife/chrome-multi-manager/raw/main/Chrome%E5%A4%9A%E5%BC%80%E7%AE%A1%E7%90%86%E5%99%A8_mac_%E5%8F%91%E5%B8%83%E7%89%88.zip)

After extracting on macOS, right-click `Chrome 多开管理器.app` and choose `Open` if Gatekeeper blocks the first launch.

## Requirements

- macOS 13 or later
- Google Chrome
- Swift 6 / Xcode Command Line Tools for building from source
- Full-window mouse/keyboard sync needs both Accessibility and Input Monitoring permissions in System Settings -> Privacy & Security
- Local debug and ad-hoc builds may need permissions again after rebuilds; public releases should be Developer ID signed and notarized

## Notes

- Profile archives are stored under `~/Library/Application Support/ChromeMultiManager/Profiles/profile_编号`.
- The native macOS version supports independent profiles, proxy import, batch launch/close, group navigation/JS, PID-based window arrangement, the window number/IP badge, and mouse/keyboard sync.
- To use sync: start at least two profiles, select one running profile, click `设为主控`, then click `同步鼠标/键盘`. Click `停止同步` to end the relay.
- Full sync listens to events on the master Chrome window and relays them to the other running Chrome windows. If the permissions are missing, the app can fall back to webpage-content sync through Chrome DevTools Protocol, but that fallback cannot sync the address bar, toolbar, or `about:blank`.
- When the manager app exits, it closes Chrome windows started and tracked by this tool.
