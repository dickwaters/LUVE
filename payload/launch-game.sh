#!/bin/bash
# 用法: launch-game.sh <AppID> [--dry-run]
#
# 统一策略（只在这里写一次，不逐个游戏改参数）：
#   1. Steam 必须在线 —— 没起就拉起，并等到登录成功
#   2. Steam IPC  —— 游戏目录必须有 steam_appid.txt，缺了/不对就自动补
#                     （缺它 = SteamApi_Init 返回 false = 游戏秒退）
#   3. 显示       —— 3D 游戏一律跑虚拟桌面，尺寸 = 当前屏幕逻辑分辨率，
#                     跟着屏幕走，不写死数字
#   4. 游戏内分辨率 —— 配方里有 prelaunch 就先执行（如 hp_lock 自动钉成屏幕尺寸）
#
# --dry-run 只打印将要做什么，不启动任何东西。
source "$HOME/Library/Application Support/SteamWine/env.sh"
GAMES="$WINEPREFIX/drive_c/Program Files (x86)/Steam/steamapps/common"
BASE="$(cd "$(dirname "$0")" && pwd)"
PROFILES="$BASE/profiles.conf"
DRY=0
[ "$2" = "--dry-run" ] && DRY=1

APPID="$1"
if [ -z "$APPID" ]; then echo "用法: launch-game.sh <AppID> [--dry-run]" >&2; exit 1; fi

LINE=$(grep -E "^${APPID}\|" "$PROFILES" 2>/dev/null | head -1)
if [ -z "$LINE" ]; then echo "profiles.conf 里没有 $APPID" >&2; exit 1; fi
IFS='|' read -r _ REL ARGSTR DESKTOP_RAW <<< "$LINE"
case "$REL" in
  /*|Z:*|C:*) EXE="$REL" ;;          # 拖进来的独立 exe（绝对路径）
  *)         EXE="$GAMES/$REL" ;;
esac
read -r -a ARGS <<< "$ARGSTR"
if [ ! -f "$EXE" ]; then echo "找不到: $EXE" >&2; exit 1; fi

# ---------- 3. 显示策略：桌面尺寸永远等于当前屏幕 ----------
screen_size() { "$BASE/tools/screensize" 2>/dev/null || echo "1280x832"; }
# 画面模式：screen = 跟随屏幕（16:10 屏就是 1280x832）；16:9 = 窗口按 16:9 内切，上下留黑边
DISPLAY_MODE=$(head -1 "$BASE/display.mode" 2>/dev/null | tr -d '[:space:]')
if [ -n "${DESKTOP_RAW:-}" ]; then
  SZ=$(screen_size); SW=${SZ%x*}
  case "$DISPLAY_MODE" in
    "16:9") DESKTOP="${SW}x$(( SW * 9 / 16 ))" ;;
    "4:3")  DESKTOP="${SW}x$(( SW * 3 / 4 ))" ;;
    *)      DESKTOP="$SZ" ;;
  esac
else
  DESKTOP=""
fi

# ---------- 4. 配方里的 prelaunch（自动钉游戏内分辨率） ----------
PRELAUNCH=$(sed -n 's/.*"prelaunch"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            "$BASE/recipes/$APPID.json" 2>/dev/null | head -1)

# ---------- 2. Steam IPC：steam_appid.txt ----------
APPID_FILE="$(dirname "$EXE")/steam_appid.txt"
appid_now() { [ -f "$APPID_FILE" ] && tr -dc '0-9' < "$APPID_FILE"; }
appid_ok() { [ "$(appid_now)" = "$APPID" ]; }
ensure_appid() {
  appid_ok && return 0
  printf '%s\n' "$APPID" > "$APPID_FILE" 2>/dev/null || return 1
  echo "  · 已补 steam_appid.txt ($APPID)"
}

if [ "$DRY" = "1" ]; then
  echo "$APPID -> $(basename "$EXE") [${ARGS[*]}]"
  echo "  虚拟桌面 : ${DESKTOP:-无}"
  echo "  appid文件: $(appid_now || true) $(appid_ok && echo '✓' || echo '✗ 启动时会自动补')"
  echo "  prelaunch: ${PRELAUNCH:-无}"
  exit 0
fi

ensure_appid
if [ -n "$PRELAUNCH" ]; then
  read -r -a PL <<< "$PRELAUNCH"
  if [ -x "$BASE/tools/${PL[0]}" ]; then
    "$BASE/tools/${PL[0]}" "${PL[@]:1}" >/dev/null 2>&1 && echo "  · prelaunch: ${PRELAUNCH} 完成"
  fi
fi

# ---------- 4.5 bottle：独立 Wine 环境 ----------
BOTTLE_NAME=$(sed -n 's/.*"bottle"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$BASE/recipes/$APPID.json" 2>/dev/null | head -1)
BOTTLE_NAME=${BOTTLE_NAME:-main}
if [ "$BOTTLE_NAME" != "main" ] && [ -d "$PAY/SharedSupport/bottles/$BOTTLE_NAME/drive_c" ]; then
  export WINEPREFIX="$PAY/SharedSupport/bottles/$BOTTLE_NAME"
  # 该 bottle 自己的引擎（可选）
  BE=$(head -1 "$PAY/SharedSupport/bottles/$BOTTLE_NAME/engine" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$BE" ] && [ -d "$PAY/SharedSupport/engines/$BE" ]; then
    ENGINE="$PAY/SharedSupport/engines/$BE"; WINE="$ENGINE/bin/wine"
    export DYLD_LIBRARY_PATH="$PAY/Frameworks:$ENGINE/lib/external"
    export DYLD_FALLBACK_LIBRARY_PATH="$DYLD_LIBRARY_PATH"
    export DYLD_FRAMEWORK_PATH="$ENGINE/lib/external"
  fi
fi

# ---------- 5. 加速：跟着 Steam++ 的 hosts 劫持走（代理活着才桥接） ----------
[ -x "$BASE/tools/accel" ] && "$BASE/tools/accel" auto >/dev/null 2>&1
# 清掉会让 Steam 卡在 Updating 的静默自启动项和残留锁
[ -x "$BASE/tools/steamfix" ] && "$BASE/tools/steamfix" auto >/dev/null 2>&1

if [ -f "$BASE/metal_hud.on" ]; then export MTL_HUD_ENABLED=1; fi
LOGIN="$WINEPREFIX/drive_c/Program Files (x86)/Steam/logs/steamui_login.txt"

start_steam_wait() {
  local start=0
  [ -f "$LOGIN" ] && start=$(wc -l < "$LOGIN")
  echo "==== $(date '+%F %T') Steam (auto) ====" >> "$LOG"
  nohup "$WINE" "$STEAM_EXE" >> "$LOG" 2>&1 &
  for i in $(seq 1 30); do
    sleep 3
    [ -f "$LOGIN" ] && tail -n +$((start+1)) "$LOGIN" | grep -qa 'SetLoginState: Success' && { sleep 4; return; }
  done
}

run_game() {
  cd "$(dirname "$EXE")" || return 1
  echo "==== $(date '+%F %T') game $APPID ====" >> "$LOG"
  if [ -n "${DESKTOP:-}" ]; then
    nohup "$WINE" explorer "/desktop=Game$APPID,$DESKTOP" "$(basename "$EXE")" "${ARGS[@]}" >> "$LOG" 2>&1 &
  else
    nohup "$WINE" "$EXE" "${ARGS[@]}" >> "$LOG" 2>&1 &
  fi
  local pid=$!
  # 时长统计：等这个 exe 退出后把秒数记进 playtime.json
  ( START=$(date +%s); GAMEBASE=$(basename "$EXE")
    while pgrep -f "$GAMEBASE" >/dev/null 2>&1; do sleep 5; done
    END=$(date +%s); DUR=$((END-START))
    "$PAY/tools/playtime" add "$APPID" "$DUR" >/dev/null 2>&1
    # 崩溃取证：启动 30 秒内就退出，多半是没跑起来
    if [ "$DUR" -lt 30 ]; then
      "$PAY/tools/export-logs" >/dev/null 2>&1
      printf '%s|%s|%s\n' "$APPID" "$DUR" "$(date '+%F %T')" > "$PAY/last-crash.txt"
    fi
  ) >/dev/null 2>&1 &
  echo $pid
}

steam_running || { cleanup_orphans; start_steam_wait; }
PID=$(run_game); sleep 12
if ! kill -0 "$PID" 2>/dev/null; then
  echo "==== $(date '+%F %T') retry after steam ready ====" >> "$LOG"
  cleanup_orphans
  start_steam_wait
  run_game >/dev/null
fi
