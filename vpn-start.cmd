@echo off
title sing-box VPN - turning ON
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0vpn-control.ps1" -Action Start
