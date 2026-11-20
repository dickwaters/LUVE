#!/bin/bash
# 启动 Steam。启动前先把「会让 Steam 卡死」的状态清掉（社区已知问题）：
#   · Run 键里的 "Steam" -silent 静默更新项
#   · htmlcache/Singleton* 残留锁
# 顺带：如果 update_hosts_cached.vdf 超过 7 天没更新，后台重测一次官方更新主机。
source "$HOME/Library/Application Support/SteamWine/env.sh"
if steam_running; then exit 0; fi

[ -x "$PAY/tools/accel" ] && "$PAY/tools/accel" auto >/dev/null 2>&1
[ -x "$PAY/tools/steamfix" ] && "$PAY/tools/steamfix" auto >/dev/null 2>&1

UH="$WINEPREFIX/drive_c/Program Files (x86)/Steam/update_hosts_cached.vdf"
if [ -x "$PAY/tools/netpick" ]; then
  if [ ! -f "$UH" ] || [ $(( $(date +%s) - $(stat -f%m "$UH" 2>/dev/null || echo 0) )) -gt 604800 ]; then
    ( "$PAY/tools/netpick" apply >/dev/null 2>&1 ) &
  fi
fi

cleanup_orphans
echo "==== $(date '+%F %T') Steam ====" >> "$LOG"
nohup "$WINE" "$STEAM_EXE" >> "$LOG" 2>&1 &
