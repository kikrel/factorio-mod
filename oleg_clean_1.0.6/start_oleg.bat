@echo off
chcp 65001 >nul
title Oleg Bridge for Factorio
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bridge.ps1"
pause
