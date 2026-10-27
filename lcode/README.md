# magpie + LCode adapter

给 [yetone/magpie](https://github.com/yetone/magpie) 加一个 **LCode** 的 agent adapter，
让 LCode 出现在 magpie 的 Agents 页面，并能从那里选 magpie 的模型。

- 补丁：`patches/0001-add-lcode-agent.patch`
- 一键脚本：`apply-lcode.sh`
- 基线版本：**官方 release v0.1.1692**（commit `353519f5`）

## 为什么能这么做

**LCode 是 ZCode 的 fork**，两者的配置文件逐一对应：

| ZCode | LCode |
|---|---|
| `~/.zcode/v2/config.json` | `~/.lcode/v2/config.json` |
| `~/.zcode/v2/provider_config.json` | `~/.lcode/v2/provider_config.json` |

magpie 源码里已经有完整的 `zcode.go`（642 行），它把 ZCode 的两套配置格式都实现了
（老版的 `config.json` provider 写法 + 3.14 起的 `provider_config.json` 规则写法）。
所以 LCode 的 adapter 不是从零写，而是**复制 zcode.go 改造成 lcode.go**，
复用了其中全部逻辑：规则合并、格式转换、原生联网搜索、stash 存还原、跨机器地址保留等。

## 版本原则（重要）

**始终跟随官方 release 打补丁，不跟 `main` 分支。**

magpie 的 main 上有未发布的提交，用 main 构建出来的东西和官网下载的
版本对不上——出了问题既不好排查，也不好判断是上游的 bug 还是补丁引入的。
脚本默认用 GitHub API 取官方最新 release tag 再 clone，所以构建出的
`magpie 0.1.1546` 和官网下的是同一份代码，只多了 LCode adapter。

想指定别的官方版本时：

```bash
MAGPIE_TAG=v0.1.1540 ./apply-lcode.sh --fresh
```

## 改动清单（6 个文件）

```
M internal/agent/agents.go            +1 行    在 All() 里注册 lcode(home)
M internal/gui/assets/app.js          ~1 行    pngIcons 名单加 "lcode"（否则图标找 .svg 变空白）
M internal/gui/assets/i18n.js         +5 行    4 种语言翻译 + NOTICES 注册
A internal/agent/lcode.go             新增     adapter 本体（约 630 行，源自 zcode.go）
A internal/appdir/lcode.go            新增     LCodeHomeOn（Windows 上 HOME 优先于 USERPROFILE）
A internal/gui/assets/icons/lcode.png 新增     图标，取自 LCode.app 的 icon.png 缩放到 128×128
```

### lcode.go 与 zcode.go 的实际差异

只有这几处，其余逻辑完全相同：

1. **目录推导**：LCode 没有 ZCode 的「数据存储路径」(`dataBaseDir`) 设置，
   固定读 `~/.lcode`，所以不需要 `LCodeDataIn` 那层间接。
2. 标识符 `zcode*` → `lcode*`（22 个函数/变量）。
3. `ID: "lcode"`、`Name: "LCode"`、`UA: ["lcode"]`、`Aliases: ["l-code"]`、`Icon: "lcode"`。
4. 删掉重复的 `onAnotherMachine`（与 zcode.go 完全相同，共用一份）。
5. 提示语 `noticeLcode`（LCode 启动时读配置，改完需重启）。

## 日常更新（推荐）

官方迭代很快，日常跟进用 `update.sh`，它走增量 fetch，比重建快得多：

```bash
./update.sh              # 检查更新，有就构建并安装
./update.sh --check      # 只看版本，不动手
./update.sh --force      # 已是最新也强制重建
./update.sh --no-install # 构建但不安装（产物留在 .build/）
./update.sh --tag v0.1.1585   # 指定版本
```

它会自动：查官方最新 release → `git fetch` 增量拉取 → **在独立 worktree 里**打补丁
→ 编译 → 打包签名 → 退出旧进程 → 安装启动 → 验证版本和网关。

用 worktree 是为了不碰 `magpie/` 里的本地分支：跑完 `feature/lcode-agent` 保持原样，
不会留在 detached HEAD 状态。

补丁冲突时会打印冲突文件并停下，不会产生半个构建。处理办法见下方。

## 从零重建

`apply-lcode.sh` 用于全新环境或需要重来时（会重新克隆约 200MB）：

```bash
./apply-lcode.sh --fresh --install
```

## 使用

```bash
# 接上（LCode 需要重启才看到 magpie 的模型）
/Applications/magpie-lcode.app/Contents/MacOS/magpie lcode provider magpie

# 断开，还原成接入前的样子
/Applications/magpie-lcode.app/Contents/MacOS/magpie lcode default

# 看当前状态
/Applications/magpie-lcode.app/Contents/MacOS/magpie ls
```

> LCode 的模型在 **LCode 自己的模型选择器**里选，不在 magpie 里选。
> magpie 做的是把模型清单写进 LCode 的两个配置文件。

## 重建 / 上游更新后

```bash
# 官方发新版：拉那个 release 的源码，重新打补丁 + 构建 + 打包
./apply-lcode.sh --fresh

# 拉官方最新 release + 构建 + 直接装到 /Applications
./apply-lcode.sh --fresh --install

# 用本地已有的源码目录，只打补丁不构建
./apply-lcode.sh --patch-only
```

脚本会自动：
- 用 `git apply` 打补丁，冲突时先尝试 `git apply --3way`
- 已打过补丁则跳过，不重复应用
- `-buildvcs=false` 编译（否则上层有 svn 等目录会报 `multiple VCS detected`）
- 打包成 `.app` 并 ad-hoc 签名
- 版本号带上 base commit（如 `lcode-39fed47`），方便追溯

### 补丁冲突了怎么办

上游若改动了这几个文件，`--3way` 也可能失败。处理步骤：

```bash
cd magpie
git apply --3way ../patches/0001-add-lcode-agent.patch   # 看冲突
# 手工解决冲突后：
git add -A
git diff HEAD --binary > ../patches/0001-add-lcode-agent.patch   # 重新生成补丁
```

`lcode.go` 因为是独立新文件，只要上游不改 `agent.Agent` 结构体接口就不会冲突。
真正容易冲突的是 `agents.go`（一行注册）和 `app.js`（pngIcons 名单）。

## 已验证的行为

| 项目 | 结果 |
|---|---|
| LCode 被识别 | `LCode  provider magpie  ~/.lcode/v2/config.json` |
| 模型写入 | 14 个模型写入 `config.json` + `provider_config.json` |
| 断开还原 | 两个文件**字节级完全一致** |
| 图标接口 | `HTTP 200 image/png`，9394 字节，与 ZCode 图标不同 |
| 网关连通 | `zcode/GLM-5.3` 经 magpie 返回正常文本 |
| 测试套件 | `go test ./internal/agent/` 全部通过 |
| 补丁自包含 | 全新 clone 上干净应用并编译通过 |

## 注意事项

- **两个 magpie 不能同时运行**：官方 `magpie.app` 和 `magpie-lcode.app` 都监听
  `127.0.0.1:3425`，切换前先退出一个。
- **LCode 启动时读配置**，改完必须重启 LCode 才生效。
- **给上游提 PR 的话**，按 `docs/integrating.md` 的要求还得补
  `internal/agent/lcode_test.go`（临时 HOME 下测 connect/switch/disconnect），
  并把 LCode 加进 `docs/reference.md` 的 Agents 表。本仓库只用于自用构建，没写测试。
