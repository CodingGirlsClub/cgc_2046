# Slice A imagegen 提示词集

生成方式：Codex 内置 imagegen；用例分类统一为 `ui-mockup`。所有页面均要求“只根据 user story 与设计 Markdown 创作，不参考现有代码或页面截图”。

## 共享视觉基准

- 目标：高保真、可交付的桌面 Web 产品 UI，不是概念海报。
- 画布：16:10 桌面截图，无浏览器边框。
- 字体：Inter Variable / 现代中文无衬线；正文克制，标题不过度加粗。
- Dark：`#08090A` 画布，`#090A0B` frame，`#0F1011` card，`#121314` selected，`#F7F8F8/#D0D6E0/#8A8F98` 文本。
- Light：`#F4F5F8` 画布，`#FAFAFA` frame，`#FFFFFF` card，`#F7F7F8` selected，`#222326/#4B4D54/#8A8A8D` 文本。
- 强调色：`#5E6AD2`；开放/成功为绿，申请/pending 为青，邀请/invited 为紫，拒绝为红。
- 边框：8% 黑/白 hairline；卡片圆角不超过 8px，输入框不超过 6px。
- 禁止：渐变、炫光、玻璃拟态、超大圆角、巨大 hero、原型浮层、主题切换底栏、聊天 UI、Agent/Workflow 执行 UI、水印、移动端构图。

## 01 登录 / Dark

双栏认证布局：左侧展示 `CGC 2046` 与“连接社区，也连接你的创造力”，右侧为登录表单。必备文案：`登录`、`邮箱`、`you@example.com`、`密码`、`忘记密码？`、`登录并进入工作台`、`还没有账号？`、`创建账号`。邮箱输入框为 focused 状态；不画社交登录。

## 02 注册 / Light

延续认证双栏布局。左侧解释“一个账号，连接多个工作区”，包含 `统一身份`、`多工作区`、`资料随行`；右侧包含邮箱、密码、确认密码、密码强度、`创建账号并继续` 与 `返回登录`。不画营销插画或 testimonial。

## 03 工作台选择 Active / Dark

全高 `288px` 侧栏 + 详情区。侧栏中 `上海 Coding Girls Club` 为 selected active，角色 `Tutor / Volunteer`；另有 `北京 Women in AI · 申请审批中` 与 `杭州创客空间 · 待凭据加入`。详情区展示 `开放加入`、角色并集、`128 位成员`、最近动态，以及 `进入工作台`、`成员与角色`、`Workspace 设置`。

## 04 工作台选择 Pending / Light

与 03 相同的信息架构，但 selected 项改为 `北京 Women in AI`、`申请制`、`申请审批中`。右侧必须展示 `申请已提交 → 管理员审批中 → 加入工作区` 三步进度与“你暂时不需要做任何操作”。禁止出现 `进入工作台`、成员管理或设置按钮；只保留 `撤回申请` 与返回操作。

## 05 首次进入卡片网格 / Light

无侧栏。标题 `选择你的工作区`，三张等高卡分别表达 active/open、pending/request、invited/invite_only；第四张为虚线 `发现 / 申请加入新工作区`。只有 active 卡可显示 `进入工作台`；policy badge 与 membership status 必须分别出现。

## 06 成员与角色 / Dark

Workspace 管理壳，`成员` tab selected。显示 5 行成员表，列为 `成员 / 账号 / 角色并集 / 加入时间 / 操作`。林溪为 `Owner / Tutor`，操作为带锁的 `专门指派`；周宁行打开角色下拉，只包含 `Admin / Tutor / Volunteer / Learner`，明确没有 Owner。页面展示“多角色权限取并集”和租户隔离提示。

## 07 权限映射 / Light

同一 Workspace 管理壳，`权限映射` tab selected。矩阵列为 `Owner / Admin / Tutor / Volunteer / Learner`；行包括查看成员、管理成员、行内分配角色、修改加入策略、查看租户内 Profile、编辑自己的 Profile、跨 Workspace 访问。右侧展示林溪 `Owner + Tutor` 的并集判定，最终 `can? = true / 允许`。不画 Agent 或 Workflow 权限。

## 08 Profile 查看 / Light

`个人资料` 导航 selected。顶部 Profile 摘要展示林溪、`Owner / Tutor`、上海、加入时间、`仅当前 Workspace 成员可见`。下方包含“关于我”“技能标签”“作品集”“工作区身份”；作品集标题显示总数，首页最多展示 3 条预览，并提供 `查看全部 N 个作品`。全量作品进入独立列表页，以分页或加载更多承载；首页卡片不使用内部滚动。工作区身份以“角色并集”展示并列的 MembershipRole chips，不使用“主角色 / 附加角色”；辅助文案为“权限按所有角色并集合并”。不出现关注、点赞或动态流。

## 09 Profile 编辑 / Dark

Profile 查看页的编辑态。基本资料包含头像、姓名、所在地、个人简介、技能标签；右侧只读展示可见范围、角色与成员编号；下方编辑两条 Portfolio。顶部操作为 `取消 / 保存更改`。角色由 Owner/Admin 管理，在此页不可编辑；页面内不放主题切换入口。
