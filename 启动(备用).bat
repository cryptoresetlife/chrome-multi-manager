@echo off
chcp 65001 >nul
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "& { $f='%~dp0ChromeManager.ps1'; $c=[System.IO.File]::ReadAllText($f,[System.Text.Encoding]::UTF8); [System.IO.File]::WriteAllText($f,$c,[System.Text.UTF8Encoding]::new($true)); & $f }"
