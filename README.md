# Chrome Multi Manager

Chrome Multi Manager is a Windows PowerShell/WPF tool for launching and managing multiple independent Chrome profiles.

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

If the executable is blocked or does not start, use:

```text
启动(备用).bat
```

## Requirements

- Windows
- Google Chrome installed in the default installation path
- PowerShell 5.1 or later

## Privacy

This repository does not include accounts, proxies, cookies, browser profile data, or user configuration.

User configuration is stored locally under:

```text
%APPDATA%\ChromeManager
```

Proxy information must be entered or imported by each user.

## Source

The main source file is:

```text
ChromeManager.ps1
```

The executable is built from that PowerShell script with ps2exe.

Windows low-memory mode is available from the left sidebar. It is saved locally and only affects newly started Chrome windows. It disables Chrome extensions and several background services, limits renderer processes, and reduces media/disk cache sizes.

Basic fingerprint settings are available in each profile edit dialog. They are saved per profile and are applied through Chrome launch flags plus Chrome DevTools Protocol for future page loads.

Mouse and keyboard sync automatically treats the currently operated managed Chrome window as the master while sync is enabled.

When the manager app exits normally, it closes Chrome windows started and tracked by this tool. It does not close ordinary Chrome windows that were not launched as managed profiles.

## License

MIT License. See [LICENSE](LICENSE).
