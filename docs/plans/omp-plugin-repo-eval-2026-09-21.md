# 评估:CGC-2046 OMP 接入包的分发形态

日期:2026-09-21
对象:`omp-ext/cgc-2046/`(extensions/cgc-command.ts、agents/cgc.md、skills/cgc2046-onboarding/、install.sh 8.7KB、install.test.sh、docs/verify-checklist.md)

## 结论

**推荐 B'(B 的修正形态):不拆独立 repo。留在 cgc_2046,plugin 化接入包,monorepo root 加 marketplace catalog,走 OMP marketplace 分发。**

「拆独立 repo」不是 marketplace 的要求——验证结论:marketplace 原生支持 monorepo。拆 repo 的两个动机(小白 clone 门槛、发布解耦)分别被 marketplace install(用户不碰 git)和 catalog version 消解;而同 repo 恰好保住了工具名同步的 CI 优势(维度 2)。zip 托管(C)仅作为接入包未来转私有时拆公开 repo 的次优 fallback,不推荐。

用户侧从「clone 40MiB monorepo + bash install.sh」变成:

```
/marketplace add CodingGirlsClub/cgc_2046
/marketplace install cgc-2046@cgc_2046
```

## 维度 3(分叉点):monorepo 能否直接进 marketplace

**能。** `omp://marketplace.md` 证据:

- catalog 位置:git source 的 marketplace catalog 在 **repository root** 的 `.omp-plugin/marketplace.json`(或 `.claude-plugin/marketplace.json` fallback)。
- plugin source 支持相对路径:`"source": "./omp-ext/cgc-2046"`(必须 `./` 开头,在 marketplace root 内解析;可选 `metadata.pluginRoot` prepend)。
- 甚至有专为 monorepo 设计的 git-subdir source(`{"source": "git-subdir", "url": ..., "path": ..., "sha": ...}`),可从任意 monorepo 装子目录——独立 repo 从来不是前提。
- 前提条件已满足:**cgc_2046 是 public repo**(gh-axi 实测 `visibility: public`),用户无需 repo 权限即可 `/marketplace add CodingGirlsClub/cgc_2046`。
- 体积成本:pack 仅 40.24 MiB,add 时一次 clone、update 时 fetch,量级可接受。

marketplace 装的 plugin 走 `claude-plugins` discovery:skills/commands/hooks/tools/MCP 按约定目录扫描,`agents/` 进 task discovery,`package.json` 的 `omp.extensions` 进 extension loader(`omp://plugin-manager-installer-plumbing.md`)。接入包现有目录结构(`extensions/`、`skills/`、`agents/`)**已经是 plugin 约定形态**,迁移近乎声明式。

repo root 已有 `.omp/`(项目级 backend-format-gate.ts),与 `.omp-plugin/` 是不同目录,无冲突。

## 维度 1:小白安装门槛

| 形态 | 用户操作 | 评价 |
|---|---|---|
| A:clone monorepo | 装 git → clone 整个平台后端 monorepo → 找到 omp-ext/cgc-2046 → `bash install.sh install` | 最差:命令最多,clone 大 repo 慢且小白会困惑「为什么装个插件要下载整个平台源码」 |
| B:marketplace | OMP 内两条命令 | 最好:全程在 OMP 内完成,无 git、无文件系统操作;add 支持 GitHub shorthand |
| C:zip URL | 浏览器下载 → 解压 → 终端 cd 到解压目录 → `bash install.sh install` | 中下:「找下载文件 + 解压 + cd」正是小白的失足点;步骤比 A 还琐碎 |

三者共同的前置(装 OMP、browser relay 扩展、onboarding 生成 token)不变,B 把「接入包本身」的门槛降到最低。

## 维度 2:与平台 MCP server 的工具名耦合

接入包内硬编码引用(实测 grep):

- `agents/cgc.md`:7+ 个工具名作为协议文本(`list_my_workspaces`、`list_my_tasks`、`get_role_playbook`、`list_public_offerings`、`get_public_offering`、`confirm_operation`、`cancel_operation`)
- `extensions/cgc-command.ts`:连接检测前缀 `mcp__cgc_2046_` + 注入 prompt 中的工具名
- `install.sh` / `install.test.sh` / `docs/verify-checklist.md`:守门键 `tools.approval.mcp__cgc_2046_confirm_operation`

| 形态 | 同步机制 |
|---|---|
| A(同 repo 手工装) | 同 repo:平台改工具名的 PR 可同步改接入包;CI 加一致性 test(后端 MCP 工具清单 ⊇ 接入包引用的工具名)即可门禁——在既有 CI 上加一个 test 的事 |
| B'(同 repo marketplace) | **同 A 的全部优势**,发布节奏用 catalog version + deploy CI 自动 bump 解耦 |
| B(拆 repo) | 跨 repo 同步:人工对齐,或建「平台公开工具清单端点 + 接入包 CI 拉取比对」的基础设施;且一个变更变两个 PR、两套时序 |
| C(同 repo zip) | 同 A,但 zip 产物与源码 commit 无绑定,同步了也难核对用户手里是哪版 |

结论:**同 repo(A/B'/C)在同步维度优于拆 repo**;拆 repo 不是不可自动化,而是需要新建跨 repo 机制,纯增成本。工具名变更本来就要平台发版,同 repo 一个 PR 双改 + 同一 deploy 生效,时序最简单。

## 维度 4:升级路径

| 形态 | 升级方式 | 新版本感知 |
|---|---|---|
| A | git pull + 重跑 install.sh | 无,靠用户自觉(README 目前让用户跑 verify-checklist,同样无提示) |
| B' | `/marketplace update` + `omp plugin upgrade` | catalog 声明 `version` 即可比对;`marketplace.autoUpdate: notify|auto` 提供启动检查;catalog 超 24h 自动 best-effort 刷新 |
| C | 重下 zip + 解压 + 重跑 | 无,且旧 zip 残留无清理语义 |

B' 是唯一有「版本比对 + 更新提示」的形态。注意 marketplace 语义:`update` 只刷 catalog 不重装;升级靠 `upgrade`(对声明 version 的条目按 semver/不等值比对)。install 时 extension factory 有校验,失败自动回滚(`omp://plugin-manager-installer-plumbing.md`)——比 install.sh 的手工备份(`*.bak-<时间戳>`)更完整。

## 维度 5:信任模型

三种形态的信任边界**本质相同**:plugin 代码进程内执行、无沙箱,用户装包 = 信任作者;A/C 的 install.sh 同样是执行任意代码。差异在**溯源与传输**:

- A / B':代码即 git repo 内容,可审计、可 pin sha(marketplace git-subdir source 支持 sha 锁定);经 GitHub 传输。B' 额外有 catalog 元数据(name/version/author/license)和 install 时校验。
- C:zip 是 deploy CI 产物,静态托管在平台服务器——用户无法核对 zip ↔ 源码 commit(除非发布附 sha 且 install.sh 校验);信任锚从「GitHub 上的公开 repo」变成「托管服务器 + CI 管道」,供应链面更大,且小白无从审计。

对小白用户,信任实际来自「平台官方出品」这一品牌事实,三形态等同;对可审计性,B'/A ≥ C。

## B' 迁移路径与成本

1. **repo root 加 `.omp-plugin/marketplace.json`**(~30 行):

```json
{
  "name": "cgc-2046",
  "owner": { "name": "CodingGirlsClub" },
  "plugins": [
    {
      "name": "cgc-2046",
      "description": "CGC-2046 平台 OMP 接入包",
      "source": "./omp-ext/cgc-2046",
      "version": "0.1.0"
    }
  ]
}
```

2. **接入包加 `package.json`**(extensions 声明;agents/skills 走约定目录,无需声明):

```json
{
  "name": "cgc-2046",
  "version": "0.1.0",
  "omp": { "extensions": ["./extensions/cgc-command.ts"] }
}
```

3. **install.sh 瘦身**:拷贝三件套与 remove 退役(`/marketplace uninstall` 接管卸载);保留 mcp.json + config.yml merge 为薄脚本(见下方残留项),并入 onboarding 流程引导执行。install.test.sh 对应缩减。
4. **README** 安装段改为两条 marketplace 命令。
5. **CI**:后端加工具名一致性 test(MCP server 工具清单 ⊇ 接入包引用);deploy CI 可选自动 bump catalog version(升级比对依赖 version 声明)。

成本估计:1-2 天(声明文件半天、install.sh 瘦身与测试半天、CI test 看后端工具注册表是否易遍历)。

### plugin 体系不覆盖的两个残留项(保留薄脚本/onboarding 步骤)

- **mcp.json 的 cgc-2046 条目(含用户 token)**:plugin `.mcp.json` 约定是静态声明,token 由 onboarding 动态生成写入,升级不覆盖用户凭证的行为未在文档中保证——保守方案:维持现状,onboarding 写用户级 `~/.omp/agent/mcp.json`,plugin 只管代码资产。
- **config.yml 守门配置**(`tools.approval.mcp__cgc_2046_confirm_operation: prompt`,撑起原生审批框与 headless 拒绝,是安全语义):plugin 无用户级 settings 声明约定,且不建议用 extension 模拟审批框(原生 gate 在 extension 之外,更可信)——保留 merge 步骤,README 的「被设置界面覆盖后重跑恢复」指引不变。

## 风险与备注

- monorepo 做 marketplace 的代价:`/marketplace update` 拉整个 repo(40 MiB 量级,可接受);catalog version 需要随平台发版维护(CI 自动 bump 可解)。
- repo 转 private 的话 marketplace git source 不可达——届时拆**公开**独立 repo(B 真),仍优于 zip。
- OpenClacky 的 zip 渠道(backend/priv/static/ext/)是另一宿主的分发,与 OMP marketplace 并列不冲突,维持不动。
- 开发迭代用 `omp plugin link <本地路径>`,免走 marketplace 缓存。

## 证据出处

- `omp://marketplace.md`:catalog 位置(repo root)、plugin source 相对路径/git-subdir、version 比对升级、autoUpdate、安装回滚、Claude Code 格式兼容
- `omp://plugin-manager-installer-plumbing.md`:install factory 校验与回滚、约定目录扫描(skills/agents/hooks/tools/MCP、`agents/` task discovery)、`omp.extensions` 装载、link 开发流
- `omp://extension-loading.md`:plugin extension 入口解析(`omp.extensions`/`pi.extensions`,.ts/.js/.mjs/.cjs)
- 实测:repo public(gh-axi)、monorepo pack 40.24 MiB、接入包工具名硬编码分布(grep)、接入包目录结构已是 plugin 约定形态
