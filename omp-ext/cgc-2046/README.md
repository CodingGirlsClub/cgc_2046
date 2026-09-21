# omp-ext/cgc-2046

CGC-2046 平台的 OMP（oh-my-pi）接入包。安装后，平台四类角色（平台管理员、Workspace Owner/Admin、Tutor、Learner）可在 OMP 终端里通过 MCP 完成 OpenClacky 宿主所支持的全部平台操作。

## 前置

1. **安装 OMP**：见 [oh-my-pi](https://github.com/oh-my-pi/oh-my-pi) 官方安装指引。
2. **安装 browser relay 扩展**（自动连接需要，一次性）：
   ```bash
   omp browser-relay install
   ```
   然后在 Chrome 手动加载 unpacked 扩展：打开 `chrome://extensions/` → 开启「开发者模式」→「加载已解压的扩展程序」→ 选 `~/.omp/browser-relay/extension`。
   > 该命令只落盘扩展，不自动注入 Chrome。

## 三步接入

```bash
# 1. 克隆本仓库（或下载 omp-ext/cgc-2046/ 目录）
git clone https://github.com/CodingGirlsClub/cgc_2046.git
cd cgc_2046

# 2. 安装接入包
bash omp-ext/cgc-2046/install.sh install

# 3. 启动 OMP，对 agent 说「连接 CGC」
omp
```

连接完成后，输入 `/cgc` 查看状态、待办与可进入角色。

## 安装内容

| 文件 | 落盘位置 | 作用 |
| --- | --- | --- |
| `agents/cgc.md` | `~/.omp/agent/agents/cgc.md` | 主 agent（入口协议 + 纪律，角色方法论来自网站 playbook 动态拉取） |
| `skills/cgc2046-onboarding/SKILL.md` | `~/.omp/agent/skills/cgc2046-onboarding/SKILL.md` | 连接引导（自动/手工） |
| `extensions/cgc-command.ts` | `~/.omp/agent/extensions/cgc-command.ts` | `/cgc` 斜杠命令（状态/待办/角色/快捷操作） |
| — | `~/.omp/agent/mcp.json` | merge 写入 `cgc-2046` MCP server 条目（0600） |
| — | `~/.omp/agent/config.yml` | merge 写入守门配置（`confirm_operation` 弹原生审批框） |

## 故障恢复

| 症状 | 处理 |
| --- | --- |
| 工具调用 401 / 连接错误 | token 过期或未配置——对 agent 说「连接 CGC」重跑 onboarding |
| relay 自动连接失败 | 确认 Chrome 已装 relay 扩展；或回退手工 token 流程（onboarding skill 有指引） |
| 健康检查失败 | 检查 `~/.omp/agent/mcp.json` 的 URL 与 token；跑 `/mcp test cgc-2046` 看具体错误 |
| 守门配置被覆盖 | OMP 设置界面重写 `config.yml` 可能覆盖 merge 结果——重跑 `install.sh install` 恢复，或手动加回 `tools.approval.mcp__cgc_2046_confirm_operation: prompt` |
| 卸载 | `bash omp-ext/cgc-2046/install.sh remove`（只删本包文件与条目，保留备份） |

## 开发场景（cgc_2046 仓库内）

在 cgc_2046 仓库内开发时，可用项目级配置替代用户级：

```bash
bash omp-ext/cgc-2046/install.sh install --url http://localhost:4000/mcp
```

或在仓库根目录建 `.omp/mcp.json`（dev URL），其余流程相同。

## 安全边界

- token 只落 `~/.omp/agent/mcp.json`（0600），不进对话、日志、其他文件
- 高风险写操作（退款、审批、发布等）走 two-tool 确认流：业务工具建 pending → agent 复述摘要 → `ask` 用户点选 → `confirm_operation` 触发 OMP 原生审批框 → 用户批准才落库
- headless 子代理中 `confirm_operation` 被直接拒绝（比 OpenClacky 守门的 headless 放行更强）

## 最低 OMP 版本

本接入包验证时的 OMP 版本：____（实现时回填）。升级 OMP 后请重跑 `omp-ext/cgc-2046/docs/verify-checklist.md`。

## FAQ

**Q: 我需要装 OpenClacky 吗？**
A: 不需要。OMP 接入包是独立的第二宿主，与 OpenClacky 并列共存。

**Q: 角色切换要重开 agent 吗？**
A: 不用。对 agent 说「切换到 Tutor 角色」即可，agent 会重新拉取对应 playbook。

**Q: 长任务（教研/学习）能看到进度吗？**
A: 能。agent 进入长任务时会用 `todo` 建任务清单，每完成一步更新状态。

**Q: 跨会话能记住我的常用 workspace 吗？**
A: 能。开 `memory.backend: local`（见 OMP 文档），agent 会记住常用 workspace 与上次角色。
