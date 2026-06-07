# Changelog

## 1.0.0-mac.1

- Add a macOS preview package implemented with Python/Tkinter.
- Support independent Chrome profile directories, proxy import, batch launch/close, group navigation/JS, window arrangement, and the window number/IP badge.
- Include a minimal `.app` wrapper and `启动.command` launcher for macOS.

## 1.0.0.4

- Add an in-page badge for each Chrome window with the window number and current public exit IP.
- Re-inject the badge after launch, refresh, timed status checks, and group-control navigation.
- Build Chrome DevTools Protocol messages with structured JSON to handle injected scripts safely.

## 1.0.0.3

- Move global mouse and keyboard hooks onto a dedicated background message thread.
- Fix a WPF crash that could close the app when enabling sync with multiple Chrome windows open.
- Add local crash logging to `%APPDATA%\ChromeManager\ChromeManager.log`.

## 1.0.0.2

- Add whole-window mouse and keyboard synchronization for Chrome UI areas such as the address bar.
- Keep Chrome DevTools Protocol dispatch as a fallback for page content.

## 1.0.0.1

- Fix profile loading from JSON arrays.
- Improve Chrome runtime/window discovery by debug port.
