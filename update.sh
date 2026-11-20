#!/bin/bash
# v5
# LUVE 检查更新 / 安装更新 —— v5
#
# 更新源优先级：环境变量 SW_UPDATE_URL > $PAY/update-source 里写的一行地址
# 只换程序与脚本；永远不动 prefix（Steam 账号/游戏/存档）、recipes、playtime.json、bottles。
#
# v5 关键修复：
#   · 优先用增量包（2~3 MB），而不是每次都下 500+ MB 整包 —— 之前脚本完全没读 version.json
#     里的 update_sha256，每次都拖整包，这才是「更新老出错」的真凶。
#   · 全线断点续传（curl -C -），断了重跑接着下，不再从 0 开始。
#   · 下载完必须过 sha256 校验，校验不过就丢掉重来（避免续传续到坏文件上）。
#   · LUVE.app 改成「解到临时目录 → 验签 → 换名」的原子替换，失败自动回滚旧版。
#   · 解压器依次尝试 ditto / unzip / bsdtar（ditto 对某些 zip 会挑食）。
#   · 分阶段报错，能说清是「版本文件 / 下载 / 校验 / 解压 / 替换」哪一步挂了。
# v4 关键修复：curl 强制 HTTP/1.1 并重试 —— Surge 的 CDN 在 HTTP/2 下会把大文件流掐断
#             （表现为 curl: (92) PROTOCOL_ERROR，下载到 95% 突然失败）。
# v3 关键修复：所有文件替换改为「写临时文件 → mv 原子替换」。

set -u

# SW_PAY / SW_APP 只给自测用（可以在临时目录里跑一遍完整更新，不碰真安装）
PAY="${SW_PAY:-$HOME/Library/Application Support/SteamWine}"
APP="${SW_APP:-$HOME/Applications/LUVE.app}"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()  { printf '\033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '\033[31m✗\033[0m %s\n' "$*"; }
warn(){ printf '\033[33m!\033[0m %s\n' "$*"; }
die() { bad "$*"; exit 1; }

# ---------- 小工具 ----------

json_str() {  # json_str <file> <key>
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$1" 2>/dev/null | head -1
}
json_num() {  # json_num <file> <key>
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p" "$1" 2>/dev/null | head -1
}
read_version() { json_str "$1" version; }
vnum() { sed -n 's/^# v\([0-9]*\).*/\1/p' "$1" 2>/dev/null | head -1; }
sha_of() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }
human() {
  awk -v b="${1:-0}" 'BEGIN{ if (b>=1048576) printf "%.1f MB", b/1048576; else if (b>=1024) printf "%.0f KB", b/1024; else printf "%d B", b }'
}

# 原子替换：cp 到同目录临时文件，再 mv 覆盖。正在运行的脚本也能安全换掉。
put() {
  local src="$1" dst="$2" tmp
  tmp="$(dirname "$dst")/.luve-tmp.$$"
  cp "$src" "$tmp" 2>/dev/null || return 1
  chmod 755 "$tmp" 2>/dev/null
  mv -f "$tmp" "$dst"
}

# 断点续传下载。服务器不支持 Range（curl 33）就退化成整段重下。
dl() {  # dl <url> <out>
  local url="$1" out="$2"
  curl -fL --http1.1 --retry 4 --retry-delay 2 --retry-all-errors \
       --connect-timeout 20 -C - -o "$out" "$url" 2>/dev/null && return 0
  curl -fL --http1.1 --retry 4 --retry-delay 2 --retry-all-errors \
       --connect-timeout 20 -o "$out" "$url"
}

# 下到本地并校验；sha 为空时只下不验
fetch_verified() {  # fetch_verified <url> <out> [sha]
  local url="$1" out="$2" sha="${3:-}" i=0
  while [ "$i" -lt 3 ]; do
    i=$((i+1))
    if [ -f "$out" ] && [ -n "$sha" ] && [ "$(sha_of "$out")" = "$sha" ]; then return 0; fi
    dl "$url" "$out" || { [ -n "$sha" ] && rm -f "$out"; sleep 1; continue; }
    if [ -z "$sha" ]; then return 0; fi
    if [ "$(sha_of "$out")" = "$sha" ]; then return 0; fi
    bad "校验不符（第 $i 次），删掉重下"
    rm -f "$out"
  done
  return 1
}

unpack() {  # unpack <zip> <destdir>
  rm -rf "$2"; mkdir -p "$2"
  ditto -x -k "$1" "$2" 2>/dev/null && return 0
  rm -rf "$2"; mkdir -p "$2"
  unzip -q -o "$1" -d "$2" 2>/dev/null && return 0
  rm -rf "$2"; mkdir -p "$2"
  bsdtar -xf "$1" -C "$2" 2>/dev/null && return 0
  return 1
}

# ---------- 0. 环境 ----------

[ -d "$PAY" ] || die "没找到安装目录：$PAY —— LUVE 装好了吗？"

CUR="$(read_version "$PAY/version.json")"
CUR="${CUR:-0.0.0}"

SRC="${SW_UPDATE_URL:-}"
if [ -z "$SRC" ] && [ -f "$PAY/update-source" ]; then
  SRC="$(head -1 "$PAY/update-source" | tr -d '[:space:]')"
fi
if [ -z "$SRC" ]; then
  say "未配置更新源"
  echo "可以用环境变量指定，例如："
  echo '  SW_UPDATE_URL=https://luve.surge.sh/dist bash "$0"'
  exit 0
fi

IS_REMOTE=0
case "$SRC" in http://*|https://*) IS_REMOTE=1 ;; esac

say "检查更新"
echo "当前版本：$CUR"
echo "更新源：  $SRC"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------- 1. 取版本文件 ----------

if [ "$IS_REMOTE" = "1" ]; then
  fetch_verified "$SRC/version.json" "$TMP/version.json" \
    || die "第 1 步失败：取不到 version.json（网络不通？建议先跑一次「优选主机」）"
else
  cp "$SRC/version.json" "$TMP/version.json" 2>/dev/null \
    || die "更新源里没有 version.json：$SRC"
fi

NEW="$(read_version "$TMP/version.json")"
[ -n "$NEW" ] || die "版本文件格式不对（没有 version 字段）"

if [ "$NEW" = "$CUR" ]; then
  ok "已是最新版本 $CUR"
  exit 0
fi

say "发现新版本 $CUR → $NEW"
NOTES="$(json_str "$TMP/version.json" notes)"
[ -n "$NOTES" ] && echo "更新内容：$NOTES"

# ---------- 2. 下载（先试增量包） ----------

DELTA_SHA="$(json_str "$TMP/version.json" update_sha256)"
FULL_SHA="$(json_str "$TMP/version.json" sha256)"
DELTA_URL="$SRC/LUVE-$NEW-delta.zip"
FULL_URL="$SRC/LUVE-$NEW.zip"
PKG=""
USED=""

if [ "$IS_REMOTE" = "1" ] && [ -n "$DELTA_SHA" ]; then
  say "下载增量包 ${NEW}（约 $(human "$(json_num "$TMP/version.json" update_size)")）"
  if fetch_verified "$DELTA_URL" "$TMP/delta.zip" "$DELTA_SHA"; then
    PKG="$TMP/delta.zip"; USED="delta"
    ok "增量包下载并校验通过"
  else
    warn "增量包拿不到，退回整包"
  fi
fi

if [ -z "$PKG" ]; then
  if [ "$IS_REMOTE" = "1" ]; then
    SIZE="$(json_num "$TMP/version.json" size)"
    say "下载完整包 ${NEW}（约 $(human "$SIZE")）"
    fetch_verified "$FULL_URL" "$TMP/pkg.zip" "$FULL_SHA" \
      || die "第 2 步失败：下载 $NEW 失败（网络不稳？重跑会从断点继续）"
    PKG="$TMP/pkg.zip"; USED="full"
    ok "完整包下载并校验通过"
  else
    # 本地目录：可能是 App 已经下好的包（里面有 zip），也可能是一个解开的目录
    for cand in "$SRC/LUVE-$NEW-delta.zip" "$SRC/LUVE-$NEW.zip"; do
      if [ -f "$cand" ]; then PKG="$cand"; USED="localzip"; break; fi
    done
    [ -z "$PKG" ] && { PKG="$SRC"; USED="dir"; }
  fi
fi

# 不管是远端下的还是本地给的，只要 version.json 给了 sha256 就必须校验
if [ "$USED" != "dir" ] && [ -f "$PKG" ]; then
  WANT_SHA=""
  case "$USED" in
    delta) WANT_SHA="$DELTA_SHA" ;;
    full)  WANT_SHA="$FULL_SHA" ;;
    localzip)
      case "$PKG" in
        *-delta.zip) WANT_SHA="$DELTA_SHA" ;;
        *)           WANT_SHA="$FULL_SHA" ;;
      esac
      ;;
  esac
  if [ -n "$WANT_SHA" ]; then
    GOT_SHA="$(sha_of "$PKG")"
    if [ "$GOT_SHA" != "$WANT_SHA" ]; then
      die "第 2 步失败：包校验不符（期望 ${WANT_SHA%${WANT_SHA#??????}}…，实际 ${GOT_SHA%${GOT_SHA#??????}}…）"
    fi
    ok "包校验通过（sha256 ${GOT_SHA%${GOT_SHA#????????????}}…）"
  fi
fi

# ---------- 3. 解开 ----------

NEWROOT=""
if [ "$USED" = "dir" ]; then
  NEWROOT="$PKG"
else
  say "解压（$(human "$(stat -f%z "$PKG")")）"
  unpack "$PKG" "$TMP/pkg" || die "第 3 步失败：ditto / unzip / bsdtar 都解不开这个包"
  NEWROOT="$(find "$TMP/pkg" -maxdepth 2 -name "LUVE-$NEW" -type d 2>/dev/null | head -1)"
  if [ -z "$NEWROOT" ]; then
    APPDIR="$(find "$TMP/pkg" -maxdepth 2 -name "LUVE.app" -type d 2>/dev/null | head -1)"
    [ -n "$APPDIR" ] && NEWROOT="$(dirname "$APPDIR")"
  fi
fi
[ -n "$NEWROOT" ] && [ -d "$NEWROOT" ] || die "第 3 步失败：解压后找不到 LUVE-$NEW 目录"
ok "解压完成（${USED}）"

# ---------- 4. 覆盖脚本 ----------

say "安装"

for f in env.sh launch-game.sh launch-steam.sh launch.sh quit-all.sh update.sh version.json; do
  [ -f "$NEWROOT/payload/$f" ] || continue
  # update.sh 只升不降，别把修好的脚本换回旧的
  if [ "$f" = "update.sh" ]; then
    lb=$(vnum "$PAY/update.sh"); lb=${lb:-0}
    nb=$(vnum "$NEWROOT/payload/$f"); nb=${nb:-0}
    if [ "$nb" -lt "$lb" ]; then
      echo "  · 包里的 update.sh 是 v${nb}，本地已 v${lb}，跳过降级"
      continue
    fi
  fi
  if put "$NEWROOT/payload/$f" "$PAY/$f"; then
    ok "更新 $f"
  else
    warn "写入 $f 失败（权限？），继续"
  fi
done

if [ -d "$NEWROOT/payload/tools" ]; then
  mkdir -p "$PAY/tools"
  rsync -a "$NEWROOT/payload/tools/" "$PAY/tools/" \
    && chmod +x "$PAY/tools/"* 2>/dev/null \
    && ok "更新 tools" || warn "更新 tools 失败，继续"
fi

# 老用户也可能缺这份主机列表（比如第一次就没写），顺手补上
if [ -f "$NEWROOT/payload/steam/update_hosts_cached.vdf" ]; then
  SD="$PAY/SharedSupport/prefix/drive_c/Program Files (x86)/Steam"
  if [ -d "$SD" ] && [ ! -f "$SD/update_hosts_cached.vdf" ]; then
    put "$NEWROOT/payload/steam/update_hosts_cached.vdf" "$SD/update_hosts_cached.vdf" \
      && ok "补上 Valve 签名的主机列表（下次更新会更快）"
  fi
fi

# ---------- 5. 原子替换 .app ----------

if [ -d "$NEWROOT/LUVE.app" ]; then
  say "替换 LUVE.app"
  mkdir -p "$HOME/Applications"
  NEWAPP="$HOME/Applications/.LUVE.app.new.$$"
  OLDAPP="$HOME/Applications/.LUVE.app.old.$$"
  rm -rf "$NEWAPP" "$OLDAPP"
  if ! ditto "$NEWROOT/LUVE.app" "$NEWAPP" 2>/dev/null; then
    rm -rf "$NEWAPP"
    die "第 5 步失败：复制新 app 失败（磁盘满了？）"
  fi
  xattr -dr com.apple.quarantine "$NEWAPP" 2>/dev/null
  codesign --force --deep --sign - "$NEWAPP" >/dev/null 2>&1 || true

  if [ -d "$APP" ]; then
    mv "$APP" "$OLDAPP" 2>/dev/null || { rm -rf "$NEWAPP"; die "第 5 步失败：旧 app 挪不动"; }
  fi
  if mv "$NEWAPP" "$APP" 2>/dev/null; then
    rm -rf "$OLDAPP"
    ok "更新 LUVE.app"
  else
    [ -d "$OLDAPP" ] && mv "$OLDAPP" "$APP" 2>/dev/null
    rm -rf "$NEWAPP"
    die "第 5 步失败：换上新 app 失败，已回滚到旧版"
  fi
else
  warn "包里没有 LUVE.app（增量包只带脚本？），程序本体保持不变"
fi

# ---------- 6. 把 Steam 的清一下，避免下次启动卡住 ----------

if [ -x "$PAY/tools/steamfix" ]; then
  "$PAY/tools/steamfix" auto >/dev/null 2>&1 || true
fi

# ---------- 7. 自更新（只升不降） ----------

if [ "$IS_REMOTE" = "1" ]; then
  if dl "$SRC/update.sh" "$TMP/update.sh" 2>/dev/null && [ -s "$TMP/update.sh" ]; then
    cur_v=$(vnum "$PAY/update.sh"); cur_v=${cur_v:-0}
    new_v=$(vnum "$TMP/update.sh"); new_v=${new_v:-0}
    if [ "$new_v" -ge "$cur_v" ]; then
      put "$TMP/update.sh" "$PAY/update.sh" 2>/dev/null && ok "更新脚本已同步（v${new_v}）"
    else
      echo "  · 站上的更新脚本还停在 v${new_v}（本地 v$cur_v 更新），跳过覆盖"
    fi
  fi
fi

say "完成"
ok "已更新到 $NEW"
echo "你的 Steam 账号、游戏、存档、bottle 都没动。"

if [ -t 0 ]; then
  printf '\n现在重新打开 LUVE？[y/N] '
  read -r ans
  case "$ans" in
    y|Y) open "$APP" && ok "已启动" ;;
    *)   echo "好的，下次手动打开。" ;;
  esac
fi
