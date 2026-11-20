#!/bin/bash
PAY="$HOME/Library/Application Support/SteamWine"
SW="$PAY/SharedSupport/wswine.bundle"
export WINEPREFIX="$PAY/SharedSupport/prefix"
export WINEDEBUG=-all WINEESYNC=1 WINEMSYNC=1 LANG=zh_CN.UTF-8
export DYLD_LIBRARY_PATH="$PAY/Frameworks"
export DYLD_FALLBACK_LIBRARY_PATH="$PAY/Frameworks"
LOG="$HOME/Library/Logs/Steam-Wine.log"
[ -x "$PAY/tools/accel" ] && "$PAY/tools/accel" auto >/dev/null 2>&1
echo "==== $(date '+%F %T') steam ====" >> "$LOG"
exec "$SW/bin/wine" "C:\\Program Files (x86)\\Steam\\Steam.exe" "$@" >> "$LOG" 2>&1
