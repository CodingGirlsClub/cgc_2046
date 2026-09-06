---
name: cgc2046-onboarding
description: 引导用户完成 CGC-2046 连接配置。当用户首次连接 CGC-2046、点击 CGC OpenClacky 面板「连接网站」、需要把工作台接入当前 agent，或 CGC MCP 工具调用报连接错误 / 401 时使用。首选流程：由 CGC-2046 面板创建连接会话，助手用宿主 browser/CDP 引导用户登录 CGC 网站、自动签发 token、写入 mcp.json 并验证 MCP；网站 token + 剪贴板管道仅作为 fallback。
---

# CGC-2046 连接引导

帮助用户把 CGC-2046 工作台接入本机 OpenClacky。完成后 agent 即可通过 CGC MCP 工具读写工作台。

**核心安全约束**：token 的目标落盘点只有 `~/.clacky/mcp.json`（connect 写入期间存在短暂的 0600 临时文件，原子 rename 后即清除）。OpenClacky 会把 tool arguments 全量记入会话文件（`~/.clacky/sessions/*.json`），所以 **token 绝不能出现在对话消息或工具参数里**。优先使用面板触发的自动连接；只有宿主能力不可用时才进入手工 fallback。

## 首选路径：面板一键连接（CGC OpenClacky）

用户安装 CGC OpenClacky 后，打开内置的 CGC-2046 面板并点击「连接网站」。面板会创建一个连接会话，把连接请求注入 `cgc-assistant`；助手按本节完成全流程。用户不需要先打开 MCP 页、创建 token 或复制 token。

1. **检查本地宿主**：确认扩展 API、`cgc-assistant` 和宿主 browser 工具可用。若面板已创建连接会话，继续使用当前会话，不要重复创建。
2. **接管真实浏览器**：优先使用宿主 `browser` 工具（CDP autoConnect），打开 CGC 工作台 MCP 页。必须接管用户日常浏览器，以复用登录态；不要要求用户手动开启 remote debugging。
3. **处理登录态**：如果页面在登录页，告诉用户“请在刚打开的浏览器里登录 CGC，登录完成后告诉我继续”。不要代填密码或验证码。用户确认后重新检查页面。
4. **自动签发**：登录成功后，只撤销名称以 `openclacky-auto-` 开头的旧自动 token，保留用户手动创建的 token；签发新的 `openclacky-auto-<YYYYMMDD>` token。
5. **安全复制**：点击一次性 token 的复制按钮，但不要读取、打印或转述明文；直接把剪贴板通过 stdin 管道交给本地 connect API。
6. **写入并验证**：调用本扩展 `/api/ext/cgc-2046/connect`，成功后调用 `/status`，再通过 MCP registry 做真实连接检查。只有 `ok:true`、`configured:true` 且 MCP 握手成功才向用户报告完成。
7. **恢复策略**：浏览器登录失败、用户取消或连接检查失败时，保留可重试状态，说明具体下一步；不要让用户回网站手工配置，除非自动路径确实不可用。

### browser 工具「Target crashed」排障（先修再用）

`browser` 工具所有调用都报 `Protocol error (Network.enable): Target crashed` 时，
**不代表浏览器不可用**——chrome-devtools-mcp 集成层与真实 Chrome 的 CDP 连接仍是
活的（`curl -s http://127.0.0.1:7070/api/browser/status` 返回 `daemon_running:true`），
通常只是 attach 到了某个已崩溃的旧标签页。按顺序尝试，每步后重试 `browser status`：

1. **新建并激活一个空白 tab 再重试**：用 CDP 直连（见下节）`Target.createTarget`
   `about:blank` → `Target.activateTarget`，让 chrome-devtools-mcp 下次 attach 到新 tab。
2. **重启 daemon**：`pkill -f chrome-devtools-mcp`，下一次 `browser` 调用会触发
   Clacky BrowserManager 重新拉起 daemon。
3. **升级 chrome-devtools-mcp**：`npm install -g chrome-devtools-mcp@latest`，再 `pkill`
   重启 daemon。曾遇 1.6.0→1.8.0 修复 Target crashed 类问题。
4. 以上都不行才按「原生 CDP 中间路径」继续——它不依赖 chrome-devtools-mcp 集成层。

注意：升级/重启后如果仍报错，检查 `~/.clacky/logger/clacky-*.log` 里 BrowserDetector
解析的 ws 端点是否与 `~/Library/Application Support/Google/Chrome/DevToolsActivePort`
（macOS）一致——Chrome 重启过时端口会变，daemon 可能还握着旧端点。

### 原生 CDP 中间路径（browser 工具不可用但 CDP 直连正常时）

chrome-devtools-mcp 集成层坏了不代表必须人工引导——**底层 CDP 直连通常完好**，可以
用 Node 原生 WebSocket（Node ≥22 自带全局 `WebSocket`）直接接管用户真实 Chrome，
完成与 `browser` 工具相同的操作（打开页面、判定登录、点按钮）。步骤：

1. **取 ws 端点**：读 `~/Library/Application Support/Google/Chrome/DevToolsActivePort`
   （macOS），第二行即 `ws://127.0.0.1:<port>/devtools/browser/<id>`。先
   `curl -s http://127.0.0.1:7070/api/browser/status` 确认 server 活着。
2. **写探测脚本验证 attach**：用全局 `WebSocket` 连 ws 端点，`Target.getTargets`
   确认能看到页面 target。**关键坑**：`Target.attachToTarget` 用 `flatten:true`，
   之后所有页面级消息（`Network.enable`、`Runtime.evaluate` 等）必须带
   `sessionId` 字段，否则报 `'Runtime.evaluate' wasn't found`。
3. **打开 MCP 页并判定登录态**：`Target.createTarget {url}` 打开
   `/w/<slug>/settings/integrations/agents/mcp`，等数秒后 attach +
   `Runtime.evaluate` 检查 `location.href` / `document.title` / 是否出现密码输入框。
   跳到登录页→按上文「登录态判定」提醒用户登录，等确认后重试。
4. **已登录后执行 UI 操作**：用 `Runtime.evaluate` 调 DOM（点「撤销」旧
   `openclacky-auto-*` token、填名称、点签发、点「复制」按钮）。按钮点击可用
   `el.click()`（多数 SPA 按钮可直接触发），不行再用 `Input.dispatchMouseEvent`
   按元素 bounding rect 坐标点击。
5. **点「复制」后**：token 在剪贴板，**绝不读取/转述明文**，直接走下方「备用路径」
   第 2 步的 `pbpaste` 管道命令写入配置，再断言。
6. **脚本运行纪律**：Node 脚本输出量小时用文件重定向
   （`node script.mjs > /tmp/out.txt 2>&1; cat /tmp/out.txt`）而不要用 `head` 管道——
   管道截断会误判为超时；CDP 消息加超时保护避免 await 永久挂起。
7. 连 CDP 直连都失败（端口不通、getTargets 空、attach 全崩）才回退人工引导。

## 备用路径：手工 token（仅自动连接不可用时）

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
CGC_CSRF=$(curl -sS "http://${CLACKY_SERVER_HOST:-127.0.0.1}:${CLACKY_SERVER_PORT:-7070}/api/ext/cgc-2046/status" | ruby -rjson -e 'print (JSON.parse(STDIN.read)["csrf_token"] rescue "")') && \
pbpaste | ruby -rjson -e 't = STDIN.read.strip; abort "ERROR: clipboard does not contain a CGC token (expected ^cgc_[A-Za-z0-9_-]+$) — nothing was written; re-copy the token from the MCP page" unless t =~ /\Acgc_[A-Za-z0-9_-]+\z/; print JSON.generate({token: t})' | \
  curl -sS -X POST "http://${CLACKY_SERVER_HOST:-127.0.0.1}:${CLACKY_SERVER_PORT:-7070}/api/ext/cgc-2046/connect" \
  -H 'Content-Type: application/json' -H "X-CGC-CSRF-Token: $CGC_CSRF" --data-binary @-
```

**Linux（X11 / Wayland）**：

```bash
CGC_CSRF=$(curl -sS "http://${CLACKY_SERVER_HOST:-127.0.0.1}:${CLACKY_SERVER_PORT:-7070}/api/ext/cgc-2046/status" | ruby -rjson -e 'print (JSON.parse(STDIN.read)["csrf_token"] rescue "")') && \
(xclip -o 2>/dev/null || wl-paste) | ruby -rjson -e 't = STDIN.read.strip; abort "ERROR: clipboard does not contain a CGC token (expected ^cgc_[A-Za-z0-9_-]+$) — nothing was written; re-copy the token from the MCP page" unless t =~ /\Acgc_[A-Za-z0-9_-]+\z/; print JSON.generate({token: t})' | \
  curl -sS -X POST "http://${CLACKY_SERVER_HOST:-127.0.0.1}:${CLACKY_SERVER_PORT:-7070}/api/ext/cgc-2046/connect" \
  -H 'Content-Type: application/json' -H "X-CGC-CSRF-Token: $CGC_CSRF" --data-binary @-
```

要点：connect 是写端点，需带 `X-CGC-CSRF-Token` 头——`CGC_CSRF` 变量先经 `GET /status`（无 Origin 的本地 curl 放行）取回进程级 token；跨站网页因 Origin 校验读不到该 token，这是防 CSRF 劫持的通道（伪造 connect 可改写 mcp.json 指向攻击者 URL，最高危写端点，不可豁免）。

其他要点：

- token 全程经管道传递，**不出现在 argv 和命令行字面量里**，不写入会话记录；
- `JSON.generate` 负责转义，剪贴板内容含引号 / 换行也不会破坏请求；`strip` 去掉首尾空白；
- **token 形态前置断言**：ruby 段在 POST 前校验输入匹配 `^cgc_[A-Za-z0-9_-]+$`（`\A…\z` 全串锚定）——不匹配即 `abort` 报错退出：错误消息打到 stderr、管道不再产出 JSON，curl 拿到空 body，服务端按缺 token 422 拒绝，**mcp.json 不会被写入**。用户剪贴板里常是误复制的整段对话/表格文本，没有这层断言时会被原样写进 Authorization 头造成静默坏连接（状态端点仍报 `token_configured: true`）。断言失败时**不要把剪贴板内容粘进对话诊断**，让用户回 MCP 页重新复制即可；
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

连接成功后，告知用户可以直接提问。自动连接完成后，给新用户的提示词引导（R13）——可以问：

- 「我的工作台现在是什么状态」「有哪些成员」（底层调 `get_workspace_context`、`list_members` 等工具）；
- 「最近有什么活动/课程」「<地点> 近期有什么活动」（底层调 `list_public_offerings`，公开浏览无需 workspace_id）；
- 也可以打开侧边栏「CGC 发现」面板，直接浏览公开活动与课程并跳转详情页。

同时提醒：剪贴板里的 token 被新复制内容覆盖即可，无需特殊处理。

## 备用路径 A（无剪贴板 CLI 时：临时文件管道）

若环境没有 `pbpaste` / `xclip` / `wl-paste`（如裸服务器、ssh 终端）：

1. 让用户**用自己的编辑器**把 token 写入 `~/.clacky/cgc-token.txt`，并 `chmod 600 ~/.clacky/cgc-token.txt`（token 由用户亲手落盘，不经过对话）。
2. agent 执行固定命令（读文件 → stdin 管道 → POST，成功才删除该文件）：

```bash
CGC_CSRF=$(curl -sS "http://${CLACKY_SERVER_HOST:-127.0.0.1}:${CLACKY_SERVER_PORT:-7070}/api/ext/cgc-2046/status" | ruby -rjson -e 'print (JSON.parse(STDIN.read)["csrf_token"] rescue "")') && \
ruby -rjson -e 't = File.read(ARGV[0]).strip; abort "ERROR: ~/.clacky/cgc-token.txt does not contain a CGC token (expected ^cgc_[A-Za-z0-9_-]+$) — nothing was written" unless t =~ /\Acgc_[A-Za-z0-9_-]+\z/; print JSON.generate({token: t})' ~/.clacky/cgc-token.txt | \
  curl -sS --fail-with-body -X POST "http://${CLACKY_SERVER_HOST:-127.0.0.1}:${CLACKY_SERVER_PORT:-7070}/api/ext/cgc-2046/connect" \
  -H 'Content-Type: application/json' -H "X-CGC-CSRF-Token: $CGC_CSRF" --data-binary @- && \
  ruby -e 'File.delete(ARGV[0])' ~/.clacky/cgc-token.txt
```

3. `--fail-with-body` 保证 HTTP 层失败（4xx/5xx）时 curl 退出码非 0（body 仍打印便于诊断），网络失败同样非 0——这两种情况文件都保留、修好后重跑同一条命令即可；只有成功才删除。**token 形态断言失败同样走保留路径**（ruby `abort` → 管道无产出 → 服务端 422 → curl 非零退出 → `File.delete` 不运行；mcp.json 不被写入），让用户改正文件内容后重跑同一条命令。删除用 ruby `File.delete` 而不用 `rm`：OpenClacky ≥1.5.6 的 terminal 工具会把 `rm` 拦截改送 trash，token 文件会长期留在回收站。
4. 继续备用路径第 3 步断言。token 同样不进对话 / argv / 会话记录。自动路径完成后不需要用户重复执行此 fallback。

## 备用路径 B（最后手段：对话粘贴）

仅在主流程与备选 A 都不可用时，允许用户在对话里粘贴 token，agent 再放进 curl 参数。agent 在发出 curl 前先做同样的形态校验（`^cgc_[A-Za-z0-9_-]+$` 全串匹配，不匹配就请用户重新粘贴，绝不带着可疑内容请求）。**必须事先明示代价**：

> 这种方式 token 会留在本机会话记录文件里。建议连接完成后回到 MCP 页**撤销这个 token**，然后改用剪贴板管道（主流程）或临时文件管道（备选 A）重签一个并完成连接——新通道不留痕，补救真实有效。

## 纪律

- token 的目标落盘点只有 `~/.clacky/mcp.json`（写入期间有短暂 0600 临时文件）；agent 不得主动把 token 写进任何其它文件或日志。
- 用户没给 token 时**不要编造**；connect 返回 422 就说明 token 缺失或格式不对，如实告诉用户。
- token 明文只在网站创建时显示一次；用户弄丢了就让他回 MCP 页撤销旧 token、重新签一个。
