# CGC-2046 连接器扩展（cgc-2046）

OpenClacky 扩展：把 CGC-2046 工作台接入本机 agent。安装后提供：

- **API 端点**：`POST /api/ext/cgc-2046/connect` 把 token + MCP URL 原子化 read-merge-write 进 `~/.clacky/mcp.json`（新建 0600，类级互斥锁防并发，reload 失败自动回滚）并热重载 MCP registry；`GET /api/ext/cgc-2046/status` 查询配置状态（不泄漏 token）；`POST /api/ext/cgc-2046/skills/sync` 为后续切片留位（当前返回 501）。
- **agent**：`cgc-assistant`——通过 CGC MCP 工具读写工作台的助手（8 个工具，含 two-tool 确认流）。
- **skill**：`cgc2046-onboarding`——引导创建 token、经剪贴板管道调 connect、验证状态的连接流程。

要求 **openclacky >= 1.3.7**（api handler / ext pack / install 能力自 v1.3.7 引入）。

## 目录结构

```
extension/cgc-2046/
  ext.yml                          # manifest（id 与目录名一致；config.mcp_url 是唯一改 URL 的点）
  api/
    handler.rb                     # 薄 DSL 层：路由 + 上下文 + error! 惯例 + 互斥/回滚加固
    mcp_config.rb                  # mcp.json read-merge-write 纯逻辑（不依赖 clacky gem，含原子写）
  agents/cgc-assistant/
    system_prompt.md               # CGC-2046 助手人设与工具说明
  skills/cgc2046-onboarding/
    SKILL.md                       # 连接引导流程（剪贴板管道主流程）
  bin/pack                         # 打包脚本（symlink → ext pack → ext verify）
  test/
    mcp_config_test.rb             # 纯逻辑单测（minitest，stdlib）
    handler_routes_test.rb         # 请求级测试（fake req + Halt 捕获，不落盘）
```

## 打包与安装

```bash
# 打包（产物在 extension/dist/，已 gitignore）
extension/cgc-2046/bin/pack

# 安装
openclacky ext install extension/dist/cgc-2046.zip
```

`bin/pack` 会把本目录 symlink 到 `~/.clacky/ext/local/cgc-2046`（openclacky 开发层），因此开发期改完文件即生效（handler 按请求热加载），无需重复打包。

## 使用流程

1. 在 CGC-2046 网站工作台的「连接设置」页 `/w/<slug>/settings/connection` 创建 token 并**复制到剪贴板**（明文只显示一次；不要粘贴进对话）。
2. 在 OpenClacky 里新建会话、选择 `cgc-assistant`（或任意带 terminal 的会话触发 `cgc2046-onboarding` skill）。
3. skill 用「剪贴板 → stdin 管道」命令 curl `POST /api/ext/cgc-2046/connect` 写入配置（loopback 免 access-key；token 不进 argv、不进入会话记录）。
4. `GET /api/ext/cgc-2046/status` 返回 `configured:true` 后即可提问工作台问题。

## 配置点

- `ext.yml` 顶层 `config.mcp_url`：MCP server 地址，默认 `http://localhost:4102/mcp`（联调值；生产域名确定后只改这一处）。
- connect 端点 body 也接受 `url` 字段临时覆盖。

## 卸载

无 CLI 子命令（known limitation），手动两步：

```bash
rm -rf ~/.clacky/ext/installed/cgc-2046
# 再编辑 ~/.clacky/mcp.json，删除 mcpServers 下的 "cgc" 条目
```

`~/.clacky/ext-data/cgc-2046/`（若存在）默认保留。

## 安全约定（真实边界）

- token 的目标落盘点只有 `~/.clacky/mcp.json`（connect 写入期间存在短暂的 0600 临时文件，原子 rename 后即清除）；handler 的响应体、日志、data_path 文件一律不含 token。
- onboarding 主流程走「剪贴板 → stdin 管道」：token 经管道传递，不出现在 argv、对话消息或工具参数里，因此不进入 OpenClacky 会话记录文件；`JSON.generate` 负责转义，剪贴板内容含引号/换行也安全。
- 无剪贴板 CLI 的环境首选备选 A（用户亲手把 token 写入 0600 临时文件、agent 管道读取、成功后删除）；对话粘贴是最后手段（备选 B），token 会留在会话记录中——skill 会明示代价并建议撤销后改走无留痕通道重签。
- MCP 工具结果（如 `invitation_token` 明文）会被客户端运行时记入会话记录，这是既定事实；我们的纪律是不主动把凭证写进额外文件/日志。
- status 端点只返回 `configured` / `url`，永不返回 headers。
- connect 的条目名写死 `cgc`，不会改动 mcp.json 里的其它 server 条目；更新时保留该条目上的未知额外键。

## Known limitations

- **宿主其它写路径不在本包控制面**：OpenClacky WebUI 的 `/api/mcp` 管理端点与本扩展可能并发写同一 `mcp.json`。本包内已用类级互斥锁 + 原子写加固自身路径，但无法锁住宿主写路径；根本解是在 OpenClacky 侧提供统一写 API（如 `Registry#upsert_server`），属上游改进建议。
- 卸载不自动清理 mcp.json 的 `cgc` 条目（无 uninstall CLI）。

## 测试

需在项目 mise 环境（Ruby 4.x，系统 ruby 2.6 无 openclacky gem）：

```bash
cd extension/cgc-2046
mise exec -- ruby test/mcp_config_test.rb        # mcp.json merge / 原子写 / 权限（test-first 交付）
mise exec -- ruby test/handler_routes_test.rb    # 请求级：422/200/回滚/500/501 + 无 token 泄漏（不落盘）
```

## 验证步骤（安装后自测）

1. `openclacky ext install extension/dist/cgc-2046.zip`，确认 `openclacky ext list` 出现 `cgc-2046`。
2. 预置一个含其它 server 条目的 `~/.clacky/mcp.json`，走一遍「使用流程」；完成后检查：其它条目语义无损、`cgc` 条目四键正确、文件权限 0600（既有文件 mode 不变）。
3. `GET /api/ext/cgc-2046/status` 返回 `configured:true` 且响应无 headers。
4. 在 agent 会话调 `get_workspace_context` 成功返回工作台信息。
