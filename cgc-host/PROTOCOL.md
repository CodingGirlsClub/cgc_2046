# 对话回复与推送的身份隔离

帧信封、方法名和载荷保持现有协议；`protocol.json` 的版本、方法与端口不变。

- 请求回复只发给原请求的 WebSocket，带原请求的 `id`（请求未带时，回复也不带）。异步操作完成时，原连接已关闭、失去授权或配对代次已变化，则丢弃回复；即使同一个 socket 又重新 `hello`，旧回复也不会恢复。另一标签页接管课程不迁移请求回复。
- 课程推送不带 `id`，发给当前配对代次内已授权的课程 holder。标签页接管后，增量、卡片及 `turn.end` 跟随新 holder；原标签页不再收到推送。
- 每次配对清除或换发都会使旧发送绑定失效。同账号的新连接 `hello + chat.attach` 会刷新课程推送绑定，因此可以继续接收原回合的事件并回答卡片；跨账号接管仍先取消旧回合，新账号收到 `busy` 后重试，不接收旧账号事件。

内部 `ChatContext.reply` 和 `ChatContext.push` 分别承担这两个职责，不通过是否存在 `id` 猜测路由。`card.answer` 的成功关闭消息走本次请求的回复；取消产生的关闭消息走课程推送。配对对象每次换发都被替换，其引用身份作为内存中的配对代次，无需改状态文件。

Web 为对话请求记录持有权代次。`chat.evicted`、`not_holder`、连接关闭或配对授权失效后，旧请求的回复、错误和超时均不再更新页面状态；新 attach/reclaim 或新开对话也使此前请求失效。被接管后只有新 reclaim 对应的有效 history 才解除 `evicted`，不能让原 socket 上晚到的 history 恢复发送权限。当前代次的正常错误仍显示，重试成功后清除。

这项隔离只控制消息的发送目标，不改变 OMP 审批模式、持有权释放后的宽限期、会话持久化或线上的帧格式。可通过还原本次代码回滚，无数据迁移。

回归：`bun test test/isolation.test.ts`（在 `cgc-host/` 执行），使用真实 Host WebSocket 与进程内假 ACP agent，不调用真实模型或使用真实凭证。

## 版本与发布门禁

Host 版本限定为三个无前导零的非负安全整数：`major.minor.patch`；不接受 `v` 前缀、预发布或构建后缀。`web/lib/host-version.ts` 按三段数值比较，例如 `0.1.9 < 0.1.10`。Web 的 `MIN_HOST_VERSION` 定义在该纯模块中，必须小于等于 `package.json.version`，不要求相等；兼容旧 Host 时保留最低要求。

`scripts/check-version-bump.ts` 先检查本地版本契约，再读取线上清单。只有明确 HTTP 404 可按首次发布放行；网络失败、15 秒超时、其他非 2xx、坏 JSON 或畸形字段均退出 1 并提示检查后重试。有效清单的 sha256 相同则无需升版，不同则要求使用不同的有效版本号。无效的本地契约不能借 404 绕过。门禁与 Web 均验证版本格式；清单还必须包含有效 sha256 和固定 download_path。

纯版本模块随 Web 自身打包；Host 发布门禁在完整仓库的构建阶段复用它，不把 Web 的运行时代码引入 Host 包。两个部署单元不互相读取镜像外的运行时文件，版本下限修改会按现有 Web 路径规则触发构建。

## 会话准备时限与共享进程

`protocol.json.preparationTimeoutMs` 为 45 秒，覆盖一次请求从课程队列等待到进程查找/启动、ACP initialize、session/list/load/new 结束的总时间；不是每步重新计时。Web 的 `CHAT_TIMEOUT_MS` 为 60 秒，给 Host 回复保留 15 秒余量。模型已开始后的正常回合不受这个准备时限限制。两端各自拥有预算常量，Web 测试读取 Host 协议并验证实际页面计时器及至少 15 秒余量；这样保持 Web 独立 Docker 构建边界。

超时请求以 `chat_unavailable` 结束，日志只记失败阶段、预算和重试建议。Host 同时发出 SDK 的协作取消并停止等待；如果请求已经使用进程，则废弃该进程代次、断开 ACP 并终止对应子进程。迟到的启动结果只关闭它自己的旧子进程，迟到的 RPC 结果和旧连接通知不再更新会话、持久化指针或发出 session/prompt。准备结果提交与发出 prompt 保持在同一课程队列操作内，避免同账号重新配对时夹入另一次 load。

一个 OMP 进程由多门课共享：废弃进程会使其他已开始的回合以 `turn.end {stopReason: "error"}` 收尾，未答卡片取消，内存中的已加载会话卸下。已有有效会话指针保留，下次用户重试启动新进程并加载；超时的新会话结果不会覆盖指针。已经完成的文件或平台副作用不回滚，OMP 可能保留超时前已创建的空会话。仅在课程队列等待、尚未取得进程的请求超时，不关闭其他课程的正常进程。

## 历史对话（protocolVersion 2）

`chat.sessions {courseId, cursor?}` → `sessions {sessions: [{sessionId, updatedAt, messageCount}], current, nextCursor}`：本课程工作目录下的会话列表（ACP session/list，`cursor` 原样透传分页）；只读，有回合在跑时同样可查。`updatedAt` / `messageCount` 缺省为 `null`（OMP 版本差异），页面自行降级展示。

`chat.open {courseId, sessionId}` → `history`（同 `chat.attach` 的载荷）：切换到指定会话。目标必须在这门课的工作目录下（belongs 校验），否则回 `bad_request`；加载失败回 `session_unavailable`，且**持久指针保持不变**——原会话不受影响，重载即回到原对话；有回合在跑回 `busy`。切换成功才推进持久指针；打开的就是当前会话时不重复加载。

页面按 `status.protocolVersion` 降级：低于 2 的旧 Host 不显示历史入口（不会发出 `chat.sessions` / `chat.open`）。

这三项改动不改变 wire 方法、协议版本、审批模式或 playbook。测试使用假 ACP 与临时 HOME；进程取消测试只启动可丢弃的 shell/sleep 子进程，不启动真实模型。
