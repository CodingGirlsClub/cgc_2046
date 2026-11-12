# 课程 Notes / Retro / 复习面设计

> 关联：[#1260](https://github.com/CodingGirlsClub/cgc_2046/issues/1260)（User Story #33–38）
> 状态：设计已定稿（2026-11-11，按 1 + 2 + 3）；本文件只定方案，不含实现。
> 范围：桌面端课程学习页 + 后端 Notes 持久化；Web/小程序对等实现不在本期。

## 1. 目标与非目标

### 目标

1. 阅读材料时选中文字，一步加入 Notes；重复引用不产生重复条目。
2. Notes 可编辑、删除、复制、发送给 Agent，并保留来源与时间。
3. 当前 Issue 的全部必修目标首次达成时，写入一条幂等 Retro。
4. 提供课程级 Notes 复习面：Retro 与用户笔记在同一处，可按 Issue 回看。
5. **Notes 存在服务器，换设备登录后可见**；客户端只保留会话内视图状态。

### 非目标

- Web、小程序、ACP 的 Notes 对等实现。
- 离线 Notes、离线写队列、多端实时同步/冲突合并。
- Agent 自动生成 Retro（当前只做服务端确定性模板）。
- 富文本/Markdown 笔记编辑器；Notes 文本按纯文本保存与渲染。
- 为 Notes 新增 `AgentIntent` 或修改 ADR-0029 的 CTA 协议。
- 把 Notes 放进 `workspace_state.json`。

## 2. 关键决策

| 决策 | 选择 | 理由 |
|---|---|---|
| 数据归属 | **服务器 PostgreSQL 为唯一真源** | 换设备/重装后可见；客户端无本地笔记副本 |
| API | GraphQL 查询 + mutation，Ash 资源 + 手写 resolver | 与现有 Learning 读面一致；复用 Ash policy |
| 归属键 | `(user_id, course_id, issue_id)`；`revision` 仅元数据 | 课程重发布后笔记仍可见；material id 稳定 |
| 去重 | 服务端规范化文本 + source material → `dedupe_hash`，活跃笔记唯一索引 | 不依赖客户端；并发/重试安全 |
| 删除 | 用户 NOTE 硬删除；RETRO 软删除墓碑 `deleted_at` | NOTE 不长期保留用户正文；RETRO 墓碑防止自动重建 |
| Retro | 服务端校验必修完成 + 唯一索引；客户端只触发 `ensureCourseRetro` | 防止客户端伪造完成；跨设备一致 |
| 发 Agent | 客户端预填普通消息 + 页面上下文，不造 `AgentCall` | Notes 不是 CTA；避免新增 intent/source 合约 |
| 课程复习面 | 右侧 Dock 新增 `Notes` panel | 不新增路由；复用 Issue 卡列表组件 |
| 客户端缓存 | 仅内存缓存 + 请求代次 | 服务端真源；不做离线写入/冲突合并 |

### 与 #1260 的关系

`#1260` 原始实现决策把 Notes 定为“本地 workspace 状态、后端同步 out of scope”。
本方案按 2026-11-11 产品决定改为**服务端持久化**：Notes 必须跨设备可见。
因此：

- `workspace_state.json` 继续只存导航元数据，不存 Notes；
- 本地只保留 UI 状态（展开、编辑草稿、删除确认），不落盘；
- 后端同步从“非目标”改为本期核心。

## 3. 数据模型

### 3.1 PostgreSQL 表 `learning_course_notes`

| 列 | 类型 | 约束/说明 |
|---|---|---|
| `id` | uuid | PK |
| `workspace_id` | uuid | FK workspaces，租户隔离 |
| `user_id` | uuid | FK users，笔记所有者 |
| `course_id` | uuid | FK courses |
| `course_revision_id` | uuid nullable | 创建时最新 revision，仅元数据 |
| `issue_id` | text | 课程内容稳定 issue id |
| `source_material_id` | text nullable | 稳定 material id；旧内容可空 |
| `kind` | text | `note` 或 `retro` |
| `text` | text | 1..4000 字符，trim 后非空 |
| `dedupe_hash` | text | 服务端计算，客户端不可写 |
| `inserted_at` / `updated_at` | utc_datetime_usec | Ash 时间戳 |
| `deleted_at` | utc_datetime_usec nullable | 仅 Retro 墓碑；用户 NOTE 硬删除不用该列 |

索引：

- 用户笔记去重唯一（NOTE 硬删除，不存在墓碑行）：
  `(user_id, course_id, issue_id, dedupe_hash) WHERE kind = 'note'`
- Retro 幂等唯一（包含已删除墓碑）：
  `(user_id, course_id, course_revision_id, issue_id) WHERE kind = 'retro'`
- 课程列表：`(user_id, course_id, inserted_at DESC) WHERE deleted_at IS NULL`
- 外键均按现有 Ash 资源约定；迁移由 `mix ash.codegen` 生成。

### 3.2 去重键

服务端计算：

```
normalized = text
  |> String.trim()
  |> String.replace(~r/\s+/u, " ")

dedupe_hash = :crypto.hash(:sha256, normalized <> "\0" <> (source_material_id || ""))
  |> Base.encode16(case: :lower)
```

- 只对 `kind = note` 生效；用户笔记删除是硬删除，重新加入同一引用会新建行。
- 创建命中唯一索引时返回已存在的活跃笔记，不报错、不新增。
- 编辑后可重算；若与另一条活跃笔记冲突，返回 `duplicate_note`，不覆盖。
- Retro 不参与用户笔记去重，由 Retro 唯一索引保证幂等。

### 3.3 Ash 资源

新增 `Cgc2046.Learning.CourseNote`：

- 属性：上表字段；`workspace_id`/`user_id`/`dedupe_hash` 不公开写。
- 多租户：`workspace_id`，`global?(true)`，与 Learning 家族一致。
- 关系：workspace、user、course、course_revision。
- Actions：
  - `:read`：本人笔记；按课程/Issue 过滤。
  - `:create_note`：只接受 `course_id`、`issue_id`、`source_material_id`、`text`；
    actor 写 `user_id`；从 course 写 `workspace_id`；`kind = note`；服务端算 `dedupe_hash`。
  - `:update_note`：只接受 `text`；仅本人；重算 `dedupe_hash`。
  - `:destroy_note`：仅本人；`kind = note` 硬删除，`kind = retro` 写 `deleted_at` 墓碑。
  - `:ensure_retro`：内部 action，见 §6。
- 授权：
  - read/update/destroy：`user_id == actor.id`；
  - create：本人 + `Learning.Authorization.authorize(actor, workspace_id, course_id)`；
  - staff/platform admin 不能读学员 Notes；
  - 课程访问被撤销后，本人仍可读/删自己的历史笔记；create 需重新具备课程访问。

## 4. GraphQL API

在 `GraphqlSchema.Learning` 增加 `learning_mutations`，由根 schema 导入。
手写 resolver 调 `Cgc2046.Learning.CourseNotes` 上下文模块；不让 AshGraphQL
自动暴露 `user_id`/`workspace_id`/`dedupe_hash`。

```graphql
type CourseNote {
  id: ID!
  courseId: ID!
  issueId: String!
  sourceMaterialId: String
  kind: String!          # note | retro
  text: String!
  createdAt: DateTime!
  updatedAt: DateTime
}

input CreateCourseNoteInput {
  courseId: ID!
  issueId: String!
  sourceMaterialId: String
  text: String!
}

input UpdateCourseNoteInput {
  text: String!
}

extend type Query {
  myCourseNotes(courseId: ID!, issueId: String): [CourseNote!]!
}

extend type Mutation {
  createCourseNote(input: CreateCourseNoteInput!): CourseNote!
  updateCourseNote(id: ID!, input: UpdateCourseNoteInput!): CourseNote!
  deleteCourseNote(id: ID!): Boolean!
  ensureCourseRetro(courseId: ID!, issueId: String!): CourseNote
}
```

语义：

- `myCourseNotes`：当前 actor 的笔记；按 `inserted_at DESC` 返回；可只取某 Issue。
- `createCourseNote`：服务端设置 user/workspace/kind/dedupe；重复引用返回已存在条目。
- `updateCourseNote`：仅本人；只改文本。
- `deleteCourseNote`：仅本人；`note` 硬删除，`retro` 写 `deleted_at` 墓碑；不存在或非本人统一 not found（不泄露存在性）。
- `ensureCourseRetro`：服务端校验完成条件；不满足返回 `null`；已删除的 Retro 不重建。
- 错误码：`forbidden`、`invalid_text`、`duplicate_note`、`course_not_accessible`。
- 文本不写日志；错误 message 不回显正文。

## 5. 桌面客户端

### 5.1 数据流

- 进入课程页/切换 Issue：查询 `myCourseNotes(courseId)`；按 `issue_id` 过滤。
- 写入/编辑/删除：mutation 成功后更新内存缓存；失败显示重试，不落本地。
- 请求代次：课程/工作区切换后，迟到响应丢弃，避免串课程。
- 多端：不实时推送；重新进入课程/窗口聚焦时重查。编辑冲突采用 last-write-wins；
  删除优先（删除后其他端下次查询消失）。
- 无本地 Notes 文件，无离线写队列；网络失败明确提示，不假装已保存。

### 5.2 选区加入 Notes

- B3 浮层增加“加入笔记”：解释 / 总结 / 加入笔记 / 复制。
- 点击后调用 `createCourseNote`：
  - 成功：浮层关闭，Issue 卡 Notes 计数 +1，提示“已加入笔记”；
  - 重复：提示“已在笔记中”，不新增；
  - 失败：保留浮层/文本，提示可重试。
- 来源材料：
  - `media.rs` 的 text/markdown body mouse-down 记录当前 `material.id`；
  - 浮层写 `sourceMaterialId`；旧内容无 id 时为 null；
  - 有 material id 时，解释/总结的 `AgentCall` target 升级为 `LearningTarget::Material`；
    无 id 时保持 Issue/Objective。
- 所有按钮 `Role::Button`、aria label、持久 FocusHandle、Enter/Space 可激活。

### 5.3 Issue 卡 Notes section

- 位置：卡片底部，Practice 之后；标题“笔记 / NOTES”+ 计数；默认展开，可折叠。
- 列表按创建时间倒序，按“今天 / 昨天 / 更早”分组。
- 每条显示：
  - kind badge：`NOTE` / `RETRO`；
  - 文本：纯文本、可选择；超过 6 行折叠；
  - 来源：材料标题（有 source id 时）或“本单元”；
  - 时间；
  - 操作：编辑、复制、删除、发给 Agent。
- 编辑：行内多行输入，保存/取消；空白拒绝；保存成功更新缓存。
- 删除：第一次点击变“确认删除 / 取消”；确认后 mutation。
- 复制：写系统剪贴板并提示。
- 发给 Agent：打开 native composer，预填
  `请结合当前课程上下文，帮我回顾这条笔记：\n\n{text}`
  不附加 `AgentCall`；页面上下文由现有 composer 自动附着。ACP 退化为文本预填。

### 5.4 课程级复习面

- 右侧 Dock 增加 `Notes` panel（与 SiteTree / Outline / Notifications 互斥）。
- 入口：
  - Issue 卡 Notes section 标题右侧“查看全部”；
  - 课程详情页头部“课程笔记”。
- 内容：当前 workspace + 当前 course 的全部 Notes，按 Issue 分组，组内时间倒序；
  顶部显示总数与筛选（全部 / 我的笔记 / Retro）。
- 空态：“还没有笔记。阅读材料时选中文字即可加入。”
- 切换课程/离开课程：panel 显示空态，不串课程数据。
- 复用 Issue 卡的 note row 渲染与 CRUD 逻辑。

## 6. Retro

### 6.1 触发

- 条件：当前 Issue 的所有 `required` objective 均 `mastery == "mastered"`；
  无 required objective 时不触发（与后端“空必修不判完成”一致）。
- 客户端在以下时机调用 `ensureCourseRetro`：
  - `LearningProjection` 成功落地后；
  - `LearningStateChanged` 重拉投影成功后；
  - 打开 Issue 卡且投影就绪时。
- 服务端重新校验，不信任客户端；跨设备/多次调用由唯一索引保证幂等。

### 6.2 文本

服务端确定性生成，不调用 LLM：

```
【复盘】{issue_title}
已完成必修目标：{required_titles.join("、")}
完成时间：{RFC3339}
```

### 6.3 幂等与删除

- 唯一键：`(user_id, course_id, course_revision_id, issue_id, kind='retro')`。
- revision 变化允许写新 Retro；旧 Retro 保留。
- 用户删除 Retro 为软删除，保留生成文本与幂等键；`ensureCourseRetro` 检测到墓碑后返回 `null`，不重建。
- 用户 NOTE 删除为硬删除，不保留正文；之后可以重新加入同一引用，生成新行。

## 7. 失败、安全与可访问性

- 服务器/网络失败：笔记查询显示错误与重试；写入失败保留编辑/选区内容，明确提示。
- 未登录：不提供 Notes 写入；查询返回未授权（桌面端课程页本身需登录）。
- 权限：仅本人可读/改/删；staff/admin 不可读；不泄露笔记存在性。
- 输入：服务端 trim、长度 1..4000；纯文本，不解析 HTML/Markdown。
- 日志：不记录正文；错误不回显正文。
- 用户 NOTE 硬删除后不留正文；RETRO 墓碑只保留生成文本、归属键与时间，用于幂等/审计；不做自动清理。
- 可访问性：note 操作按钮 role/aria/focus，Tab + Enter/Space 可用。

## 8. 测试

### 后端

- `create/list/update/delete` 本人路径；跨用户不可读/改/删。
- 课程访问：可学习用户可创建；无权限 `course_not_accessible`；撤权后仍可读自己的历史笔记。
- 去重：同文本同 source 并发创建只一行；不同 source 可各一行；编辑冲突返回 `duplicate_note`。
- 删除：用户 NOTE 硬删除后可重新加入；列表不返回；RETRO 软删除后不重建。
- Retro：未全 mastered 不创建；全 mastered 创建一条；重复调用一条；revision 变化可新建；
  删除后不重建。
- GraphQL：未登录、跨用户、非法 text、超长 text、非本人 id。

### 桌面

- 选区加入、重复提示、source 有/无。
- Issue 卡加载/空/错误/重试；切换课程丢弃迟到响应。
- 编辑/删除确认/复制/发 Agent 预填。
- Notes panel 分组/筛选/空态。
- 键盘 role/focus/Enter/Space。
- 同一 actor 两个客户端（两个查询会话）验证：A 写入后 B 重查可见；不依赖本地文件。

### 变异验证

- 去掉服务端去重索引/比较 → 重复测试必须红。
- 去掉 Retro 唯一索引 → 幂等测试必须红。
- 去掉 material mouse-down 来源记录 → source 测试必须红。

## 9. 本地拆分（不发布 GitHub issue）

按依赖顺序，四个可独立合并的切片：

### S1 — 后端 Notes 资源与 API

**范围**
- 迁移 `learning_course_notes`；Ash `CourseNote` 资源、policy、context 模块。
- GraphQL：`myCourseNotes`、`createCourseNote`、`updateCourseNote`、`deleteCourseNote`。
- 去重、用户 NOTE 硬删除、RETRO 墓碑、owner/课程访问授权。
- 后端测试；GraphQL schema 更新。

**验收**
- 两个用户隔离；同引用去重；NOTE 删除后列表消失且可重新加入；RETRO 删除后不重建。
- 迁移触碰 `backend/priv/repo/migrations/**`，PR 按人工合并范围处理。

**依赖**：无。

### S2 — 桌面查询与选区加入

**范围**
- 桌面 GraphQL client：查询/创建；课程页加载、缓存、请求代次。
- B3 浮层“加入笔记”；material source；Issue 卡只读列表。
- UI 测试：加入、重复、source、加载/错误。

**依赖**：S1。

### S3 — 桌面 Notes CRUD 与发 Agent

**范围**
- 编辑/删除确认/复制/发 Agent 预填；时间分组、长文本折叠、可访问性。
- 测试 CRUD/键盘/composer。

**依赖**：S2。

### S4 — Retro 与课程级复习面

**范围**
- 后端 `ensureCourseRetro` + 完成校验 + 幂等/墓碑；客户端触发点。
- 右侧 Dock `Notes` panel、课程详情入口、筛选/分组。
- 测试 Retro 幂等/revision、panel、跨课程隔离。

**依赖**：S1、S3。

## 10. 发布与回滚

- 后端迁移新增表/索引，不改旧表；部署后旧客户端无影响。
- 桌面旧版本不调用新 API；新版本失败时显示重试，不阻塞课程阅读。
- 回滚后端：新表可保留不用；桌面入口可关闭。已写入 Notes 在表中保留。
- 不涉及生产内容迁移；Notes 为空启动。

## 11. 定稿决策（2026-11-11）

1. Notes 服务端持久化，PostgreSQL 为唯一真源；客户端只保留内存缓存与视图状态。
2. Notes 跨 course revision 保留，`revision` 仅元数据；Retro 按 revision 幂等。
3. 用户 NOTE 硬删除；RETRO 软删除墓碑，删除后不自动重建。
4. 课程复习面采用右侧 Dock `Notes` panel，而非新路由。
5. 发 Agent 采用普通消息预填，不新增 `AgentIntent`/`AgentCallSource`。
