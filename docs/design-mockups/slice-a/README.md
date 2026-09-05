# Slice A 页面设计图

本目录是根据 GitHub 已关闭的 Slice A tickets 与设计 Markdown 生成的高保真页面设计稿。生成过程中未读取或参考当前页面实现代码。

## 设计输入

- GitHub Spec：#22
- Slice A 父票：#24–#29
- Slice A 页面票：#61、#63、#65、#67、#69
- Slice A 验收票：#70
- `DESIGN.md`
- `原型工程师/正式组件清单.md`
- `原型工程师/原型评审对比表.md`

## 页面索引

| 文件 | 页面 / 状态 | 主题 | 主要覆盖 |
|---|---|---|---|
| `01-login-dark.png` | 登录 | Dark | #61：全局账号登录、进入工作台 |
| `02-register-light.png` | 注册 | Light | #61：全局账号注册、一个账号多 Workspace |
| `03-workspace-select-active-dark.png` | 工作台选择 / Active | Dark | #63、U1：侧栏选中态、详情联动、角色并集、join_policy |
| `04-workspace-select-pending-light.png` | 工作台选择 / Pending | Light | #63、U1：申请审批中、三步进度、禁止进入工作台 |
| `05-workspace-first-login-grid-light.png` | 工作台选择 / 首次进入 | Light | #63：卡片网格引导、active/pending/invited 三态 |
| `06-members-roles-dark.png` | 成员与角色 | Dark | #65、U2：成员表、角色并集、Owner 专门指派 |
| `07-rbac-permission-map-light.png` | 权限映射 | Light | #67：Role → capability、can? 并集、租户隔离 |
| `08-profile-view-light.png` | Profile 查看 | Light | #69：租户内公开资料、标签、Portfolio |
| `08-profile-view-light-v2.png` | Profile 查看（推荐修订版） | Light | #69：作品集总数 + 3 条预览 + 全量入口，支持任意数量作品 |
| `08-profile-view-light-v3.png` | Profile 查看（当前推荐版） | Light | #69：可扩展作品集 + MembershipRole 并列角色与权限并集 |
| `09-profile-edit-dark.png` | Profile 编辑 | Dark | #69：资料编辑、只读角色与成员编号 |

## 设计边界

- 采用 Linear 式克制、信息密集的双主题视觉；圆角不超过 8px。
- 生产页面不出现 PROTOTYPE / variant 切换浮层。
- 主题入口不画在页面底栏；正式产品按用户偏好持久化。
- join_policy 与 membership 中间态分别表达。
- pending / invited 工作区不能显示“进入工作台”。
- Owner 不出现在成员页的行内角色选择器里。
- Profile 是当前 Workspace 内可见资料，不是全平台社交主页。
- Profile 首页的作品集只展示 3 条预览；显示总数并提供“查看全部 N 个作品”。全量列表使用独立页面的分页或加载更多，不在首页卡片内嵌滚动。
- MembershipRole 没有“主角色 / 附加角色”层级。Profile 中的多个角色以并列 chip 展示，文案使用“角色并集”，权限按所有角色并集合并。
- 不包含 Agent 对话页或 Workflow 执行页。

标准化提示词见 `PROMPTS.md`。
