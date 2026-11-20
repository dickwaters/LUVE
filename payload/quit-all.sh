#!/bin/bash
# 一键退出 Steam + 所有游戏（含残留 wine 进程）
for p in Steam.exe steamwebhelper.exe gameoverlayui64.exe winedevice.exe services.exe plugplay.exe svchost.exe explorer.exe lsass.exe conhost.exe wineserver; do
  pkill -f "$p" 2>/dev/null
done
sleep 3
for p in Steam.exe steamwebhelper.exe winedevice.exe services.exe plugplay.exe explorer.exe lsass.exe conhost.exe wineserver; do
  pkill -9 -f "$p" 2>/dev/null
done
rm -rf /tmp/.wine-$(id -u)/server-* 2>/dev/null
echo "已退出 Steam 和所有 wine 进程"
