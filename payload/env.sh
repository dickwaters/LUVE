# 共享环境（被各个启动器 source）
PAY="$HOME/Library/Application Support/SteamWine"
# 引擎可选：SharedSupport/engines/<名字>/ 存在就用它，否则用内置引擎
ENGINE_NAME=$(head -1 "$PAY/engine" 2>/dev/null | tr -d '[:space:]')
if [ -n "${WINE_ENGINE:-}" ]; then ENGINE_NAME="$WINE_ENGINE"; fi
if [ -n "${ENGINE_NAME:-}" ] && [ -d "$PAY/SharedSupport/engines/$ENGINE_NAME" ]; then
  ENGINE="$PAY/SharedSupport/engines/$ENGINE_NAME"
else
  ENGINE="$PAY/SharedSupport/wswine-dm.bundle"
fi
export WINEPREFIX="$PAY/SharedSupport/prefix"
export WINEDEBUG=-all
export LANG=zh_CN.UTF-8
export DYLD_LIBRARY_PATH="$PAY/Frameworks:$ENGINE/lib/external"
export DYLD_FALLBACK_LIBRARY_PATH="$DYLD_LIBRARY_PATH"
export DYLD_FRAMEWORK_PATH="$ENGINE/lib/external"
WINE="$ENGINE/bin/wine"
LOG="$HOME/Library/Logs/Steam-Wine.log"
STEAM_EXE='C:\Program Files (x86)\Steam\Steam.exe'
mkdir -p "$HOME/Library/Logs"
HOSTS="$WINEPREFIX/drive_c/windows/system32/drivers/etc/hosts"
if [ -f "$HOSTS" ]; then
  grep -q 'steamloopback.host' "$HOSTS" || printf '127.0.0.1 localhost\n127.0.0.1 steamloopback.host\n::1 localhost\n' >> "$HOSTS"
fi
steam_running() { pgrep -f 'Steam.exe' >/dev/null 2>&1; }

# 日志超过 5MB 就切一份，避免无限膨胀
if [ -f "$LOG" ] && [ $(stat -f%z "$LOG" 2>/dev/null || echo 0) -gt 5242880 ]; then
  mv -f "$LOG" "$LOG.1"
fi

# 冷启动前清掉上一次残留的 wine 后台进程（它们会让新进程 SIGFPE）
cleanup_orphans() {
  for p in winedevice.exe services.exe plugplay.exe svchost.exe explorer.exe lsass.exe conhost.exe gameoverlayui64.exe; do
    pkill -9 -f "$p" 2>/dev/null
  done
  pkill -9 -f 'C:\\windows\\system32\\wineserver' 2>/dev/null
  rm -rf /tmp/.wine-$(id -u)/server-* 2>/dev/null
  sleep 1
}
