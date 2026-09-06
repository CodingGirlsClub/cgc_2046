---
name: cgc2046-onboarding
description: 首次连接 CGC-2046、面板点击「连接网站」、或 MCP 连接错误/401 时使用。优先面板触发的浏览器/CDP 自动连接；自动路径不可用时才使用剪贴板或临时文件 fallback。
---

# CGC-2046 连接引导

目标是让用户在本机 OpenClacky 安全接入 CGC-2046 MCP。

## 安全边界

- token 只允许落盘到 `~/.clacky/mcp.json`；不得进入对话、工具参数、日志或其他文件。
- 优先复用用户真实浏览器的登录态；不得代填密码或验证码。
- 只有 `connect` 返回成功、状态为 `configured:true` 且 MCP 握手成功，才能报告完成。

## 路由

1. 检查扩展 API、`cgc-assistant` 与宿主 browser/CDP 是否可用。
2. 可用时执行面板一键连接：打开 MCP 页、提醒用户登录、自动签发一次性 token、通过 stdin 调用 connect，再验证 status 和 MCP registry。
3. browser 集成层故障但 Chrome CDP 可用时，读取 [原生 CDP 流程](references/connection-procedure.md)。
4. 自动路径不可用时，执行 [手工 token 与 fallback 流程](references/connection-procedure.md)。

## 故障处理

遇到浏览器 target 崩溃、连接失败或用户取消时，保留可重试状态并报告下一步；不要跳过安全验证，也不要要求用户把 token 粘贴到对话中。
