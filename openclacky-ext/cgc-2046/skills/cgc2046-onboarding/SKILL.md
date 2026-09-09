---
name: cgc2046-onboarding
description: 首次连接 CGC-2046、面板点击「连接网站」、MCP 连接错误/401、或自动连接因缺少 node 等本机环境不可用时使用。优先面板触发的浏览器/CDP 自动连接；缺运行环境时先按用户系统自举安装（Node ≥22），自举失败或用户拒绝才使用剪贴板或临时文件 fallback。
---

# CGC-2046 连接引导

目标是让用户在本机 OpenClacky 安全接入 CGC-2046 MCP。

## 安全边界

- token 只允许落盘到 `~/.clacky/mcp.json`；不得进入对话、工具参数、日志或其他文件。
- 优先复用用户真实浏览器的登录态；不得代填密码或验证码。
- 只有 `connect` 返回成功、状态为 `configured:true` 且 MCP 握手成功，才能报告完成。

## 路由

1. 检查扩展 API、`cgc-assistant` 与宿主 browser/CDP 是否可用，并确认自动路径的环境依赖（Node ≥22）。缺 node 或 browser daemon 起不来时，先按 [环境自举](references/connection-procedure.md) 修复——不要直接降级手工流程。
2. 环境就绪后执行面板一键连接：打开 MCP 页、提醒用户登录、自动签发一次性 token、通过 stdin 调用 connect，再验证 status 和 MCP registry。
3. browser 集成层故障但 Chrome CDP 可用时（node 已就绪），读取 [原生 CDP 流程](references/connection-procedure.md)。
4. 环境自举失败、用户拒绝安装等自动路径确实不可用时，执行 [手工 token 与 fallback 流程](references/connection-procedure.md)——该路径只依赖 ruby + curl，不需要 node。

## 故障处理

遇到浏览器 target 崩溃、连接失败或用户取消时，保留可重试状态并报告下一步；不要跳过安全验证，也不要要求用户把 token 粘贴到对话中。
