---
name: cgc2046-onboarding
description: 引导用户完成 CGC-2046 连接配置。当用户首次连接 CGC-2046、需要配置 MCP token、把 CGC-2046 工作台接入当前 agent，或 CGC MCP 工具调用报连接错误 / 401 时使用。流程：网站创建 token 并复制到剪贴板 → agent 用 stdin 管道命令调 connect 端点（token 不进 argv、不进会话记录）→ 验证状态。
---

# CGC-2046 连接引导

帮助用户把 CGC-2046 工作台接入本机 OpenClacky。完成后 agent 即可通过 CGC MCP 工具读写工作台。

**核心安全约束**：token 的目标落盘点只有 `~/.clacky/mcp.json`（connect 写入期间存在短暂的 0600 临时文件，原子 rename 后即清除）。OpenClacky 会把 tool arguments 全量记入会话文件（`~/.clacky/sessions/*.json`），所以 **token 绝不能出现在对话消息或工具参数里**。下面按环境给出三级通道，能走主流程就不要走 fallback。

## 主流程（剪贴板 → stdin 管道）

### 1. 让用户创建 token 并只复制到剪贴板

引导用户打开 CGC-2046 网站对应工作台的「MCP」页：

```
/w/<slug>/settings/integrations/agents/mcp
```

（`<slug>` 是用户工作台的 slug，不知道就问用户。）

在该页创建新 token 并**复制到剪贴板**。明确告诫用户：

> 请只复制，**不要把 token 粘贴到这个对话里**——对话内容会被保存。token 明文只在网站显示一次，请直接复制。

### 2. 用 stdin 管道命令调 connect（token 不进 argv、不进会话记录）

用户告知已复制后，用 terminal 工具执行固定命令（`ruby` 必有——OpenClacky 即 ruby 运行时）。

**macOS**：

```bash
pbpaste | ruby -rjson -e 'print JSON.generate({token: STDIN.read.strip})' | \
  curl -sS -X POST "http://${CLACKY_SERVER_HOST:-127.0.0.1}:${CLACKY_SERVER_PORT:-7070}/api/ext/cgc-2046/connect" \
  -H 'Content-Type: application/json' --data-binary @-
```

**Linux（X11 / Wayland）**：

```bash
(xclip -o 2>/dev/null || wl-paste) | ruby -rjson -e 'print JSON.generate({token: STDIN.read.strip})' | \
  curl -sS -X POST "http://${CLACKY_SERVER_HOST:-127.0.0.1}:${CLACKY_SERVER_PORT:-7070}/api/ext/cgc-2046/connect" \
  -H 'Content-Type: application/json' --data-binary @-
```

要点：

- token 全程经管道传递，**不出现在 argv 和命令行字面量里**，不写入会话记录；
- `JSON.generate` 负责转义，剪贴板内容含引号 / 换行也不会破坏请求；`strip` 去掉首尾空白；
- 命令输出是响应 JSON（不含 token）。

该端点会把 `mcpServers["cgc-2046"]` 条目原子化 read-merge-write 进 `~/.clacky/mcp.json`（新建文件权限 0600）并热重载 MCP registry，不影响其它已有 server 条目。

### 3. 断言连接结果

- connect 返回 `{"ok":true,...}` 才算成功；`created:true` 表示新建，`created:false` 表示更新了已有配置。
- 再确认状态：

```bash
curl -sS "http://${CLACKY_SERVER_HOST:-127.0.0.1}:${CLACKY_SERVER_PORT:-7070}/api/ext/cgc-2046/status"
```

应返回 `{"ok":true,"configured":true,"url":"..."}`。

### 4. 告诉用户可以开始

连接成功后，告知用户可以直接提问。给新用户的提示词引导（R13）——可以问：

- 「我的工作台现在是什么状态」「有哪些成员」（底层调 `get_workspace_context`、`list_members` 等工具）；
- 「最近有什么活动/课程」「<地点> 近期有什么活动」（底层调 `list_public_offerings`，公开浏览无需 workspace_id）；
- 也可以打开侧边栏「CGC 发现」面板，直接浏览公开活动与课程并跳转详情页。

同时提醒：剪贴板里的 token 被新复制内容覆盖即可，无需特殊处理。

## 备选 A（无剪贴板 CLI 时首选：临时文件管道）

若环境没有 `pbpaste` / `xclip` / `wl-paste`（如裸服务器、ssh 终端）：

1. 让用户**用自己的编辑器**把 token 写入 `~/.clacky/cgc-token.txt`，并 `chmod 600 ~/.clacky/cgc-token.txt`（token 由用户亲手落盘，不经过对话）。
2. agent 执行固定命令（读文件 → stdin 管道 → POST，成功才删除该文件）：

```bash
ruby -rjson -e 'print JSON.generate({token: File.read(ARGV[0]).strip})' ~/.clacky/cgc-token.txt | \
  curl -sS --fail-with-body -X POST "http://${CLACKY_SERVER_HOST:-127.0.0.1}:${CLACKY_SERVER_PORT:-7070}/api/ext/cgc-2046/connect" \
  -H 'Content-Type: application/json' --data-binary @- && \
  ruby -e 'File.delete(ARGV[0])' ~/.clacky/cgc-token.txt
```

3. `--fail-with-body` 保证 HTTP 层失败（4xx/5xx）时 curl 退出码非 0（body 仍打印便于诊断），网络失败同样非 0——这两种情况文件都保留、修好后重跑同一条命令即可；只有成功才删除。删除用 ruby `File.delete` 而不用 `rm`：OpenClacky ≥1.5.6 的 terminal 工具会把 `rm` 拦截改送 trash，token 文件会长期留在回收站。
4. 继续主流程第 3 步断言。token 同样不进对话 / argv / 会话记录。

## 备选 B（最后手段：对话粘贴）

仅在主流程与备选 A 都不可用时，允许用户在对话里粘贴 token，agent 再放进 curl 参数。**必须事先明示代价**：

> 这种方式 token 会留在本机会话记录文件里。建议连接完成后回到 MCP 页**撤销这个 token**，然后改用剪贴板管道（主流程）或临时文件管道（备选 A）重签一个并完成连接——新通道不留痕，补救真实有效。

## 纪律

- token 的目标落盘点只有 `~/.clacky/mcp.json`（写入期间有短暂 0600 临时文件）；agent 不得主动把 token 写进任何其它文件或日志。
- 用户没给 token 时**不要编造**；connect 返回 422 就说明 token 缺失或格式不对，如实告诉用户。
- token 明文只在网站创建时显示一次；用户弄丢了就让他回 MCP 页撤销旧 token、重新签一个。
