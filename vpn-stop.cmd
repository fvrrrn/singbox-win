@echo off
title sing-box VPN - turning OFF
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0vpn-control.ps1" -Action Stop
