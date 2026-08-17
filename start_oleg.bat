@echo off
chcp 65001 >nul
title Oleg Bridge for Factorio
REM Launch PowerShell and set console encoding to UTF-8 before running the script
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; [Console]::InputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8; & '%~dp0bridge.ps1'"
pause
