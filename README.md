# Chrome Multi Manager

Chrome Multi Manager is a Windows PowerShell/WPF tool for launching and managing multiple independent Chrome profiles.

## Features

- Create and edit Chrome profile configurations
- Launch selected profiles or all profiles
- Arrange Chrome windows into a grid
- Import proxy lists
- Group-control navigation and JavaScript execution through Chrome DevTools Protocol
- Synchronized mouse and keyboard control across Chrome windows
- In-page badge showing each Chrome window number and current public exit IP

## Download / Run

Download the latest release package:

[Chrome多开管理器_v1.0_发布版.zip](https://github.com/cryptoresetlife/chrome-multi-manager/raw/main/Chrome%E5%A4%9A%E5%BC%80%E7%AE%A1%E7%90%86%E5%99%A8_v1.0_%E5%8F%91%E5%B8%83%E7%89%88.zip)

Use the compiled executable:

```text
Chrome多开管理器.exe
```

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

## License

MIT License. See [LICENSE](LICENSE).
