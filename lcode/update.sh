#!/usr/bin/env bash
# 增量更新 magpie + LCode 到官方最新 release
#
# 和 apply-lcode.sh 的区别：这个不重新克隆，走 git fetch 增量更新，速度快得多。
# 日常跟官方版本用这个；apply-lcode.sh 留着做从零重建。
#
# 用法：
#   ./update.sh               # 检查更新，有就构建并安装
#   ./update.sh --check       # 只看版本，不动手
#   ./update.sh --force       # 已是最新版也强制重建
#   ./update.sh --no-install  # 构建但不安装
#   ./update.sh --tag v0.1.1585  # 指定版本

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 脚本在 <repo>/lcode/ 下，源码仓库是上一级
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$REPO_DIR"
APP="/Applications/magpie.app"
CHECK_ONLY=0
FORCE=0
DO_INSTALL=1
TAG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --check)      CHECK_ONLY=1 ;;
    --force)      FORCE=1 ;;
    --no-install) DO_INSTALL=0 ;;
    --tag)        shift; TAG="${1:-}" ;;
    -h|--help)    awk 'NR>1 && /^#/ {sub(/^# ?/,""); print} NR>1 && !/^#/ {exit}' "$0"; exit 0 ;;
    *) echo "未知参数: $1（-h 看用法）" >&2; exit 1 ;;
  esac
  shift
done

cd "$SRC"

# ---- 1. 查官方最新版本 ----
if [ -z "$TAG" ]; then
  echo "==> 查询官方最新 release"
  TAG="$(curl -fsSL --max-time 25 \
        https://api.github.com/repos/yetone/magpie-releases/releases/latest \
        | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
fi
[ -n "$TAG" ] || { echo "查不到官方版本，请用 --tag 指定" >&2; exit 1; }

INSTALLED="$("$APP/Contents/MacOS/magpie" version 2>/dev/null | awk '{print $2}' || echo "未安装")"
echo "    官方最新: $TAG"
echo "    当前安装: $INSTALLED"

if [ "$TAG" = "v$INSTALLED" ] && [ "$FORCE" = 0 ]; then
  echo "==> 已是最新，无需更新"
  exit 0
fi

[ "$CHECK_ONLY" = 1 ] && { echo "==> 有更新（--check 只查不动）"; exit 0; }

# ---- 2. 拉取该 tag ----
# 校验用 ^{tree} 而不是 rev-parse "$TAG"：浅克隆里 tag 的 commit 对象可能到了，
# 但它 parent 的历史没到，rev-parse "$TAG" 会成功而 ^{commit} 会报
# "Needed a single revision"。构建只需要这个提交的树，tree 在就够。
echo "==> 拉取 $TAG"
have_tag() { git cat-file -e "$TAG^{tree}" 2>/dev/null; }

if ! have_tag; then
  for depth in 100 300 800 2000; do
    git fetch --depth "$depth" https://github.com/yetone/magpie.git "tag" "$TAG" 2>/dev/null || true
    have_tag && break
  done
fi
# 还不行就只取这一个提交的树（不带历史），浅克隆也能成
if ! have_tag; then
  echo "    深度拉取不够，改为只取该提交"
  git fetch --depth 1 https://github.com/yetone/magpie.git "+refs/tags/$TAG:refs/tags/$TAG" 2>/dev/null || true
fi
have_tag || { echo "拉取 $TAG 失败（拿不到它的文件树）" >&2; exit 1; }
BASE="$(git rev-parse --short "$TAG")"

# ---- 3. 在独立 worktree 里打补丁，不碰你本地分支 ----
# 之前的做法是 checkout --detach，会把 feature/lcode-agent 留在分离头状态。
# 用 worktree 就隔离了：主仓库的分支和提交完全不动。
echo "==> 准备构建目录"
WT="/tmp/magpie-lcode-build/worktree"
git worktree remove --force "$WT" 2>/dev/null || true
rm -rf "$WT"
git worktree add -q --detach "$WT" "$TAG"
cd "$WT"

if ! git apply --check "$SCRIPT_DIR/patches/0001-add-lcode-agent.patch" 2>/dev/null; then
  echo "!! 补丁与 $TAG 冲突，尝试三方合并..." >&2
  if ! git apply --3way "$SCRIPT_DIR/patches/0001-add-lcode-agent.patch"; then
    echo "" >&2
    echo "无法自动合并。冲突文件：" >&2
    git diff --name-only --diff-filter=U >&2 || true
    echo "" >&2
    echo "处理办法：" >&2
    echo "  1. cd $WT 手工解决冲突" >&2
    echo "  2. git add -A && git diff $TAG --binary > $SCRIPT_DIR/patches/0001-add-lcode-agent.patch" >&2
    echo "  3. 再跑一次 ./update.sh" >&2
    exit 1
  fi
else
  git apply "$SCRIPT_DIR/patches/0001-add-lcode-agent.patch"
fi
echo "✓ 补丁已应用（基于 $TAG / $BASE）"

# ---- 4. 编译 ----
# -buildvcs=false：上层目录若有 svn 等其它 VCS，Go 会报 "multiple VCS detected"
echo "==> 编译"
go build -tags production -buildvcs=false -trimpath \
  -ldflags="-s -w -X main.version=${TAG#v}" \
  -o "/tmp/magpie-lcode-build/magpie" . 2>&1 | grep -v "ld: warning" | grep -v "^#" || true
[ -x "/tmp/magpie-lcode-build/magpie" ] || { echo "编译失败" >&2; exit 1; }

# ---- 5. 打包 ----
echo "==> 打包"
BUNDLE="/tmp/magpie-lcode-build/magpie.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "/tmp/magpie-lcode-build/magpie" "$BUNDLE/Contents/MacOS/magpie"
cp build/darwin/magpie.icns build/darwin/Assets.car "$BUNDLE/Contents/Resources/"
sed "s/@VERSION@/${TAG#v}/" build/darwin/Info.plist > "$BUNDLE/Contents/Info.plist"
codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1
echo "✓ $BUNDLE"

# ---- 6. 安装 ----
if [ "$DO_INSTALL" = 1 ]; then
  echo "==> 安装"
  # 两个 magpie 都监听 3425，先退掉旧进程
  osascript -e 'quit app "magpie"' 2>/dev/null || true
  pkill -f "$APP/Contents/MacOS/magpie" 2>/dev/null || true
  sleep 2
  rm -rf "$APP"
  cp -R "$BUNDLE" "$APP"
  open "$APP"
  sleep 6
  NEW="$("$APP/Contents/MacOS/magpie" version 2>/dev/null | awk '{print $2}')"
  if [ "$NEW" = "${TAG#v}" ]; then
    echo "✓ 已安装并启动: magpie $NEW"
  else
    echo "!! 安装后版本不对: $NEW（期望 ${TAG#v}）" >&2
    exit 1
  fi
  if curl -fsS --max-time 5 http://127.0.0.1:3425/api/hello >/dev/null 2>&1; then
    echo "✓ 网关正常"
  else
    echo "!! 网关无响应" >&2
  fi
fi

# ---- 7. 把本地分支也同步到这个 tag ----
# 之前只在 worktree 里构建，magpie/ 的 feature/lcode-agent 一直停在旧基点上，
# 想基于最新代码改东西就会错位。这里构建成功后再 rebase 分支，保证两边一致。
if git -C "$SRC" rev-parse --verify feature/lcode-agent >/dev/null 2>&1; then
  CUR_BASE="$(git -C "$SRC" merge-base --octopus feature/lcode-agent "$TAG" 2>/dev/null || echo '')"
  if [ -n "$CUR_BASE" ] && [ "$CUR_BASE" != "$(git -C "$SRC" rev-parse "$TAG")" ]; then
    echo "==> 同步本地分支 feature/lcode-agent 到 $TAG"
    if git -C "$SRC" rebase --onto "$TAG" "$CUR_BASE" feature/lcode-agent >/dev/null 2>&1; then
      git -C "$SRC" checkout -q feature/lcode-agent 2>/dev/null || true
      echo "✓ 分支已同步: $(git -C "$SRC" log --oneline -1)"
    else
      echo "!! 分支同步失败（补丁已在 worktree 里验证过，构建不受影响）" >&2
      echo "   手工处理: cd $SRC && git rebase --onto $TAG <旧基点> feature/lcode-agent" >&2
      git -C "$SRC" rebase --abort 2>/dev/null || true
    fi
  fi
fi

# ---- 8. 收尾 ----
git -C "$SRC" worktree remove --force "/tmp/magpie-lcode-build/worktree" 2>/dev/null || true
# 装好了就清掉构建产物；--no-install 时留着，好检查
if [ "$DO_INSTALL" = 1 ]; then
  rm -rf /tmp/magpie-lcode-build
else
  echo ""
  echo "产物保留在: $SCRIPT_DIR/.build/magpie.app"
fi
if [ -f "$SCRIPT_DIR/README.md" ]; then
  python3 - "$SCRIPT_DIR/README.md" "$TAG" "$BASE" <<'PY' 2>/dev/null || true
import re, sys
p, tag, base = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
s = re.sub(r'- 基线版本：\*\*官方 release v[\d.]+\*\*（commit `[0-9a-f]+`）',
           f'- 基线版本：**官方 release {tag}**（commit `{base}`）', s)
open(p, 'w').write(s)
PY
fi

echo ""
echo "完成：magpie ${TAG#v}（官方 $TAG / $BASE）"
