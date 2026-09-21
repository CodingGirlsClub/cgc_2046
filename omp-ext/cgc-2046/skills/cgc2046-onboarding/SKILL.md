---
name: cgc2046-onboarding
description: 首次连接 CGC-2046、MCP 连接错误/401、或需要把工作台接入当前 OMP 会话时使用。首选路径：OMP browser relay 接管用户已登录的 Chrome，自动签发 token、写入 mcp.json 并验证；relay 不可用或未登录时回退手工 token 流程。
---

# CGC-2046 连接引导（OMP）

帮助用户把 CGC-2046 工作台接入本机 OMP。完成后 agent 即可通过 CGC MCP 工具读写工作台。

**核心安全约束**：token 的目标落盘点只有 `~/.omp/agent/mcp.json`（写入期间存在短暂的 0600 临时文件，原子 rename 后即清除）。OMP 会把 tool arguments 全量记入会话文件，所以 **token 绝不能出现在对话消息或工具参数里**。优先使用 relay 自动连接；只有 relay 不可用或未登录时才进入手工 fallback。

## 首选路径：relay 自动连接

用户已装 OMP 接入包后，对 agent 说「连接 CGC」或「连接网站」。agent 按本节完成全流程。用户不需要先打开 MCP 页、创建 token 或复制 token。

1. **检查 relay 前置**：确认用户 Chrome 已装 OMP browser relay 扩展（`omp browser-relay install` 落盘到 `~/.omp/browser-relay/extension`，用户需在 Chrome 手动加载 unpacked 扩展——该命令只落盘，不自动注入 Chrome）。未装则引导用户先装，装完重试。
2. **接管真实浏览器**：用 OMP 内置 `browser` 工具（`app.relay: true`）接管用户已登录的 Chrome，打开 CGC 工作台 MCP 页（`/w/<slug>/settings/integrations/agents/mcp`，`<slug>` 是用户工作台的 slug，不知道就问用户）。必须接管用户日常浏览器，以复用登录态；不要要求用户手动开启 remote debugging。
3. **处理登录态**：如果页面在登录页，告诉用户"请在刚打开的浏览器里登录 CGC，登录完成后告诉我继续"。不要代填密码或验证码。用户确认后重新检查页面。
4. **自动签发**：登录成功后，只撤销名称以 `omp-auto-` 开头的旧自动 token，保留用户手动创建的 token；签发新的 `omp-auto-<YYYYMMDD>` token。
5. **安全复制**：点击一次性 token 的复制按钮，但不要读取、打印或转述明文；直接把剪贴板通过 stdin 管道交给写入命令（见下方「写入并验证」）。
6. **写入并验证**：用剪贴板管道把 token 写入 `~/.omp/agent/mcp.json` 的 `mcpServers["cgc-2046"]` 条目（read-merge-write，临时文件 + chmod 600 + 原子替换，保留其他 server 与未知字段），再通过 OMP `/mcp test cgc-2046` 或等效 initialize + tools/list 探测做真实连接检查。只有握手成功才向用户报告完成。
7. **写入守门配置**：握手成功后，执行下方「写入守门配置」节的命令并同样验证（调一次 confirm 类工具确认弹审批框）。
8. **恢复策略**：浏览器登录失败、用户取消或连接检查失败时，保留可重试状态，说明具体下一步；不要让用户回网站手工配置，除非自动路径确实不可用。

## 备用路径：手工 token（仅自动连接不可用时）

### 1. 让用户创建 token 并只复制到剪贴板

引导用户打开 CGC-2046 网站对应工作台的「MCP」页：

```
/w/<slug>/settings/integrations/agents/mcp
```

（`<slug>` 是用户工作台的 slug，不知道就问用户。）

在该页创建新 token 并**复制到剪贴板**。明确告诫用户：

> 请只复制，**不要把 token 粘贴到这个对话里**——对话内容会被保存。token 明文只在网站显示一次，请直接复制。

### 2. 用 stdin 管道命令写入 mcp.json（token 不进 argv、不进会话记录）

用户告知已复制后，用 terminal 工具执行固定命令（`jq` 或 `python3` 必有——OMP 生态常见）。

**macOS**：

```bash
mkdir -p ~/.omp/agent && \
pbpaste | python3 -c '
import json, sys, os, tempfile
token = sys.stdin.read().strip()
import re
if not token or not re.fullmatch(r'cgc_[A-Za-z0-9_-]+', token):
    print("ERROR: clipboard does not contain a valid token — nothing was written; re-copy the token from the MCP page", file=sys.stderr)
    sys.exit(1)
path = os.path.expanduser("~/.omp/agent/mcp.json")
config = {}
if os.path.exists(path):
    with open(path) as f:
        config = json.load(f)
config.setdefault("mcpServers", {})["cgc-2046"] = {
    "type": "http",
    "url": "https://api.codingirlsclub.com/mcp",
    "headers": {"Authorization": f"Bearer {token}"}
}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".mcp.json.", text=True)
try:
    with os.fdopen(fd, "w") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
except Exception:
    os.unlink(tmp)
    raise
print("OK: cgc-2046 entry written to ~/.omp/agent/mcp.json")
'
```

**Linux（X11 / Wayland）**：把 `pbpaste` 换成 `xclip -o 2>/dev/null || wl-paste`，其余相同。

要点：

- token 全程经管道传递，**不出现在 argv 和命令行字面量里**，不写入会话记录；
- `json.dump` 负责转义，剪贴板内容含引号 / 换行也不会破坏 JSON；`strip` 去掉首尾空白；
- **token 形态前置断言**：python 段在写文件前校验输入非空且为字母数字+连字符+下划线——不匹配即报错退出，**mcp.json 不会被写入**。用户剪贴板里常是误复制的整段对话/表格文本，没有这层断言时会被原样写进 Authorization 头造成静默坏连接。断言失败时**不要把剪贴板内容粘进对话诊断**，让用户回 MCP 页重新复制即可；
- 命令输出是 "OK" 或错误消息（不含 token）。

该命令把 `mcpServers["cgc-2046"]` 条目原子化 read-merge-write 进 `~/.omp/agent/mcp.json`（新建文件权限 0600），不影响其它已有 server 条目。

### 3. 断言连接结果

- 写入成功后，在 OMP 里跑 `/mcp test cgc-2046` 或等效 initialize + tools/list 探测。
- 握手成功（工具列表返回）才算连接建立；失败则检查 token 是否过期/撤销、URL 是否正确。

### 4. 写入守门配置（安全闸）

连接成功后，写入确认守门配置——`confirm_operation` 每次调用弹 OMP 原生审批框，用户批准才执行：

```bash
python3 -c '
import os, re, tempfile

path = os.path.expanduser("~/.omp/agent/config.yml")
GUARD_KEY = "mcp__cgc_2046_confirm_operation"
GUARD_LINE = f"    {GUARD_KEY}: prompt"

lines = []
if os.path.exists(path):
    with open(path) as f:
        lines = f.readlines()

content = "".join(lines)
if GUARD_KEY in content:
    print("OK: guard config already present")
    raise SystemExit(0)

tools_idx = None
approval_idx = None
for i, line in enumerate(lines):
    if re.match(r"^tools:\s*$", line):
        tools_idx = i
    if tools_idx is not None and re.match(r"^  approval:\s*$", line):
        approval_idx = i
        break

if approval_idx is not None:
    lines.insert(approval_idx + 1, GUARD_LINE + "\n")
elif tools_idx is not None:
    lines.insert(tools_idx + 1, "  approval:\n")
    lines.insert(tools_idx + 2, GUARD_LINE + "\n")
else:
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    lines.append("\ntools:\n")
    lines.append("  approval:\n")
    lines.append(GUARD_LINE + "\n")

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".config.yml.", text=True)
try:
    with os.fdopen(fd, "w") as f:
        f.writelines(lines)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
except Exception:
    os.unlink(tmp)
    raise

print("OK: guard config written to ~/.omp/agent/config.yml")
'
```

验证：调一次 confirm 类工具（如 `confirm_operation`）确认弹审批框。若未弹框，检查 `~/.omp/agent/config.yml` 是否被 OMP 设置界面重写；恢复方法见 README。

### 5. 告诉用户可以开始

连接成功后，告知用户可以直接提问。自动连接完成后，给新用户的提示词引导——可以问：

- 「我的工作台现在是什么状态」「有哪些成员」（底层调 `get_workspace_context`、`list_members` 等工具）；
- 「最近有什么活动/课程」「<地点> 近期有什么活动」（底层调 `list_public_offerings`，公开浏览无需 workspace_id）；
- 也可以输入 `/cgc` 查看连接状态、待办与可进入角色。

同时提醒：剪贴板里的 token 被新复制内容覆盖即可，无需特殊处理。

## 备用路径 A（无剪贴板 CLI 时：临时文件管道）

若环境没有 `pbpaste` / `xclip` / `wl-paste`（如裸服务器、ssh 终端）：

1. 让用户**用自己的编辑器**把 token 写入 `~/.omp/agent/cgc-token.txt`，并 `chmod 600 ~/.omp/agent/cgc-token.txt`（token 由用户亲手落盘，不经过对话）。
2. agent 执行固定命令（读文件 → stdin 管道 → 写入 mcp.json，成功才删除该文件）：

```bash
mkdir -p ~/.omp/agent && \
python3 -c '
import json, sys, os, tempfile
token_path = os.path.expanduser("~/.omp/agent/cgc-token.txt")
with open(token_path) as f:
    token = f.read().strip()
import re
if not token or not re.fullmatch(r'cgc_[A-Za-z0-9_-]+', token):
    print("ERROR: ~/.omp/agent/cgc-token.txt does not contain a valid token — nothing was written", file=sys.stderr)
    sys.exit(1)
path = os.path.expanduser("~/.omp/agent/mcp.json")
config = {}
if os.path.exists(path):
    with open(path) as f:
        config = json.load(f)
config.setdefault("mcpServers", {})["cgc-2046"] = {
    "type": "http",
    "url": "https://api.codingirlsclub.com/mcp",
    "headers": {"Authorization": f"Bearer {token}"}
}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".mcp.json.", text=True)
try:
    with os.fdopen(fd, "w") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
except Exception:
    os.unlink(tmp)
    raise
os.unlink(token_path)
print("OK: cgc-2046 entry written, token file removed")
'
```

3. 只有成功才删除 token 文件；失败（网络、断言、写入错误）时文件保留、修好后重跑同一条命令即可。
4. 继续备用路径第 3 步断言。token 同样不进对话 / argv / 会话记录。自动路径完成后不需要用户重复执行此 fallback。

## 备用路径 B（最后手段：对话粘贴）

仅在主流程与备选 A 都不可用时，允许用户在对话里粘贴 token，agent 再放进写入命令。agent 在写入前先做同样的形态校验（`re.fullmatch(r'cgc_[A-Za-z0-9_-]+', token)`，不匹配就请用户重新粘贴，绝不带着可疑内容写入）。**必须事先明示代价**：

> 这种方式 token 会留在本机会话记录文件里。建议连接完成后回到 MCP 页**撤销这个 token**，然后改用剪贴板管道（主流程）或临时文件管道（备选 A）重签一个并完成连接——新通道不留痕，补救真实有效。

## 项目级开发场景（cgc_2046 仓库内）

在 cgc_2046 仓库内开发时，可用项目级 `.omp/mcp.json`（dev URL `http://localhost:4000/mcp`）替代用户级配置。其余流程相同，只是落盘路径与 URL 不同。

## 故障处理

遇到浏览器 target 崩溃、连接失败或用户取消时，保留可重试状态并报告下一步；不要跳过安全验证，也不要要求用户把 token 粘贴到对话中。

**撤销旧 token 时精确定位卡片**：撤销按钮在每张 token 卡片内，按按钮文本找会误点其他卡片（真实事故：`dsh-auto-20260909` 被误撤销）。正确定位方式：先按 token 名称（`omp-auto-*`）找到卡片容器，再在卡片内找撤销按钮。撤销前确认卡片名称匹配目标命名。

## 纪律

- token 的目标落盘点只有 `~/.omp/agent/mcp.json`（写入期间有短暂 0600 临时文件）；agent 不得主动把 token 写进任何其它文件或日志。
- 用户没给 token 时**不要编造**；写入失败或握手失败就说明 token 缺失、过期或格式不对，如实告诉用户。
- token 明文只在网站创建时显示一次；用户弄丢了就让他回 MCP 页撤销旧 token、重新签一个。
- **签发后页面会渲染 token 明文**——任何 `document.body.innerText` / page text dump / DOM 读取都会把它带进会话记录（OMP 把 tool arguments 全量记入会话文件）。签发后**只能点复制按钮**（返回 `{clicked: true}` 即可），**不能读页面文本**。若 token 已泄漏到会话记录，立即撤销该 token 并重签一个干净的——泄漏的 token 已污染，不能写入 mcp.json。
- **验证连接只看 MCP 握手/工具调用结果，禁止 read mcp.json**——agent 验证连接时会读 `~/.omp/agent/mcp.json` 把 token 拉进会话记录（与 page text dump 同类事故）。连接状态的唯一可信来源是 MCP 握手（`/mcp test` 或工具调用结果），不是配置文件内容。
