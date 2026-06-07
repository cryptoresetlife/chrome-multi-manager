# Changelog

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
