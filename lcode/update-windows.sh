#!/usr/bin/env bash
# Windows 版增量更新：跟随官方最新 release，打 LCode 补丁，构建成桌面上的 magpie.exe
#
# 和 update.sh 的区别：
#   - 打包换成 Windows 的 go-winres（图标、版本资源）+ -H windowsgui（不弹控制台）
#   - 产物不装进 /Applications，直接放到桌面，覆盖旧的 magpie.exe
#   - 本机没有 Go 时，自动下载一份便携版到缓存目录，不装进系统
#
# 在 Git Bash 里运行（仓库自带的脚本都是 bash）。
#
# 用法：
#   ./update-windows.sh                # 检查更新，有就构建、放到桌面并启动
#   ./update-windows.sh --check        # 只看版本，不动手
#   ./update-windows.sh --force        # 已是最新版也强制重建
#   ./update-windows.sh --no-launch    # 构建并放到桌面，但不启动
#   ./update-windows.sh --tag v0.1.1599
#   ./update-windows.sh --arch arm64   # 默认 amd64
#   ./update-windows.sh --go /path/to/go[.exe]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 脚本在 <repo>/lcode/ 下，源码仓库是上一级
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PATCH="$SCRIPT_DIR/patches/0001-add-lcode-agent.patch"
BUILD_BASE="${TMPDIR:-/tmp}"
BUILD_DIR=""
WT=""
GO_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/magpie-lcode"

# 每次一个新的构建目录。用固定的 $BUILD_BASE/magpie-lcode-build 时，前一次
# 跑完残留的空 worktree 目录（被 Windows 上的资源管理器或索引器占着句柄，
# rm -rf 报 Device or resource busy）会让下一次跑直接死在 “准备构建目录”。
# 带随机后缀就永远碰不上旧的锁，旧目录由各自的清理代码自己清。
make_build_dir() {
  BUILD_DIR="$BUILD_BASE/magpie-lcode-build.$$"
  WT="$BUILD_DIR/worktree"
  mkdir -p "$BUILD_DIR"
}

CHECK_ONLY=0
FORCE=0
DO_LAUNCH=1
TAG=""
ARCH=amd64
GO="${GO_BIN:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --check)      CHECK_ONLY=1 ;;
    --force)      FORCE=1 ;;
    --no-launch)  DO_LAUNCH=0 ;;
    --tag)        shift; TAG="${1:-}" ;;
    --arch)       shift; ARCH="${1:-amd64}" ;;
    --go)         shift; GO="${1:-}" ;;
    -h|--help)    awk 'NR>1 && /^#/ {sub(/^# ?/,""); print} NR>1 && !/^#/ {exit}' "$0"; exit 0 ;;
    *) echo "未知参数: $1（-h 看用法）" >&2; exit 1 ;;
  esac
  shift
done

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *) echo "这个脚本是给 Windows 的 Git Bash 用的；macOS 请用 ./update.sh" >&2; exit 1 ;;
esac

# 路径转换：给 PowerShell/git 用 Windows 路径
winpath() { cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }

# 桌面可能在 OneDrive 下，交给 Windows 说
desktop_dir() {
  local d=""
  if command -v powershell.exe >/dev/null 2>&1; then
    d="$(powershell.exe -NoProfile -Command "[Environment]::GetFolderPath('Desktop')" 2>/dev/null | tr -d '\r' || true)"
  fi
  [ -n "$d" ] || d="$HOME/Desktop"
  cygpath -u "$d" 2>/dev/null || printf '%s' "$d"
}

DESKTOP="$(desktop_dir)"
EXE="$DESKTOP/magpie.exe"
# 之前可能从 lcode/.build 跑；版本检查两边都看
OLD_EXE="$SCRIPT_DIR/.build/magpie.exe"

installed_version() {
  local exe ver=""
  for exe in "$EXE" "$OLD_EXE"; do
    [ -x "$exe" ] || continue
    ver="$("$exe" version 2>/dev/null | awk '{print $2}' || true)"
    [ -n "$ver" ] && { printf '%s' "$ver"; return 0; }
  done
  return 1
}

# ---- 1. 查官方最新版本 ----
if [ -z "$TAG" ]; then
  echo "==> 查询官方最新 release"
  # 偶发的 TLS 抖动（schannel 关连接）让第一次查询空手，停一下重试
  for _ in 1 2 3; do
    TAG="$(curl -fsSL --max-time 25 \
          https://api.github.com/repos/yetone/magpie-releases/releases/latest 2>/dev/null \
          | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$TAG" ] && break
    sleep 2
  done
fi
[ -n "$TAG" ] || { echo "查不到官方版本，请用 --tag 指定" >&2; exit 1; }

INSTALLED="$(installed_version || true)"
[ -n "$INSTALLED" ] || INSTALLED="未安装"
echo "    官方最新: $TAG"
echo "    当前桌面: $INSTALLED"

if [ "$TAG" = "v$INSTALLED" ] && [ "$FORCE" = 0 ]; then
  echo "==> 已是最新，无需更新"
  exit 0
fi

[ "$CHECK_ONLY" = 1 ] && { echo "==> 有更新（--check 只查不动）"; exit 0; }

# ---- 2. 拉取该 tag ----
echo "==> 拉取 $TAG"
cd "$REPO_DIR"
if ! git rev-parse "$TAG" >/dev/null 2>&1; then
  # 浅克隆要够深才能拿到 tag 的历史，逐级加深
  for depth in 100 300 800; do
    if git fetch --depth "$depth" https://github.com/yetone/magpie.git "tag" "$TAG" 2>/dev/null; then
      break
    fi
  done
fi
git rev-parse "$TAG" >/dev/null 2>&1 || { echo "拉取 $TAG 失败" >&2; exit 1; }
BASE="$(git rev-parse --short "$TAG")"

# ---- 3. 在独立 worktree 里打补丁，不碰本地分支 ----
echo "==> 准备构建目录"
make_build_dir
git -C "$REPO_DIR" worktree add -q --detach "$WT" "$TAG"
cd "$WT"

if ! git apply --check "$PATCH" 2>/dev/null; then
  echo "!! 补丁与 $TAG 冲突，尝试三方合并..." >&2
  if ! git apply --3way "$PATCH"; then
    echo "" >&2
    echo "无法自动合并。冲突文件：" >&2
    git diff --name-only --diff-filter=U >&2 || true
    echo "" >&2
    echo "处理办法：" >&2
    echo "  1. cd $WT 手工解决冲突" >&2
    echo "  2. git add -A && git diff $TAG --binary > $PATCH" >&2
    echo "  3. 再跑一次 ./update-windows.sh" >&2
    exit 1
  fi
else
  git apply "$PATCH"
fi
echo "✓ 补丁已应用（基于 $TAG / $BASE）"

# ---- 4. 准备 Go ----
# 没有系统 Go 就下一份便携版，放在缓存目录，不进 PATH、不改注册表
fetch_go() {
  local json file ver sum base url
  echo "==> 本机没有 Go，下载便携版到 $GO_CACHE"
  json="$(curl -fsSL --max-time 25 "https://go.dev/dl/?mode=json" 2>/dev/null || true)"
  file="$(printf '%s' "$json" | grep -o 'go[0-9][0-9.]*\.windows-amd64\.zip' | head -1)"
  if [ -z "$file" ]; then
    echo "查不到 Go 的版本。装一个 Go，或用 --go 指定 go.exe" >&2
    exit 1
  fi
  ver="${file%.windows-amd64.zip}"
  sum="$(printf '%s' "$json" \
        | awk -v f="\"$file\"" 'index($0,f){hit=1} hit&&/"sha256"/{gsub(/[",]/,"",$2); print $2; exit}')"
  echo "    $ver（约 80 MB）"
  mkdir -p "$GO_CACHE"
  local intact=0
  if [ -n "$sum" ] && [ -f "$GO_CACHE/$file" ] \
     && printf '%s  %s\n' "$sum" "$GO_CACHE/$file" | sha256sum -c - >/dev/null 2>&1; then
    intact=1
    echo "    上次已下好，跳过下载"
  fi
  if [ "$intact" = 0 ]; then
    # -C -: 上次中断的包接着下，不用从头再来
    for base in https://mirrors.aliyun.com/golang https://go.dev/dl https://dl.google.com/go; do
      if curl -fsSL -C - --max-time 600 -o "$GO_CACHE/$file" "$base/$file" 2>/dev/null; then
        break
      fi
    done
    [ -s "$GO_CACHE/$file" ] || { echo "下载 $file 失败" >&2; exit 1; }
    if [ -n "$sum" ]; then
      if printf '%s  %s\n' "$sum" "$GO_CACHE/$file" | sha256sum -c - >/dev/null 2>&1; then
        echo "    sha256 校验通过"
      else
        rm -f "$GO_CACHE/$file"
        echo "下载的文件校验失败，已删除，再跑一次会重新下" >&2
        exit 1
      fi
    fi
  fi
  rm -rf "$GO_CACHE/go"
  if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$GO_CACHE/$file" -d "$GO_CACHE"
  else
    MAGPIE_ZIP="$(winpath "$GO_CACHE/$file")" MAGPIE_DEST="$(winpath "$GO_CACHE")" \
      powershell.exe -NoProfile -Command 'Expand-Archive -LiteralPath $env:MAGPIE_ZIP -DestinationPath $env:MAGPIE_DEST -Force'
  fi
  rm -f "$GO_CACHE/$file"
}

ensure_go() {
  if [ -n "$GO" ]; then
    [ -x "$GO" ] || { echo "--go 给的路径不可执行: $GO" >&2; exit 1; }
    return
  fi
  if command -v go >/dev/null 2>&1; then
    GO="$(command -v go)"
    return
  fi
  if [ -x "$GO_CACHE/go/bin/go.exe" ]; then
    GO="$GO_CACHE/go/bin/go.exe"
    return
  fi
  fetch_go
  GO="$GO_CACHE/go/bin/go.exe"
}

ensure_go
echo "==> Go: $("$GO" version)"

# go.mod 要求的版本比手上的新时，给一句明白话，而不是让编译报错
need="$(awk '/^go /{print $2; exit}' go.mod 2>/dev/null || true)"
have="$("$GO" env GOVERSION 2>/dev/null | sed 's/^go//' || true)"
if [ -n "$need" ] && [ -n "$have" ]; then
  if [ "$(printf '%s\n%s\n' "$need" "$have" | sort -V | head -1)" != "$need" ]; then
    echo "Go $have 比 go.mod 要求的 $need 旧；请用 --go 指定更新的 Go" >&2
    exit 1
  fi
fi

# ---- 5. 生成 Windows 资源 ----
WINVER="$(printf '%s' "$TAG" | sed -E 's/^v//; s/[^0-9.].*//')"
echo "==> 生成图标和版本资源（$WINVER）"
GOPROXY="${GOPROXY:-https://goproxy.cn,direct}" \
  "$GO" run github.com/tc-hib/go-winres@v0.3.3 make \
    --in build/windows/winres.json --arch "$ARCH" --out rsrc \
    --file-version "$WINVER" --product-version "$WINVER" 2>&1 | grep -v "go: downloading" || true
SYSO="rsrc_windows_${ARCH}.syso"
[ -f "$SYSO" ] || { echo "winres 没有生成 $SYSO" >&2; exit 1; }

# ---- 6. 编译 ----
# -buildvcs=false：上层目录若有 svn 等其它 VCS，Go 会报 "multiple VCS detected"
# -H windowsgui：GUI 子系统，双击不弹控制台（Makefile 的 release-windows 同款）
echo "==> 编译"
TMP_EXE="$BUILD_DIR/magpie.exe"
rm -f "$TMP_EXE"
CGO_ENABLED=0 GOOS=windows GOARCH="$ARCH" \
  "$GO" build -tags production -buildvcs=false -trimpath \
    -ldflags="-s -w -X main.version=$WINVER -H windowsgui" \
    -o "$TMP_EXE" . 2>&1 | grep -v "ld: warning" | grep -v "^#" || true
rm -f "$SYSO"
[ -s "$TMP_EXE" ] || { echo "编译失败" >&2; exit 1; }

# ---- 7. 验货：版本、GUI 子系统 ----
echo "==> 验证产物"
GOT="$("$TMP_EXE" version 2>/dev/null | awk '{print $2}' || true)"
[ "$GOT" = "$WINVER" ] || { echo "产物版本不对: $GOT（期望 $WINVER）" >&2; exit 1; }

SUBSYS="$(MAGPIE_EXE="$(winpath "$TMP_EXE")" powershell.exe -NoProfile -Command '
$b=[IO.File]::ReadAllBytes($env:MAGPIE_EXE)
$e=[BitConverter]::ToInt32($b,0x3C)
[BitConverter]::ToUInt16($b,$e+0x5C)
' 2>/dev/null | tr -d '\r' | tail -1 || true)"
[ "$SUBSYS" = "2" ] || { echo "产物不是 GUI 子系统（subsystem=$SUBSYS），双击会弹控制台" >&2; exit 1; }

FV="$(MAGPIE_EXE="$(winpath "$TMP_EXE")" powershell.exe -NoProfile -Command \
  '(Get-Item $env:MAGPIE_EXE).VersionInfo.FileVersion' 2>/dev/null | tr -d '\r' || true)"
[ "$FV" = "$WINVER" ] || { echo "版本资源不对: $FV（期望 $WINVER）" >&2; exit 1; }
echo "✓ 版本 $GOT，GUI 子系统，资源 $FV"

# ---- 8. 放到桌面 ----
# 两个 magpie 都监听 3425，先退掉旧进程（旧 exe 被占用时也复制不过去）
echo "==> 放到桌面: $EXE"
if command -v powershell.exe >/dev/null 2>&1; then
  powershell.exe -NoProfile -Command \
    "Get-Process -Name magpie -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue" \
    >/dev/null 2>&1 || true
else
  taskkill //IM magpie.exe //F >/dev/null 2>&1 || true
fi
sleep 2
cp -f "$TMP_EXE" "$EXE"
[ -x "$EXE" ] || { echo "复制到桌面失败" >&2; exit 1; }
echo "✓ $EXE"

# ---- 9. 启动 ----
if [ "$DO_LAUNCH" = 1 ]; then
  echo "==> 启动"
  # start 让进程脱离当前终端；失败就用资源管理器打开
  if ! cmd //c start "" "$(winpath "$EXE")" >/dev/null 2>&1; then
    explorer.exe "$(winpath "$EXE")" >/dev/null 2>&1 || true
  fi
  sleep 6
  NEW="$("$EXE" version 2>/dev/null | awk '{print $2}' || true)"
  if [ "$NEW" = "$WINVER" ]; then
    echo "✓ 已启动: magpie $NEW"
  else
    echo "!! 启动后版本不对: $NEW（期望 $WINVER）" >&2
  fi
  if curl -fsS --max-time 5 http://127.0.0.1:3425/api/hello >/dev/null 2>&1; then
    echo "✓ 网关正常"
  else
    echo "!! 网关无响应" >&2
  fi
fi

# ---- 10. 收尾 ----
# worktree 本体被 Windows 上的谁（资源管理器、索引器、杀软）占着时，
# worktree remove 删得掉 .git 却删不掉目录，下一次 rm -rf 撞它。
# 真正的记录清掉，目录清不掉就留着：下一次用新后缀，不会再碰它。
if ! git -C "$REPO_DIR" worktree remove --force "$WT" 2>/dev/null; then
  git -C "$REPO_DIR" worktree prune 2>/dev/null || true
fi
# 桌面上的那份是给人用的，构建目录里不留副本
rm -f "$TMP_EXE" 2>/dev/null || true
rm -rf "$BUILD_DIR" 2>/dev/null || true
if [ "$DO_LAUNCH" = 0 ]; then
  echo ""
  echo "产物已在桌面: $EXE"
fi

# 和 update.sh 一样，把 README 的基线版本记成这次构建的
if [ -f "$SCRIPT_DIR/README.md" ]; then
  python3 - "$SCRIPT_DIR/README.md" "$TAG" "$BASE" <<'PY' 2>/dev/null || \
  sed -i -E "s/^- 基线版本：\*\*官方 release v[0-9.]+\*\*（commit \`[0-9a-f]+\`）/- 基线版本：**官方 release $TAG**（commit \`$BASE\`）/" "$SCRIPT_DIR/README.md"
import re, sys
p, tag, base = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding="utf-8").read()
s = re.sub(r'- 基线版本：\*\*官方 release v[\d.]+\*\*（commit `[0-9a-f]+`）',
           f'- 基线版本：**官方 release {tag}**（commit `{base}`）', s)
open(p, 'w', encoding="utf-8").write(s)
PY
fi

echo ""
echo "完成：magpie $WINVER（官方 $TAG / $BASE）"
echo "桌面: $EXE"
