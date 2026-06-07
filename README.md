# Chrome Multi Manager

Chrome Multi Manager is a Windows PowerShell/WPF tool for launching and managing multiple independent Chrome profiles.

## Features

- Create and edit Chrome profile configurations
- Launch selected profiles or all profiles
- Arrange Chrome windows into a grid
- Import proxy lists
- Group-control navigation and JavaScript execution through Chrome DevTools Protocol
- Synchronized mouse and keyboard control across Chrome windows

## Download / Run

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
