# 用户旅程与 Web 功能清单(定稿)

> 日期:2026-07-31
> 状态:已确认(J1 双路径 / J2 平台管理员创建 / J3 教研活动 / Workflow 构建方式 / 页面清单)
> 依赖:docs/领域模型定稿.md

---

## 1. User Journey

### J1 加入一个 Workspace(两条路径)

```mermaid
flowchart TD
    A[注册 / 登录<br/>全局账号] --> B{如何进入?}

    %% 路径 A:主动发现
    B -->|A. 主动发现| C[浏览公开 Club 列表<br/>发现页]
    C --> D[查看 Club 公开主页<br/>名称 / 简介 / 成员数]
    D --> E{该 Workspace 加入策略}
    E -->|open| F[点击加入<br/>直接成为成员<br/>分配默认 Learner 角色]
    E -->|request| G[提交 JoinRequest<br/>pending]
    G --> H[Owner / Admin 审批<br/>通过后分配角色]
    %% invite_only 空间不可被发现,不会出现在发现页/公开主页,无需此分支

    %% 路径 B:邀请链接
    B -->|B. 收到邀请链接| J[点击链接<br/>slug + UUID 末4位]
    J --> K{已登录?}
    K -->|否| A
    K -->|是| L[校验链接<br/>预览 Club 公开页]
    L --> M[确认加入]
    M --> N{链接带预授权角色?}
    N -->|是| O[直接按角色入座]
    N -->|否| P[由 Owner / Admin 分配]

    F & H & O & P --> Q[进入工作台<br/>看到被授权的 Workflow]
```

### J2 平台管理员创建 + Owner 运营 Workspace

```mermaid
flowchart TD
    A[平台管理员登录<br/>is_platform_admin] --> B[平台管理后台]
    B --> C[创建 Workspace<br/>slug / 名称 / 加入策略<br/>指定 Owner]
    C --> D[Owner 登录]
    D --> E[工作台选择页<br/>看到该 Workspace]
    E --> F[首次进入<br/>选择角色模板<br/>默认 / 自定义 → 生成角色]
    F --> G[建公共 Agent<br/>设置独立使用授权角色]
    G --> H[通过 Workflow 构建 Agent<br/>创建 Workflow<br/>Step: 执行角色 + Agent]
    H --> I[部署进 Workspace]
    I --> J[管理成员<br/>审批申请 / 分配角色 / 生成邀请链接]
```

### J3 教练组织教研活动

```mermaid
flowchart TD
    A[进工作台] --> B[我的 Workflow 列表<br/>教研 Workflow 可见]
    B --> C[执行 Step 1 大纲设计<br/>Tutor + 教研 Agent]
    C --> D{Step 1 完成}
    D -->|解锁| E[Step 2 学员招募物料<br/>Volunteer + 招募 Agent]
    E --> F[Step 3 学员练习答疑<br/>Tutor / Learner + 答疑 Agent]
    F --> G[AgentRun 全程留痕<br/>对话历史可回溯]
```

---

## 2. Web 页面清单(第一版)

| 页面 | 说明 | 可访问角色 |
|---|---|---|
| 注册/登录页 | 全局账号 | 所有人 |
| 公开 Club 发现页 | 浏览 open/request 空间 + 加入(直接加入或申请) | 游客/登录用户 |
| Club 公开主页 | 名称/简介/成员数 + 加入入口 | 游客 |
| 工作台选择页 | 我的 Workspace 列表 + 平台管理员入口 | 成员/平台管理员 |
| Workspace 设置页 | 成员管理(授角色)/申请审批/角色管理/邀请链接管理/加入策略 | Owner/Admin |
| 公共 Agent 列表/详情 | 建/编辑/停用/删除 + 授权角色 | Owner/Admin/Tutor |
| Workflow 执行页 | 当前用户可执行的 Step + 启动 | 按 Step 授权 |
| Agent 对话页 | 聊天 + AgentRun 历史 | 按授权 |
| 成员 Profile 页 | 公开资料(头像/简介/作品) | 成员 |
| 平台管理后台 | 创建 Workspace + 指定 Owner | 平台管理员 |

说明:
- Workflow 构建不做独立 UI 页面:通过 OpenClack 的 Workflow 构建 Agent/Skill 完成,产物部署为 Workspace 的 Workflow
- 个人设置页:并入注册/账号体系,二期再补
- 审计日志页:二期(接 AshAuditLog)
- 页面随开发过程按需增减

---

## 3. 关键权限补充

| 操作 | 允许角色 |
|---|---|
| 创建 Workspace + 指定 Owner | 仅平台管理员(is_platform_admin) |
| 设置/修改加入策略 | Owner |
| 审批加入申请(request 空间) | Owner/Admin |
| 用 Agent 构建 Workflow + 部署进 Workspace | Owner/Admin/Tutor(同"创建 Workflow"矩阵) |
| 生成邀请链接 | Owner/Admin/Volunteer;Volunteer 的链接不可预授权 Admin 级角色 |
