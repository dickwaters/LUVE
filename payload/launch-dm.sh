#!/bin/bash
PAY="$HOME/Library/Application Support/SteamWine"
B="$PAY/SharedSupport/wswine-dm.bundle"
export WINEPREFIX="$PAY/SharedSupport/prefix"
export WINEDEBUG=-all LANG=zh_CN.UTF-8
export DYLD_LIBRARY_PATH="$PAY/Frameworks:$B/lib/external"
export DYLD_FALLBACK_LIBRARY_PATH="$DYLD_LIBRARY_PATH"
export DYLD_FRAMEWORK_PATH="$B/lib/external"
LOG="$HOME/Library/Logs/Steam-Wine.log"
echo "==== $(date '+%F %T') steam dm noesync ====" >> "$LOG"
exec "$B/bin/wine" "C:\\Program Files (x86)\\Steam\\Steam.exe" "$@" >> "$LOG" 2>&1
