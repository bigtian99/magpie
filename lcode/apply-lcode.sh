#!/usr/bin/env bash
# 一键把 LCode adapter 重新打回 magpie 源码，并编译打包成 magpie-lcode.app
#
# 用法：
#   ./apply-lcode.sh                  # 在已有的源码目录里打补丁并构建
#   ./apply-lcode.sh --fresh          # 拉官方最新 release 再打补丁（官方发新版后用这个）
#   ./apply-lcode.sh --patch-only     # 只打补丁，不构建
#   ./apply-lcode.sh --install        # 构建后装到 /Applications
#
# 设计说明：
#   - 补丁以 git apply 应用，二进制文件（图标 PNG）用 --binary 编码在内
#   - 上游更新后若补丁冲突，脚本会打印冲突文件，可用 --3way 让它尝试三方合并
#   - 每次运行都记录 base commit，方便判断补丁是基于哪个版本写的

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$SCRIPT_DIR/patches/0001-add-lcode-agent.patch"
# 克隆到临时目录，不污染仓库工作区
SRC="${MAGPIE_SRC:-/tmp/magpie-lcode-fresh/magpie}"
APP_NAME="magpie-lcode"
FRESH=0
PATCH_ONLY=0
INSTALL=0

for arg in "$@"; do
  case "$arg" in
    --fresh)      FRESH=1 ;;
    --patch-only) PATCH_ONLY=1 ;;
    --install)    INSTALL=1 ;;
    -h|--help)    awk 'NR>1 && /^#/ {sub(/^# ?/,""); print} NR>1 && !/^#/ {exit}' "$0"; exit 0 ;;
    *) echo "未知参数: $arg（-h 看用法）" >&2; exit 1 ;;
  esac
done

[ -f "$PATCH" ] || { echo "找不到补丁: $PATCH" >&2; exit 1; }

# ---- 0. 确定要构建的官方版本 ----
# 版本以官网 release 为准，不跟 main 分支：main 上的提交可能未发布，
# 拿它构建出来的东西和官方下载的对不上，出问题也不好复现。
if [ -z "${MAGPIE_TAG:-}" ]; then
  TAG="$(curl -fsSL --max-time 20 https://api.github.com/repos/yetone/magpie-releases/releases/latest \
        | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  TAG="${TAG:-v0.1.1546}"
else
  TAG="$MAGPIE_TAG"
fi
echo "==> 目标官方版本: $TAG（MAGPIE_TAG 可覆盖）"

# ---- 1. 准备源码 ----
if [ "$FRESH" = 1 ]; then
  # 安全措施：删目录前先看有没有未提交的改动，有就备份，绝不让用户的手工修改无声消失
  if [ -d "$SRC/.git" ] && [ -n "$(git -C "$SRC" status --porcelain 2>/dev/null)" ]; then
    BACKUP="$SRC.bak-$(date +%Y%m%d-%H%M%S)"
    echo "==> 警告：$SRC 有未提交的改动，先备份到 $BACKUP"
    mv "$SRC" "$BACKUP"
    echo "    确认没用后可删：rm -rf \"$BACKUP\""
  else
    rm -rf "$SRC"
  fi
  echo "==> 克隆官方最新 release $TAG 到 $SRC"
  git clone --depth 1 --branch "$TAG" https://github.com/yetone/magpie.git "$SRC"
elif [ ! -d "$SRC/.git" ]; then
  echo "==> $SRC 不是 git 仓库，克隆官方最新 release $TAG"
  git clone --depth 1 --branch "$TAG" https://github.com/yetone/magpie.git "$SRC"
fi

cd "$SRC"
BASE="$(git rev-parse --short HEAD)"
echo "==> 源码 HEAD: $BASE"

# 已被打过补丁就跳过，避免重复应用报错
if [ -f internal/agent/lcode.go ]; then
  echo "==> LCode adapter 已存在，跳过打补丁"
else
  echo "==> 应用补丁"
  if ! git apply --check "$PATCH" 2>/dev/null; then
    echo "!! 补丁与当前源码冲突（上游可能改动了相关文件），尝试三方合并..." >&2
    if ! git apply --3way "$PATCH"; then
      echo "" >&2
      echo "三方合并也失败。冲突文件：" >&2
      git diff --name-only --diff-filter=U >&2 || true
      echo "" >&2
      echo "处理办法：手工改完这些文件后重新生成补丁（见 README.md 的“上游更新后”一节）" >&2
      exit 1
    fi
  else
    git apply "$PATCH"
  fi
  echo "✓ 补丁已应用"
fi

[ "$PATCH_ONLY" = 1 ] && { echo "==> --patch-only：到此为止"; exit 0; }

# ---- 2. 构建 ----
# -buildvcs=false：上层目录若有 svn 等其它 VCS，Go 会报 "multiple VCS detected"
echo "==> 编译"
go build -tags production -buildvcs=false -trimpath \
  -ldflags="-s -w -X main.version=${TAG#v}" \
  -o "$SRC/$APP_NAME" . 2>&1 | grep -v "ld: warning" | grep -v "^#" || true

[ -x "$SRC/$APP_NAME" ] || { echo "编译失败" >&2; exit 1; }

# ---- 3. 打包成 .app ----
echo "==> 打包 $APP_NAME.app"
rm -rf "$SRC/$APP_NAME.app"
mkdir -p "$SRC/$APP_NAME.app/Contents/MacOS" "$SRC/$APP_NAME.app/Contents/Resources"
cp "$SRC/$APP_NAME" "$SRC/$APP_NAME.app/Contents/MacOS/magpie"
cp build/darwin/magpie.icns "$SRC/$APP_NAME.app/Contents/Resources/"
cp build/darwin/Assets.car   "$SRC/$APP_NAME.app/Contents/Resources/"
sed "s/@VERSION@/${TAG#v}/" build/darwin/Info.plist \
  > "$SRC/$APP_NAME.app/Contents/Info.plist"
codesign --force --deep --sign - "$SRC/$APP_NAME.app" 2>&1 | sed 's/^/    /'
echo "✓ $SRC/$APP_NAME.app（基于官方 $TAG / $BASE）"

# ---- 4. 可选安装 ----
if [ "$INSTALL" = 1 ]; then
  echo "==> 安装到 /Applications"
  # 两个 magpie 都监听 3425，同时运行会端口冲突
  if pgrep -f "/Applications/magpie.app/Contents/MacOS/magpie" >/dev/null 2>&1; then
    echo "    官方 magpie 正在运行，先退出它"
    osascript -e 'quit app "magpie"' 2>/dev/null || pkill -f "/Applications/magpie.app/Contents/MacOS/magpie" || true
    sleep 2
  fi
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$SRC/$APP_NAME.app" "/Applications/$APP_NAME.app"
  echo "✓ 已安装：open /Applications/$APP_NAME.app"
fi

echo ""
echo "完成。基于官方 magpie $TAG（commit $BASE）。"
echo "  LCode 接回：magpie lcode provider magpie"
echo "  断开：      magpie lcode default"
