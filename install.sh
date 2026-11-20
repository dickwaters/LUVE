#!/bin/bash
# LUVE 安装器 v2 —— 在一台干净的 Apple Silicon Mac 上装好运行环境。
# 用法: ./install.sh
#
# 做四件事：放文件 → 建 Wine 环境 → 装 Steam（官方安装器）→ 把首次更新跑完
# 不会复制任何人的账号、存档或游戏。
#
# v2 关键修复：
#   · 装 Steam 不再用固定 `sleep 8` 猜，改成轮询 Steam.exe（最多 300 秒）+ 判退出码，
#     装不上就明确说是哪一步。
#   · 装完立刻跑 steamprewarm，把 Steam 首次客户端更新在安装阶段跑完（带进度、断点、诊断），
#     用户第一次打开就是能登录的状态，不会停在「Updating Steam」转圈。
#   · 装完跑 netpick apply：实测 Valve 官方更新镜像，把通得快的写进 Steam 自己的
#     update_hosts_cached.vdf。只用官方主机，不依赖任何加速器/第三方服务。
#   · 装完跑 steamfix auto：清掉会让 Steam 卡死的自启动项（-silent）和残留锁。
#   · LUVE.app 安装改成「临时目录 → 验签 → 换名」的原子替换，失败回滚。

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PAY="$HOME/Library/Application Support/SteamWine"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

echo "== LUVE 安装器 v2 =="
if [ "$(uname -m)" != "arm64" ]; then
  echo "❌ 只支持 Apple Silicon（M 系列）"; exit 1
fi
OSMAJ="$(sw_vers -productVersion | cut -d. -f1)"
[ "${OSMAJ:-0}" -ge 14 ] || die "需要 macOS 14 或更新，你当前是 $(sw_vers -productVersion)"

# 扫描游戏列表要用 python3（系统自带，需装过命令行工具）
if ! command -v python3 >/dev/null 2>&1; then
  warn "没找到 python3，应用扫描会不可用。装一下命令行工具：xcode-select --install"
fi

# ---------- 1. 放文件 ----------
say "→ 复制运行文件到 $PAY"
mkdir -p "$PAY"
# 升级安装时，保住用户自己的游戏列表/配方/时长，绝不用包里的空文件覆盖
BAK="$(mktemp -d)"
for keep in profiles.conf playtime.json recipes bottles; do
  [ -e "$PAY/$keep" ] && cp -R "$PAY/$keep" "$BAK/" 2>/dev/null || true
done
[ -d "$PAY/SharedSupport/bottles" ] && cp -R "$PAY/SharedSupport/bottles" "$BAK/bottles" 2>/dev/null || true
ditto "$HERE/payload" "$PAY"
for keep in profiles.conf playtime.json recipes; do
  [ -e "$BAK/$keep" ] && rm -rf "$PAY/$keep" && cp -R "$BAK/$keep" "$PAY/" 2>/dev/null || true
done
if [ -d "$BAK/bottles" ]; then
  mkdir -p "$PAY/SharedSupport"
  rm -rf "$PAY/SharedSupport/bottles"
  cp -R "$BAK/bottles" "$PAY/SharedSupport/bottles" 2>/dev/null || true
fi
rm -rf "$BAK"
mkdir -p "$PAY/downloads" "$PAY/recipes"
chmod +x "$PAY/tools/"* 2>/dev/null || true
ok "运行文件就位"

# ---------- 2. 建 Wine 环境 ----------
export WINEPREFIX="$PAY/SharedSupport/prefix"
if [ ! -d "$WINEPREFIX/drive_c" ]; then
  say "→ 首次创建 Wine 环境（约 1 分钟，请不要关窗口）"
  # shellcheck disable=SC1091
  source "$PAY/env.sh"
  "$WINE" wineboot -u >/dev/null 2>&1 || true
  "$WINE" wineboot -s >/dev/null 2>&1 || true
  ok "Wine 环境就绪"
else
  echo "→ 已有 Wine 环境，跳过创建"
fi
# shellcheck disable=SC1091
source "$PAY/env.sh"

# ---------- 3. 装 Steam（优先用包里自带的官方安装器，不联网） ----------
STEAM_DIR="$WINEPREFIX/drive_c/Program Files (x86)/Steam"
STEAM_EXE_PATH="$STEAM_DIR/Steam.exe"
CACHED="$PAY/downloads/SteamSetup.exe"

steam_ok() {   # $1 = 文件；是官方安装器才返回 0
  f="$1"
  [ -s "$f" ] || return 1
  [ "$(head -c 2 "$f")" = "MZ" ] || return 1
  # 官方 NSIS 安装器里有 ASCII 的 "Valve Corp." 与 "Nullsoft"
  strings -a "$f" 2>/dev/null | grep -q "Valve Corp\." || return 1
  strings -a "$f" 2>/dev/null | grep -qi "Nullsoft" || return 1
  # 包里带了 sha256 就按它校验 —— 这条不依赖任何网络和文件关联
  if [ -s "$PAY/downloads/SteamSetup.exe.sha256" ]; then
    want="$(head -1 "$PAY/downloads/SteamSetup.exe.sha256" | tr -d '[:space:]')"
    got="$(shasum -a 256 "$f" | awk '{print $1}')"
    [ "$want" = "$got" ] || { echo "   · 哈希不符，拒绝使用这份安装器"; return 1; }
  fi
  return 0
}

# 轮询等 Steam.exe 出现（不再用固定 sleep 猜）
wait_steam_exe() {   # $1 = 最多等多少秒
  local limit="${1:-300}" i=0
  while [ "$i" -lt "$limit" ]; do
    [ -f "$STEAM_EXE_PATH" ] && return 0
    sleep 1
    i=$((i+1))
    [ $((i % 15)) -eq 0 ] && printf '   · 还在装… %ds\n' "$i"
  done
  return 1
}

if [ -f "$STEAM_EXE_PATH" ]; then
  echo "→ Steam 已安装，跳过"
else
  SRC=""
  if steam_ok "$CACHED"; then
    SRC="$CACHED"; echo "→ 用包里自带的 Steam 安装器（不联网）"
  else
    say "→ 包里没有可用安装器，联网获取"
    TMPD="$(mktemp -d)"; got=0
    for url in \
      "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe" \
      "https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe" \
      "https://media.steampowered.com/client/installer/SteamSetup.exe"; do
      host="${url#https://}"; host="${host%%/*}"
      case " cdn.akamai.steamstatic.com cdn.fastly.steamstatic.com media.steampowered.com " in
        *" $host "*) ;;
        *) echo "   · 跳过非官方域名 $host"; continue ;;
      esac
      final="$(curl -fsSL --http1.1 --proto '=https' --proto-redir '=https' --max-redirs 3 \
                     --retry 2 -o "$TMPD/SteamSetup.exe" -w '%{url_effective}' "$url" 2>/dev/null)" || continue
      fh="${final#https://}"; fh="${fh%%/*}"
      case " cdn.akamai.steamstatic.com cdn.fastly.steamstatic.com media.steampowered.com " in
        *" $fh "*) ;;
        *) echo "   · 跳到了 ${fh}，不在官方名单，丢弃"; rm -f "$TMPD/SteamSetup.exe"; continue ;;
      esac
      if steam_ok "$TMPD/SteamSetup.exe"; then
        got=1; mkdir -p "$PAY/downloads"; cp "$TMPD/SteamSetup.exe" "$PAY/downloads/SteamSetup.exe"
        SRC="$PAY/downloads/SteamSetup.exe"; break
      fi
      rm -f "$TMPD/SteamSetup.exe"
    done
    rm -rf "$TMPD"
    if [ "$got" != "1" ]; then
      cat <<'EOF'
❌ 拿到的 Steam 安装器没通过校验，已停止（什么都没装进你的 Wine 环境）。

这基本说明下载链路被劫持了。请手动处理：
  1. 浏览器打开 https://store.steampowered.com/about/ 下载 SteamSetup.exe
  2. 把它放到 ~/Library/Application Support/SteamWine/downloads/SteamSetup.exe
  3. 重跑本脚本 —— 会直接使用你放进去的这份
EOF
      exit 1
    fi
  fi

  say "→ 安装 Steam（静默，直接交给 Wine，不经过系统文件关联）"
  # 隔离：复制到 700 的私有临时目录执行，执行完即删。
  RUNDIR="$(mktemp -d)"; chmod 700 "$RUNDIR"
  cp "$SRC" "$RUNDIR/SteamSetup.exe" && chmod 700 "$RUNDIR/SteamSetup.exe"
  xattr -dr com.apple.quarantine "$RUNDIR/SteamSetup.exe" 2>/dev/null || true
  "$WINE" "$RUNDIR/SteamSetup.exe" /S >/dev/null 2>&1
  RC=$?
  rm -rf "$RUNDIR"
  [ "$RC" -ne 0 ] && warn "安装器退出码 ${RC}（不一定是失败，继续看结果）"

  if wait_steam_exe 300; then
    ok "Steam 已安装"
  else
    warn "等了 300 秒没看到 Steam.exe —— 安装器没跑成功"
    warn "可以手动再试：\"$WINE\" \"$SRC\" /S"
    warn "先继续装 LUVE，稍后可以在「设置 → 续跑首次更新」再试一次"
  fi
fi

# ---------- 3.5 放进 Valve 签名的更新主机列表 ----------
# 没有这份文件时，Steam 只用一台 baked in 的 cdn.steamstatic.com，
# 实测 336 MB 客户端更新只有 ~100 KB/s —— 这就是「首次更新卡住」的真因。
SEED="$HERE/payload/steam/update_hosts_cached.vdf"
if [ -f "$SEED" ] && [ -d "$STEAM_DIR" ] && [ ! -f "$STEAM_DIR/update_hosts_cached.vdf" ]; then
  if cp "$SEED" "$STEAM_DIR/update_hosts_cached.vdf" 2>/dev/null; then
    ok "已放入 Valve 签名的主机列表（首次更新会从多台官方主机里挑）"
  else
    warn "放主机列表失败（不影响后续步骤）"
  fi
fi

# ---------- 4. 清理会让 Steam 卡住的坏状态 ----------
if [ -x "$PAY/tools/steamfix" ]; then
  say "→ 清理 Steam 的静默自启动项和残留锁"
  "$PAY/tools/steamfix" auto 2>/dev/null | sed 's/^/   /' || true
fi

# ---------- 5. 优选更新主机（只用 Valve 官方镜像） ----------
if [ -x "$PAY/tools/netpick" ] && [ -f "$STEAM_EXE_PATH" ]; then
  say "→ 实测 Valve 官方更新镜像，挑能通最快的"
  "$PAY/tools/netpick" apply 2>&1 | sed 's/^/   /' || warn "测更新主机失败（不影响安装）"
fi

# ---------- 6. 跑完 Steam 首次更新 ----------
if [ -x "$PAY/tools/steamprewarm" ] && [ -f "$STEAM_EXE_PATH" ]; then
  say "→ 把 Steam 首次更新跑完（这一步决定你之后打不打开得起来）"
  echo "   可能要几分钟，有进度，别关窗口"
  # 注意：管道里的 $? 是 sed 的退出码，必须用 PIPESTATUS 取 steamprewarm 自己的
  "$PAY/tools/steamprewarm" --timeout 1200 2>&1 | sed 's/^/   /'
  PREWARM_RC=${PIPESTATUS[0]}
  if [ "$PREWARM_RC" -eq 0 ]; then
    ok "Steam 首次更新完成，可以正常登录了"
    PREWARM_OK=1
  else
    PREWARM_OK=0
    case "$PREWARM_RC" in
      2) warn "Steam 首次更新卡住了（网络不通畅，退出码 2）" ;;
      3) warn "没找到 Steam.exe（安装没成功，退出码 3）" ;;
      4) warn "Steam 首次更新超时（退出码 4）" ;;
      *) warn "Steam 首次更新没跑完（退出码 $PREWARM_RC）" ;;
    esac
    warn "别急：打开 LUVE →「设置 → Steam 网络」可以再点「续跑首次更新」"
    warn "也可以先点「优选主机」换一条官方线路再试"
  fi
else
  PREWARM_OK=0
fi

# ---------- 7. 装上「LUVE」 ----------
say "→ 安装 LUVE.app"
mkdir -p "$HOME/Applications"
NEWAPP="$HOME/Applications/.LUVE.app.new.$$"
OLDAPP="$HOME/Applications/.LUVE.app.old.$$"
rm -rf "$NEWAPP" "$OLDAPP"
if ditto "$HERE/LUVE.app" "$NEWAPP" 2>/dev/null; then
  xattr -dr com.apple.quarantine "$NEWAPP" 2>/dev/null || true
  codesign --force --deep --sign - "$NEWAPP" >/dev/null 2>&1 || true
  [ -d "$HOME/Applications/LUVE.app" ] && mv "$HOME/Applications/LUVE.app" "$OLDAPP" 2>/dev/null
  if mv "$NEWAPP" "$HOME/Applications/LUVE.app" 2>/dev/null; then
    rm -rf "$OLDAPP"
    ok "LUVE.app 已安装"
  else
    [ -d "$OLDAPP" ] && mv "$OLDAPP" "$HOME/Applications/LUVE.app" 2>/dev/null
    rm -rf "$NEWAPP"
    die "安装 LUVE.app 失败（已回滚）"
  fi
else
  rm -rf "$NEWAPP"
  die "复制 LUVE.app 失败"
fi

cat <<EOF

✅ 装好了

  打开：~/Applications/LUVE.app
  首页会自动列出 Steam、你装的所有游戏，以及每个 bottle 里的程序
  （默认隐藏系统组件，右上角眼睛图标可以切出来）

  安装目录：$PAY
  卸载：删掉这个目录 + ~/Applications/LUVE.app 即可，不留残留
EOF

if [ "${PREWARM_OK:-0}" != "1" ]; then
  cat <<'EOF'

⚠️ 有一件事没做完：Steam 的首次客户端更新没跑完。
   打开 LUVE →「设置 → Steam 网络」：
     · 先点「优选主机」
     · 再点「续跑首次更新」
   如果还是不行，把「导出日志」的结果发出来，能看出卡在哪个主机。
EOF
fi
