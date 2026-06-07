# macOS Preview

This folder contains the macOS preview source for Chrome Multi Manager.

## Run

Download the package:

[Chrome多开管理器_mac_发布版.zip](https://github.com/cryptoresetlife/chrome-multi-manager/raw/main/Chrome%E5%A4%9A%E5%BC%80%E7%AE%A1%E7%90%86%E5%99%A8_mac_%E5%8F%91%E5%B8%83%E7%89%88.zip)

After extracting on macOS, right-click `Chrome多开管理器.app` and choose `Open`.

If macOS blocks the app wrapper, run:

```bash
bash 启动.command
```

## Requirements

- macOS 11 or later
- Google Chrome
- Python 3

## Notes

- Profile archives are stored under `~/Library/Application Support/ChromeMultiManager/Profiles/profile_编号`.
- The macOS preview supports independent profiles, proxy import, batch launch/close, group navigation/JS, window arrangement, and the window number/IP badge.
- Whole-window mouse and keyboard synchronization is not included in this preview because macOS requires Accessibility permissions and real-machine event-tap testing.
