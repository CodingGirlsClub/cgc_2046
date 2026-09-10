// 程序媛汇 2046 工作台 hub 面板(S1-S4 重构;视觉对齐青狮工作台设计语言)。
//
// 单一入口:侧栏顶部「程序媛汇 2046」(mount sidebar.nav.top,青狮工作台同款位置)。
// 承接原 workspace 连接面板的全部职责(连接管理 / 身份区 / 任务 / 会话入口),
// 新增角色感知功能目录与一键进助手会话;发现与课程面板保留为隐藏功能页
// (registerWorkspace 不挂侧栏入口),经目录卡 openWorkspace 直达。
//
// 视觉(学青狮):宿主 CSS 变量体系(--color-*/--radius-*/--shadow-*/--transition-*)
// 自动适配明暗主题;页面 = 光晕背景 + max-width 居中容器;page header =
// brand icon 容器(accent-soft 底) + 标题行 + 状态 pill + 右侧操作;功能目录 =
// 3 列卡片(icon 容器/名称/描述/箭头,hover 描边+阴影+箭头位移);任务与活动 =
// 行列表(hover 高亮、分隔线)。
//
// 功能目录按 /me/workspaces 返回的角色动态渲染:
//   - 和助手对话(全员)——POST /api/sessions {agent_profile: cgc-assistant}
//     + Clacky.Sessions.select 直接进入会话(青狮工作台 view.js 同款通道);
//   - 发现活动 / 我的课程(全员)——openWorkspace 隐藏功能页;
//   - 教研工作台(任一 workspace 角色含 tutor);
//   - 平台管理(is_platform_admin)——网站管理端外链(面板侧无管理功能页)。
//
// 安全红线:只展示 status 布尔/URL 字段与 loopback 透传数据,绝不渲染
// token/headers;服务端字符串一律 escapeHtml;写端点(DELETE /connect)带
// X-CGC-CSRF-Token,403-on-CSRF 重取 /status token 重试一次。

(() => {
  "use strict";
  if (!window.Clacky || !Clacky.ext || Clacky.ext.pure) return;
  const Kit = window.CgcKit;
  if (!Kit) return; // 共享骨架未注入(ext.yml 首位 cgc-2046-shared 异常)

  const API = Kit.API;
  const rawGet = Kit.rawGet;   // /health 探活(共享 fetch 封装:非 2xx 抛错挂 { body, status })
  const HOME_ID = "cgc";
  const DISCOVERY_ID = "cgc-2046-discovery";
  const TEACH_ID = "cgc-2046-curriculum";
  const COURSE_ID = "cgc-2046-course";
  const AGENT_PROFILE = "cgc-assistant";
  // 会话 Tab 可过滤的三个助手(agent_profile → 显示名)
  const SESSION_AGENTS = {
    "cgc-assistant": "2046 助手",
    "cgc-admin": "管理助手",
    "cgc-tutor": "教研助手"
  };
  // 沿用原 workspace 面板的存储 key:用户已持久化的选择不丢失
  const LS_WORKSPACE = "cgc2046.workspacePanel.workspaceId";
  const EDIT_ROLES = ["tutor"];
  const ADMIN_ROLES = ["owner", "admin"];

  // ---- 闭包状态(跨面板开关保持) ----
  let mcpError = null;        // 最近连接异常文本(横幅)
  let sessionTab = "all";     // 会话区当前 Tab(all 或 SESSION_AGENTS 的键)
  let allSessions = [];       // /api/sessions + 本地合并缓存(Tab 切换不重拉)
  let currentContainer = null;

  let configured = false;
  let webUrl = "";
  let workspaces = [];        // [{ workspace_id, name, slug, roles }]
  let isPlatformAdmin = false;
  let selectedWorkspaceId = "";
  let sessionBusy = false;    // 会话创建中(防重复点击)
  const escapeHtml = Kit.escapeHtml;


  function toast(message, type) {
    if (Clacky.Modal && typeof Clacky.Modal.toast === "function") {
      Clacky.Modal.toast(message, type || "info");
    } else {
      console.info("[cgc-home] " + message);
    }
  }

  // MCP 连接异常横幅(原活动区已删,banner 独立保留:连接错误是用户
  // 必须看见的引导,挂在 guide-slot 下方)
  function renderMcpBanner(container) {
    const el = container.querySelector("#cgc-mcp-banner");
    if (!el) return;
    if (!mcpError) { el.innerHTML = ""; return; }
    el.innerHTML =
      '<div class="cgch-banner">' +
        '<b>CGC MCP 连接异常：</b>' + escapeHtml(mcpError) +
        '<div class="cgch-banner-hint">请运行 <code>cgc2046-onboarding</code> skill 重新连接，' +
          '或在网站「MCP」页重新生成 token。</div>' +
      '</div>';
  }

  // ---- 线性 icon(stroke currentColor,青狮同款容器) ----
  function icon(name) {
    const paths = {
      code: '<polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/>',
      chat: '<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>',
      compass: '<circle cx="12" cy="12" r="10"/><polygon points="16.24 7.76 14.12 14.12 7.76 16.24 9.88 9.88 16.24 7.76"/>',
      book: '<path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20"/><path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z"/>',
      edit: '<path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.12 2.12 0 0 1 3 3L12 15l-4 1 1-4z"/>',
      shield: '<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>',
      arrow: '<polyline points="9 18 15 12 9 6"/>',
      plus: '<path d="M12 5v14"/><path d="M5 12h14"/>'
    };
    return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" ' +
           'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
           (paths[name] || "") + '</svg>';
  }

  // ---- 侧边栏入口(顶部,青狮工作台同款挂载点) ----
  function navRow() {
    const item = document.createElement("div");
    item.className = "task-item task-item-summary";
    item.dataset.extWorkspace = HOME_ID;
    item.innerHTML =
      '<div class="task-row">' +
        '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" ' +
             'fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" ' +
             'stroke-linejoin="round" class="task-icon">' +
          '<path d="M5 12h14"/>' +
          '<path d="M12 5v14"/>' +
        '</svg>' +
        '<div class="task-info"><span class="task-name">程序媛汇 2046</span></div>' +
      '</div>';
    item.addEventListener("click", function () { Clacky.ext.ui.openWorkspace(HOME_ID); });
    return item;
  }

  // ---- 面板页(青狮 page 结构:光晕背景 + 居中容器 + page header) ----
  function render(container) {
    currentContainer = container;
    container.innerHTML =
      '<div class="cgch-page">' +
        '<header class="cgch-header">' +
          '<div class="cgch-brand">' +
            '<div class="cgch-brand-icon">' + icon("code") + '</div>' +
            '<div class="cgch-heading">' +
              '<div class="cgch-title-row">' +
                '<h3 class="cgch-title">程序媛汇 2046</h3>' +
                '<span class="cgch-pill" id="cgc-state-pill" data-testid="cgc-state-pill">…</span>' +
                '<span id="cgc-version-badge" class="cgch-version-badge" data-testid="cgc-version-badge" hidden></span>' +
              '</div>' +
              '<p class="cgch-subtitle">连接 · 身份 · 功能目录</p>' +
            '</div>' +
          '</div>' +
          '<div class="cgch-header-actions">' +
            '<a id="cgc-open-web" class="btn-secondary" href="#" ' +
               'target="_blank" rel="noopener noreferrer">打开网站</a>' +
            '<button id="cgc-upgrade" class="btn-secondary" type="button" data-testid="cgc-upgrade" hidden>升级</button>' +
            '<button id="cgc-disconnect" class="btn-secondary cgch-btn-danger" type="button" disabled>断开连接</button>' +
          '</div>' +
        '</header>' +
        '<div id="cgc-guide-slot"></div>' +
        '<div id="cgc-mcp-banner"></div>' +
        '<section class="cgch-section" id="cgc-identity-wrap">' +
          '<div class="cgch-section-header">' +
            '<div>' +
              '<div class="cgch-section-title">工作台</div>' +
              '<div class="cgch-section-desc">身份、角色与待办</div>' +
            '</div>' +
            '<button id="cgc-tasks-refresh" class="btn-secondary cgch-btn-sm" type="button">刷新</button>' +
          '</div>' +
          '<div class="cgch-card">' +
            '<div class="cgch-identity" id="cgc-identity">加载中…</div>' +
            '<div id="cgc-picker-slot"></div>' +
            '<div id="cgc-tasks"><div class="cgch-empty">加载中…</div></div>' +
          '</div>' +
        '</section>' +
        '<section class="cgch-section">' +
          '<div class="cgch-section-header">' +
            '<div>' +
              '<div class="cgch-section-title">功能目录</div>' +
              '<div class="cgch-section-desc">按你的角色可用</div>' +
            '</div>' +
          '</div>' +
          '<div id="cgc-catalog"></div>' +
        '</section>' +
        '<section class="cgch-section">' +
          '<div class="cgch-section-header">' +
            '<div>' +
              '<div class="cgch-section-title">最近会话</div>' +
              '<div class="cgch-section-desc">三个助手的会话记录,点击继续</div>' +
            '</div>' +
            '<div class="cgch-tabs" id="cgc-session-tabs" role="tablist">' +
              '<button class="cgch-tab is-active" type="button" role="tab" data-tab="all">全部</button>' +
              '<button class="cgch-tab" type="button" role="tab" data-tab="cgc-assistant">2046 助手</button>' +
              '<button class="cgch-tab" type="button" role="tab" data-tab="cgc-admin">管理助手</button>' +
              '<button class="cgch-tab" type="button" role="tab" data-tab="cgc-tutor">教研助手</button>' +
            '</div>' +
          '</div>' +
          '<div class="cgch-card" id="cgc-recent-sessions" data-testid="cgc-recent-sessions"></div>' +
        '</section>' +
      '</div>';

    const discEl = container.querySelector("#cgc-disconnect");
    discEl.addEventListener("click", function () {
      if (discEl.dataset.mode === "connect") {
        if (!window.confirm("将自动打开 CGC 网站签发并复制 token(需已在浏览器登录网站),是否继续?")) return;
        startConnectSession();
      } else {
        disconnect(container);
      }
    });
    container.querySelector("#cgc-upgrade").addEventListener("click", function () {
      upgradeExtension(container);
    });
    container.querySelector("#cgc-identity-wrap").addEventListener("change", function (e) {
      if (e.target && e.target.id === "cgc-ws-select") selectWorkspace(container, e.target.value);
    });
    container.querySelector("#cgc-tasks-refresh").addEventListener("click", function () {
      loadTasks(container);
    });
    loadRecentSessions(container);
    renderMcpBanner(container);
    renderCatalog();
    refresh(container);
    loadVersionBadge(container);
    checkExtensionUpdate(container);
    // tab 用 container 级事件委托:按钮在骨架层、列表在子容器,直绑节点在
    // 异步重写后引用失效的风险归零(真实 DOM 与测试 shim 语义一致)
    container.addEventListener("click", function (e) {
      const t = e && e.target;
      if (!t || typeof t.getAttribute !== "function") return;
      const tabName = t.getAttribute("data-tab");
      if (!tabName) return;
      sessionTab = tabName;
      container.querySelectorAll("[data-tab]").forEach(function (b) {
        b.classList.toggle("is-active", b === t);
      });
      renderSessionRows(container);
    });
  }

  // ---- 版本徽标与升级(自托管分发:/version + loopback /update_info;
  //   安装执行复用宿主 /api/store/extension/install,数据源不再走市场查询) ----
  // 版本比较只在 handler /update_info 一处(version_newer?),面板直接消费
  // update_available 布尔,不再重复比较

  let installedVersion = "";

  function loadVersionBadge(container) {
    const badge = container.querySelector("#cgc-version-badge");
    if (!badge) return;
    fetch(API + "/version", { headers: { Accept: "application/json" } })
      .then((r) => r.json())
      .then((payload) => {
        installedVersion = String(payload.version || "").replace(/^v/i, "");
        badge.textContent = installedVersion ? "v" + installedVersion : "";
        badge.hidden = !installedVersion;
        badge.title = "CGC-2046 扩展当前版本 v" + installedVersion;
      })
      .catch(() => { /* 版本拉取失败不影响主流程 */ });
  }

  function checkExtensionUpdate(container) {
    const btn = container.querySelector("#cgc-upgrade");
    if (!btn || !btn.isConnected) return;
    fetch(API + "/update_info", { headers: { Accept: "application/json" } })
      .then((r) => r.json())
      .then((payload) => {
        if (!payload || payload.ok !== true) { btn.hidden = true; return; }
        const latest = String(payload.latest_version || "");
        const current = String(payload.current_version || "") || installedVersion;
        if (latest && payload.download_url && payload.update_available === true) {
          btn.textContent = "升级 v" + latest;
          btn.title = "CGC-2046 有新版本 v" + latest + ",当前 v" + current;
          btn.dataset.latest = latest;
          btn.hidden = false;
        } else {
          btn.hidden = true;
        }
      })
      .catch(() => { /* 升级信息查询失败静默(离线/远端故障),按钮保持隐藏 */ });
  }

  async function upgradeExtension(container) {
    const btn = container.querySelector("#cgc-upgrade");
    if (!btn || btn.disabled) return;
    btn.disabled = true;
    btn.textContent = "升级中…";
    try {
      const res = await fetch(API + "/update_info", { headers: { Accept: "application/json" } });
      const payload = await res.json();
      if (!payload || payload.ok !== true || !payload.download_url) throw new Error("更新信息不可用");
      const install = await fetch("/api/store/extension/install", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ download_url: payload.download_url, name: "CGC-2046" }),
      });
      const ip = await install.json();
      if (ip.ok === false) throw new Error(ip.error || "安装请求失败");
      // 新版宿主异步安装:轮询 job 直到完成;旧版宿主 POST 内同步完成(无 job_id)
      let job = ip.job_id;
      while (job) {
        await new Promise((r) => setTimeout(r, 1000));
        const s = await fetch("/api/store/extension/install/status?job_id=" + encodeURIComponent(job),
          { headers: { Accept: "application/json" } });
        const sp = await s.json();
        if (sp.ok === false) throw new Error(sp.error || "安装失败");
        if (sp.status === "done" || sp.done || sp.completed) { job = null; }
      }
      window.alert("CGC-2046 已升级,页面即将刷新。");
      window.location.reload();
    } catch (e) {
      window.alert("升级失败:" + (e && e.message ? e.message : "未知错误") + ",可稍后重试。");
      btn.disabled = false;
      if (btn.dataset.latest) btn.textContent = "升级 v" + btn.dataset.latest;
      else btn.hidden = true;
    }
  }

  // ---- 状态 pill(header 右侧徽章) ----
  function setPill(text, cls) {
    const pill = currentContainer && currentContainer.querySelector("#cgc-state-pill");
    if (pill) {
      pill.textContent = text;
      pill.className = "cgch-pill" + (cls ? " " + cls : "");
    }
  }

  // ---- 功能目录(角色感知;青狮 extension-card 同款结构) ----
  function catalogSpecs() {
    const canEdit = workspaces.some(function (w) {
      const roles = Array.isArray(w.roles) ? w.roles : [];
      return EDIT_ROLES.some(function (r) { return roles.indexOf(r) !== -1; });
    });
    const specs = [
      { key: "chat", ic: "chat", title: "和助手对话",
        desc: "通过 CGC 助手读写工作台", action: "session" },
      { key: "discovery", ic: "compass", title: "发现活动",
        desc: "浏览公开活动与课程,报名支付", action: "workspace", target: DISCOVERY_ID },
      { key: "course", ic: "book", title: "我的课程",
        desc: "课程学习地图与进度", action: "workspace", target: COURSE_ID }
    ];
    if (canEdit) {
      specs.push({ key: "tutor", ic: "edit", title: "教研工作台",
        desc: "课程草稿编辑与教研流程", action: "workspace", target: TEACH_ID });
    }
    if (isPlatformAdmin && webUrl) {
      specs.push({ key: "admin", ic: "shield", title: "平台管理",
        desc: "网站管理端(成员/工作台)", action: "web" });
    }
    // 工作台管理(Owner/Admin):创建课程/成员/审批/邀请
    const isAdmin = workspaces.some(function (w) {
      const roles = Array.isArray(w.roles) ? w.roles : [];
      return ADMIN_ROLES.some(function (r) { return roles.indexOf(r) !== -1; });
    });
    if (isAdmin) {
      specs.push({ key: "wsadmin", ic: "shield", title: "工作台管理",
        desc: "创建课程·成员·审批·邀请", action: "session-admin" });
    }
    return specs;
  }

  function renderCatalog() {
    const el = currentContainer && currentContainer.querySelector("#cgc-catalog");
    if (!el) return;
    if (!configured) {
      el.innerHTML =
        '<div class="cgch-guide" data-testid="cgc-connect-guide">' +
          '<div class="cgch-guide-icon">' + icon("plus") + '</div>' +
          '<div class="cgch-guide-copy">' +
            '<div class="cgch-guide-title">还未连接 CGC-2046</div>' +
            '<div class="cgch-guide-desc">点右上「连接网站」,助手会自动完成连接(已登录网站时);' +
              '或运行 <code>cgc2046-onboarding</code> skill 手动完成。</div>' +
          '</div>' +
        '</div>';
      return;
    }
    const cards = catalogSpecs().map(function (spec) {
      return (
        '<button class="cgch-catalog-card" type="button" data-catalog="' + spec.key + '"' +
              ' data-testid="cgc-catalog-' + spec.key + '">' +
          '<span class="cgch-catalog-icon">' + icon(spec.ic) + '</span>' +
          '<span class="cgch-catalog-copy">' +
            '<span class="cgch-catalog-heading">' +
              '<span class="cgch-catalog-title">' + escapeHtml(spec.title) + '</span>' +
              '<span class="cgch-catalog-status">可用</span>' +
            '</span>' +
            '<span class="cgch-catalog-desc">' + escapeHtml(spec.desc) + '</span>' +
          '</span>' +
          '<span class="cgch-catalog-arrow">' + icon("arrow") + '</span>' +
        '</button>'
      );
    }).join("");
    el.innerHTML = '<div class="cgch-catalog-grid" data-testid="cgc-catalog">' + cards + '</div>';
    el.querySelectorAll("[data-catalog]").forEach(function (card) {
      card.addEventListener("click", function () {
        const key = card.getAttribute("data-catalog");
        const spec = catalogSpecs().find(function (s) { return s.key === key; });
        if (!spec) return;
        if (spec.action === "session") {
          startAssistantSession();
        } else if (spec.action === "session-admin") {
          startAdminSession();
        } else if (spec.action === "workspace") {
          Clacky.ext.ui.openWorkspace(spec.target);
        } else if (spec.action === "web") {
          window.open(webUrl, "_blank", "noopener");
        }
      });
    });
  }

  function setCatalogBusy(key, busy) {
    const card = currentContainer && currentContainer.querySelector('[data-catalog="' + key + '"]');
    if (card) card.classList.toggle("is-busy", busy);
  }

  // ---- 连接网站:创建会话并注入连接请求(agent 按 onboarding CDP SOP 自动完成) ----
  function startConnectSession() {
    if (sessionBusy) return;
    sessionBusy = true;
    setCatalogBusy("chat", true);

    fetch("/api/sessions", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        name: "连接 CGC-2046",
        agent_profile: AGENT_PROFILE,
        source: "manual"
      })
    })
      .then(function (res) { return res.json().catch(function () { return {}; }); })
      .then(function (payload) {
        const session = payload.session;
        if (!session || !session.id) throw new Error("没有创建可用的助手会话");
        if (Clacky.Sessions && typeof Clacky.Sessions.add === "function") {
          Clacky.Sessions.add(session);
          if (typeof Clacky.Sessions.renderList === "function") Clacky.Sessions.renderList();
          Clacky.Sessions.select(session.id);
        } else if (Clacky.Router && typeof Clacky.Router.navigate === "function") {
          Clacky.Router.navigate("session", { id: session.id });
        }
        // 会话就绪后注入连接请求(agent 按 onboarding「CDP 自动连接」SOP 执行;
        // btn-send 订阅确认前禁用,injectIntoComposer 已处理等待补发)
        const instruction = [
          "用户刚在「程序媛汇 2046」面板点击了「连接网站」，请自动完成 CGC-2046 连接：",
          "按 cgc2046-onboarding skill 的「首选路径：CDP 自动连接」执行——",
          "用宿主自带的 browser 工具接管用户真实 Chrome 打开网站 MCP 页(零配置,不需要",
          "让用户开 remote debugging;注意登录态,未登录先提醒用户),",
          "签发 token 后点页面「复制」按钮,再执行剪贴板管道命令写入配置,",
          "最后断言连接成功并汇报。绝不让 token 出现在对话或工具参数里。",
          "若浏览器自动化不可用,回退 skill 的人工引导流程。"
        ].join("\n");
        setTimeout(function () { injectIntoComposer(instruction); }, 1500);
      })
      .catch(function (e) {
        toast(String(e.message || e), "error");
      })
      .finally(function () {
        sessionBusy = false;
        setCatalogBusy("chat", false);
      });
  }

  // ---- 工作台管理助手(cgc-admin):创建会话并注入管理指令 ----
  function startAdminSession(instruction) {
    if (sessionBusy) return;
    sessionBusy = true;
    setCatalogBusy("wsadmin", true);

    fetch("/api/sessions", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        name: "CGC 管理助手",
        agent_profile: "cgc-admin",
        source: "manual"
      })
    })
      .then(function (res) { return res.json().catch(function () { return {}; }); })
      .then(function (payload) {
        const session = payload.session;
        if (!session || !session.id) throw new Error("没有创建可用的管理会话");
        if (Clacky.Sessions && typeof Clacky.Sessions.add === "function") {
          Clacky.Sessions.add(session);
          if (typeof Clacky.Sessions.renderList === "function") Clacky.Sessions.renderList();
          Clacky.Sessions.select(session.id);
        } else if (Clacky.Router && typeof Clacky.Router.navigate === "function") {
          Clacky.Router.navigate("session", { id: session.id });
        }
        // 管理指令:任务行点击带处理指令;目录卡默认先读身份确认权限,然后等用户指令
        const text = instruction || [
          "请作为 CGC 管理助手帮助我。",
          "先调 list_my_workspaces 确认我的工作台与角色，",
          "然后告诉我你可以帮我做什么(创建课程/成员管理/审批/邀请)。",
          "等待我的具体需求。"
        ].join("\n");
        setTimeout(function () { injectIntoComposer(text); }, 1500);
      })
      .catch(function (e) {
        toast(String(e.message || e), "error");
      })
      .finally(function () {
        sessionBusy = false;
        setCatalogBusy("wsadmin", false);
      });
  }

  // contenteditable 注入(宿主 #user-input 是 DIV 非 textarea;发送按钮订阅确认前
  // 禁用,轮询待启用补发——cgc-learn 面板真机实证同款管道,走共享骨架)。
  // 历史注:本文件曾有两个 injectIntoComposer 定义(372 toast 兜底被 434 prompt
  // 兜底覆盖为死代码);归一保留 prompt 兜底语义(原生效行为)。
  function injectIntoComposer(text) {
    const input = document.getElementById("user-input");
    const send = document.getElementById("btn-send");
    if (!input || !send) {
      window.prompt("复制以下指令到管理会话:", text);
      return;
    }
    Kit.injectIntoComposer(input, send, text);
  }

  // ---- 一键进助手会话(S3;青狮工作台 view.js 同款通道) ----
  function startAssistantSession(instruction) {
    if (sessionBusy) return;
    sessionBusy = true;
    setCatalogBusy("chat", true);

    fetch("/api/sessions", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        name: "CGC-2046 助手",
        agent_profile: AGENT_PROFILE,
        source: "manual"
      })
    })
      .then(function (res) { return res.json().catch(function () { return {}; }); })
      .then(function (payload) {
        const session = payload.session;
        if (!session || !session.id) throw new Error("没有创建可用的助手会话");
        if (Clacky.Sessions && typeof Clacky.Sessions.add === "function") {
          Clacky.Sessions.add(session);
          if (typeof Clacky.Sessions.renderList === "function") Clacky.Sessions.renderList();
          Clacky.Sessions.select(session.id);
        } else if (Clacky.Router && typeof Clacky.Router.navigate === "function") {
          // 宿主无 Sessions API 时退化为路由直达(会话列表稍后自行同步)
          Clacky.Router.navigate("session", { id: session.id });
        } else {
          toast("会话已创建,请在会话列表中打开", "info");
        }
        // 任务行点击带处理指令时注入(admin 版 :483 同款延迟管道)
        if (instruction) setTimeout(function () { injectIntoComposer(instruction); }, 1500);
      })
      .catch(function (e) {
        toast(String(e.message || e), "error");
      })
      .finally(function () {
        sessionBusy = false;
        setCatalogBusy("chat", false);
      });
  }

  // ---- 身份区 / Workspace 选择器(自原 workspace 面板迁移) ----
  async function loadWorkspaces(container) {
    const idEl = container.querySelector("#cgc-identity");
    const pickerEl = container.querySelector("#cgc-picker-slot");
    const tasksEl = container.querySelector("#cgc-tasks");
    try {
      const res = await fetch(API + "/me/workspaces", { headers: { Accept: "application/json" } });
      const body = await res.json().catch(function () { return {}; });
      if (!res.ok) throw new Error(body.error || ("HTTP " + res.status));

      const result = body.result || {};
      workspaces = Array.isArray(result.workspaces) ? result.workspaces : [];
      isPlatformAdmin = !!result.is_platform_admin;

      // 选中解析:持久化 id 仍在列表中则沿用,否则回退第一项;列表为空不动存储(可能是瞬态)
      const stored = localStorage.getItem(LS_WORKSPACE) || "";
      const found = workspaces.find(function (w) { return w.workspace_id === stored; });
      const chosen = found || workspaces[0] || null;
      selectedWorkspaceId = chosen ? String(chosen.workspace_id) : "";
      if (chosen) localStorage.setItem(LS_WORKSPACE, selectedWorkspaceId);

      renderIdentity(container);
      renderCatalog();
      loadTasks(container);
    } catch (e) {
      workspaces = [];
      isPlatformAdmin = false;
      selectedWorkspaceId = "";
      if (idEl) idEl.innerHTML = '<span class="cgch-err">加载 Workspace 列表失败：' + escapeHtml(String(e.message || e)) + '</span>';
      if (pickerEl) pickerEl.innerHTML = "";
      if (tasksEl) tasksEl.innerHTML = '<div class="cgch-err">任务加载失败</div>';
    }
  }

  function renderIdentity(container) {
    const idEl = container.querySelector("#cgc-identity");
    const pickerEl = container.querySelector("#cgc-picker-slot");
    if (!idEl || !pickerEl) return;

    const current = workspaces.find(function (w) { return w.workspace_id === selectedWorkspaceId; });
    let html = "";
    if (isPlatformAdmin) html += '<span class="cgch-chip cgch-chip-admin">平台管理模式</span>';
    if (current) {
      html += '<span class="cgch-identity-line">当前：<b>' + escapeHtml(current.name || current.slug || "") + '</b></span>';
      (Array.isArray(current.roles) ? current.roles : []).forEach(function (r) {
        html += '<span class="cgch-chip">' + escapeHtml(r) + '</span>';
      });
      // 管理入口:选中工作台角色含 owner/admin 时显示网站成员管理页链接
      const roles = Array.isArray(current.roles) ? current.roles : [];
      const isManager = roles.indexOf("owner") !== -1 || roles.indexOf("admin") !== -1;
      if (isManager && webUrl && current.slug) {
        html += '<a class="btn-secondary cgch-btn-sm" href="' +
                escapeHtml(webUrl.replace(/\/+$/, "")) + '/w/' + encodeURIComponent(current.slug) +
                '/settings/members" target="_blank" rel="noopener noreferrer">管理</a>';
      }
    }
    idEl.innerHTML = html || '<span class="cgch-empty">无可访问的 Workspace</span>';

    if (workspaces.length === 0) {
      pickerEl.innerHTML = "";
      return;
    }
    const opts = workspaces.map(function (w) {
      const sel = w.workspace_id === selectedWorkspaceId ? " selected" : "";
      return '<option value="' + escapeHtml(w.workspace_id) + '"' + sel + '>' +
             escapeHtml(w.name || w.slug || w.workspace_id) + '</option>';
    }).join("");
    pickerEl.innerHTML =
      '<label class="cgch-picker-label" for="cgc-ws-select">Workspace</label>' +
      '<select id="cgc-ws-select" class="cgch-select">' + opts + '</select>';
  }

  function selectWorkspace(container, id) {
    selectedWorkspaceId = id;
    localStorage.setItem(LS_WORKSPACE, id);
    renderIdentity(container);
    loadTasks(container);
  }

  // ---- 我的任务(session-row 行列表风格) ----
  const TEACH_PANEL = "cgc-2046-curriculum";
  // kind → 中文标签 + 路由:prep 三类 = 教研行(tutor 跳面板,非 tutor 注入助手会话);
  // approval 三类 = 审批行(仅 owner/admin 收得到,注入管理会话)
  const TASK_KINDS = {
    course_prep_claimable: { label: "教研认领", panel: TEACH_PANEL, prep: true },
    course_prep_authoring: { label: "教研编写", panel: TEACH_PANEL, prep: true },
    course_prep_review:    { label: "教研审核", panel: TEACH_PANEL, prep: true },
    enrollment_approval:   { label: "报名审批", admin: true },
    join_request:          { label: "加入申请", admin: true },
    sponsorship_review:    { label: "赞助审核", admin: true }
  };

  function taskKindLabel(kind) {
    const meta = TASK_KINDS[kind];
    return meta ? meta.label : kind || "";
  }

  // 任务行注入指令(纪律对齐 admin-aside taskPrompt:ws/标题折单行,requester/
  // 邮箱等 PII 不进指令本体,末尾 DATA_NOTE)
  function taskInstruction(t) {
    const ws = Kit.oneLine(t._ws_name || "");
    const title = Kit.oneLine(t.context_title || t.title || "");
    return "请处理 " + ws + "工作台的" + taskKindLabel(t.kind) + "待办" + (title ? "：" + title : "") +
      "。先调用 list_my_tasks 获取该待办详情，再按 playbook 流程处理。\n" + Kit.DATA_NOTE;
  }

  function taskSummary(t) {
    const requester = t.requester_name ? String(t.requester_name) : "";
    const context = t.context_title ? String(t.context_title) : "";
    if (requester && context) return requester + " → " + context;
    if (context) return context;
    if (requester) return requester;
    const cand = [t.title, t.name, t.summary, t.key];
    for (let i = 0; i < cand.length; i++) {
      if (cand[i]) return String(cand[i]);
    }
    return t.id ? String(t.id).slice(0, 8) + "…" : "";
  }

  function taskDeadline(t) {
    if (!t.approval_deadline) return "";
    const d = new Date(t.approval_deadline);
    const text = isNaN(d.getTime()) ? String(t.approval_deadline) : d.toLocaleString();
    return '<span class="cgch-row-meta">截止 ' + escapeHtml(text) + '</span>';
  }

  async function loadTasks(container) {
    const tasksEl = container.querySelector("#cgc-tasks");
    if (!tasksEl) return;
    if (workspaces.length === 0) {
      tasksEl.innerHTML = '<div class="cgch-empty">暂无待办</div>';
      return;
    }
    tasksEl.innerHTML = '<div class="cgch-empty">加载中…</div>';
    try {
      // 聚合所有工作台的待办(不按当前选中台过滤——多台用户的任务不该被选中态遮蔽);
      // allSettled:单台失败不拖空白单(跳过该台)
      const settled = await Promise.allSettled(workspaces.map(function (w) {
        return fetch(API + "/tasks?workspace_id=" + encodeURIComponent(w.workspace_id), {
          headers: { Accept: "application/json" }
        }).then(function (res) {
          return res.json().catch(function () { return {}; }).then(function (body) {
            if (!res.ok) throw new Error(body.error || ("HTTP " + res.status));
            const tasks = Array.isArray((body.result || {}).tasks) ? body.result.tasks : [];
            return { name: w.name || "", ws_id: w.workspace_id, roles: Array.isArray(w.roles) ? w.roles : [], tasks: tasks };
          });
        });
      }));
      const fulfilled = settled.filter(function (r) { return r.status === "fulfilled"; });
      // 全部失败 ≠ 暂无待办——空态会掩盖后端不可用/token 过期(与被选中台遮蔽同款静默错)
      if (fulfilled.length === 0) {
        tasksEl.innerHTML = '<div class="cgch-err">待办加载失败：所有工作台请求均未成功</div>';
        return;
      }
      const tasks = fulfilled.flatMap(function (r) {
        return r.value.tasks.map(function (t) {
          t._ws_name = r.value.name;
          t._ws_id = r.value.ws_id;
          t._ws_roles = r.value.roles;
          return t;
        });
      });
      if (tasks.length === 0) {
        tasksEl.innerHTML = '<div class="cgch-empty">暂无待办</div>';
        return;
      }
      const rows = tasks.map(function (t, idx) {
        return (
          '<div class="cgch-row" data-task-idx="' + idx + '" style="cursor:pointer" data-testid="cgc-task-row">' +
            '<span class="cgch-chip">' + escapeHtml(taskKindLabel(t.kind)) + '</span>' +
            '<span class="cgch-row-copy">' + escapeHtml(t._ws_name ? "[" + t._ws_name + "] " : "") + escapeHtml(taskSummary(t)) + '</span>' +
            taskDeadline(t) +
            '<span class="cgch-row-arrow">' + icon("arrow") + '</span>' +
          '</div>'
        );
      }).join("");
      tasksEl.innerHTML = '<div class="cgch-row-list">' + rows + '</div>';
      tasksEl.querySelectorAll("[data-task-idx]").forEach(function (row) {
        row.addEventListener("click", function () {
          const t = tasks[Number(row.getAttribute("data-task-idx"))];
          const meta = TASK_KINDS[t.kind] || {};
          const roles = Array.isArray(t._ws_roles) ? t._ws_roles : [];
          if (meta.prep && roles.indexOf("tutor") !== -1) {
            Clacky.ext.ui.openWorkspace(meta.panel);   // 教研行 + 该台 tutor → 面板
          } else if (meta.prep) {
            startAssistantSession(taskInstruction(t));  // 教研行 + 非 tutor(如被指定的 reviewer) → 注入助手会话
          } else {
            startAdminSession(taskInstruction(t));      // 审批行(仅 owner/admin 收得到) → 注入管理会话
          }
        });
      });
    } catch (e) {
      tasksEl.innerHTML = '<div class="cgch-err">加载失败：' + escapeHtml(String(e.message || e)) + '</div>';
    }
  }

  // ---- 最近会话(青狮同款:可点击进入 session) ----
  function sessionActivityTime(s) {
    const v = s && (s.updated_at || s.created_at);
    const t = v ? new Date(v).getTime() : 0;
    return Number.isFinite(t) ? t : 0;
  }

  function formatSessionTime(epochMs) {
    if (!epochMs) return "";
    const d = new Date(epochMs);
    const now = Date.now();
    const diff = now - epochMs;
    if (diff < 60 * 60 * 1000) return Math.max(1, Math.round(diff / 60000)) + " 分钟前";
    if (d.toDateString() === new Date().toDateString()) return d.toLocaleTimeString();
    return d.toLocaleDateString();
  }

  function localSessions() {
    return Clacky.Sessions && Array.isArray(Clacky.Sessions.all) ? Clacky.Sessions.all.slice() : [];
  }

  async function loadRecentSessions(container) {
    try {
      const res = await fetch("/api/sessions?limit=50", { headers: { Accept: "application/json" } });
      const body = await res.json().catch(function () { return {}; });
      const remote = Array.isArray(body.sessions) ? body.sessions : [];
      const byId = new Map();
      [remote, localSessions()].forEach(function (list) {
        list.forEach(function (s) { if (s && s.id) byId.set(s.id, Object.assign({}, byId.get(s.id) || {}, s)); });
      });
      allSessions = Array.from(byId.values());
    } catch (e) {
      allSessions = localSessions(); // 拉取失败用本地列表
    }
    renderSessionRows(container);
  }

  // 按当前 Tab 过滤渲染;行点击进入会话(青狮同款 Router.navigate 通道)
  function renderSessionRows(container) {
    const el = container && container.querySelector("#cgc-recent-sessions");
    if (!el) return;

    const mine = allSessions
      .filter(function (s) {
        if (!SESSION_AGENTS[s.agent_profile]) return false;
        return sessionTab === "all" || s.agent_profile === sessionTab;
      })
      .sort(function (a, b) { return sessionActivityTime(b) - sessionActivityTime(a); })
      .slice(0, 20); // 三助手同框后 6 条太紧;接口拉 50,展示 20,滚动由卡片容器承担

    if (mine.length === 0) {
      const label = sessionTab === "all" ? "" : SESSION_AGENTS[sessionTab];
      el.innerHTML = '<div class="cgch-empty">还没有' + escapeHtml(label) +
        '会话。点功能目录对应卡片开始。</div>';
      return;
    }
    el.innerHTML = '<div class="cgch-row-list">' + mine.map(function (s) {
      const running = s.status === "running";
      const agentLabel = SESSION_AGENTS[s.agent_profile] || "";
      const meta = [agentLabel, formatSessionTime(sessionActivityTime(s))].filter(Boolean).join(" · ");
      return (
        '<button class="cgch-row cgch-session-row" type="button" data-session="' + escapeHtml(s.id) + '"' +
              ' data-testid="cgc-recent-session" data-agent="' + escapeHtml(s.agent_profile) + '">' +
          '<span class="cgch-row-dot' + (running ? " is-running" : "") + '"></span>' +
          '<span class="cgch-row-copy">' + escapeHtml(s.name || agentLabel + "会话") + '</span>' +
          '<span class="cgch-row-meta">' + escapeHtml(meta) + '</span>' +
          '<span class="cgch-row-arrow">' + icon("arrow") + '</span>' +
        '</button>'
      );
    }).join("") + '</div>';
    el.querySelectorAll("[data-session]").forEach(function (row) {
      row.addEventListener("click", function () {
        const id = row.getAttribute("data-session");
        if (Clacky.Router && typeof Clacky.Router.navigate === "function") {
          Clacky.Router.navigate("session", { id: id });
        }
      });
    });
  }


  // ---- 连接状态 / 断开(自原 workspace 面板迁移,含 DELETE CSRF 自愈) ----
  async function refresh(container) {
    const identityEl = container.querySelector("#cgc-identity-wrap");
    const discEl = container.querySelector("#cgc-disconnect");
    discEl.disabled = true;

    let st;
    try {
      const res = await fetch(API + "/status", { headers: { Accept: "application/json" } });
      st = await res.json().catch(function () { return {}; });
      if (!res.ok || !st.ok) throw new Error(st.error || ("HTTP " + res.status));
    } catch (e) {
      configured = false;
      setPill("状态获取失败", "cgch-pill-off");
      renderCatalog();
      if (identityEl) identityEl.style.display = "none";
      return;
    }

    configured = !!st.configured;
    Kit.csrfFromStatus(st);
    // scheme 门(安全评审低危#4):非法 scheme ≡ 未配置——下游(打开网站锚/管理
    // 深链/平台管理卡)全部走既有"隐藏"降级;合法 localhost http 联调放行
    webUrl = Kit.safeWebUrl(st.web_url) || "";

    setPill(configured ? "MCP 已连接" : "未连接", configured ? "cgch-pill-on" : "cgch-pill-off");
    // 副标题保持静态目录文案:端点 URL/Token 状态属敏感运维细节,不在 hub 透出
    // (版本徽标独立渲染,见 loadVersion;连接状态由 pill 表达)
    const webEl = container.querySelector("#cgc-open-web");
    // 未连接态:按钮切换为「连接网站」——confirm 后创建会话并注入连接请求,
    // agent 按 onboarding「CDP 自动连接」SOP 自动完成(token 不进对话)
    discEl.textContent = configured ? "断开连接" : "连接网站";
    discEl.className = "btn-secondary" + (configured ? " cgch-btn-danger" : "");
    discEl.disabled = false;
    discEl.dataset.mode = configured ? "disconnect" : "connect";
    if (webUrl) {
      webEl.href = webUrl;
      webEl.style.display = "";
    } else {
      webEl.style.display = "none";
    }

    // 已连接才展开身份区与角色目录(数据走 loopback,未连接必 503)
    if (st.configured) {
      if (identityEl) identityEl.style.display = "";
      loadWorkspaces(container);
      // 连接健康检查(plan 020):配置在 ≠ 连接可用,异步真实握手探活,
      // 结果只反映在 pill/横幅,不阻塞身份区与目录渲染
      probeConnection(container);
    } else {
      if (identityEl) identityEl.style.display = "none";
    }
    renderCatalog();
  }

  // GET /health:真实握手探测(R4)。配置在但探不通 → 「连接异常」+ 横幅引导。
  // 探活只改 pill/横幅,不阻塞目录与身份区渲染;
  // 三态:「MCP 已连接」(握手 OK)/「连接异常」(探不通)/「未连接」(未配置)。
  function probeConnection(container) {
    rawGet("/health")   // 共享封装已带 /api/ext/cgc-2046 基前缀
      .then(function (h) {
        if (h && h.ok && h.handshake) {
          setPill("MCP 已连接", "cgch-pill-on");
        } else {
          setPill("连接异常", "cgch-pill-off");
          mcpError = (h && h.error) ? String(h.error) : "MCP 握手未通过";
          renderMcpBanner(container);
        }
      })
      .catch(function (e) {
        setPill("连接异常", "cgch-pill-off");
        // rawGet 对非 2xx 抛错挂 body——502 的「连接探测失败: …」照常透出;
        // 网络层失败(扩展服务不可达)落通用引导文案
        mcpError = (e && e.body && e.body.error) ? String(e.body.error)
          : "健康检查请求失败(扩展服务不可达?)";
        renderMcpBanner(container);
      });
  }

  async function disconnect(container) {
    if (!window.confirm("确认断开 CGC-2046 连接？将移除 mcp.json 中的 cgc-2046 条目。")) return;

    const discEl = container.querySelector("#cgc-disconnect");
    discEl.disabled = true;

    try {
      await Kit.apiDelete("/connect");
      toast("已断开连接,可点「连接网站」重新连接", "success");
      await refresh(container);
    } catch (e) {
      window.alert("断开失败：" + String(e.message || e));
      discEl.disabled = false;
    }
  }



  // ---- 扩展事件总线订阅 ----
  // tool_used 事件由 admin/tutor 侧栏消费(刷新闭环),home 面板不再订阅;
  // mcp_error 只驱动连接异常横幅(不推对话、不落盘)。
  function onMcpError(payload) {
    mcpError = String(payload.error || "未知连接错误").slice(0, 300);
    if (currentContainer) renderMcpBanner(currentContainer);
  }

  // ---- 样式(青狮设计语言:宿主 CSS 变量体系,明暗主题自适应) ----
  function injectStyles() {
    if (document.getElementById("cgc-home-styles")) return;
    const style = document.createElement("style");
    style.id = "cgc-home-styles";
    style.textContent = `
.cgch-page {
  min-height: 100%;
  box-sizing: border-box;
  padding: 32px clamp(24px, 4vw, 64px) 56px;
  color: var(--color-text-primary);
  background:
    radial-gradient(circle at 94% 4%, var(--color-accent-soft), transparent 24rem),
    var(--color-bg-secondary);
}
.cgch-page code { font-family: ui-monospace, Menlo, monospace; }

/* page header */
.cgch-header {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 24px;
  max-width: 1120px;
  margin: 0 auto 28px;
}
.cgch-brand { display: flex; align-items: flex-start; gap: 16px; min-width: 0; }
.cgch-brand-icon {
  display: inline-flex; align-items: center; justify-content: center;
  width: 48px; height: 48px; padding: 12px; box-sizing: border-box; flex: none;
  color: var(--color-accent-primary);
  background: var(--color-accent-soft);
  border: 1px solid color-mix(in srgb, var(--color-accent-primary) 24%, var(--color-border-primary));
  border-radius: var(--radius-lg, 10px);
  box-shadow: var(--shadow-xs);
}
.cgch-brand-icon svg { width: 100%; height: 100%; }
.cgch-title-row { display: flex; align-items: center; flex-wrap: wrap; gap: 10px; }
.cgch-title { margin: 0; font-size: 1.25rem; font-weight: 700; letter-spacing: -0.01em; }
.cgch-subtitle { margin: 4px 0 0; color: var(--color-text-tertiary); font-size: 0.8125rem; }
.cgch-pill {
  display: inline-flex; align-items: center; min-height: 20px; padding: 0 8px;
  border-radius: 999px; font-size: 0.6875rem; font-weight: 650; line-height: 1;
  color: var(--color-text-secondary);
  background: var(--color-bg-hover);
  border: 1px solid var(--color-border-secondary);
}
.cgch-pill-on {
  color: var(--color-accent-primary);
  background: var(--color-accent-soft);
  border-color: color-mix(in srgb, var(--color-accent-primary) 24%, var(--color-border-primary));
}
.cgch-pill-off { color: var(--color-warning, #a16207); }
.cgch-version-badge {
  display: inline-flex; align-items: center; min-height: 18px; padding: 0 7px;
  border-radius: 6px; font-size: 0.6875rem; font-weight: 650; line-height: 1;
  font-family: var(--font-mono, ui-monospace, monospace);
  color: var(--color-text-tertiary);
  background: var(--color-bg-hover);
  border: 1px solid var(--color-border-secondary);
}
.cgch-header-actions { display: flex; align-items: center; flex: none; gap: 10px; }

/* buttons:基类直接用宿主 .btn-secondary;此处仅保留 danger 幽灵红修饰 + sm 尺寸工具 */
.cgch-page a.btn-secondary { text-decoration: none; }
.cgch-btn-danger {
  color: var(--color-error, #c0392b);
  border-color: color-mix(in srgb, var(--color-error, #c0392b) 32%, var(--color-border-primary));
}
.cgch-btn-danger:hover:not(:disabled) {
  background: color-mix(in srgb, var(--color-error, #c0392b) 8%, var(--color-bg-card));
}
.cgch-btn-danger:disabled { opacity: 0.45; cursor: not-allowed; box-shadow: none; }
.cgch-btn-sm { padding: 4px 10px; font-size: 0.6875rem; }

/* sections */
.cgch-section { max-width: 1120px; margin: 0 auto 26px; }
.cgch-section-header {
  display: flex; align-items: flex-end; justify-content: space-between;
  gap: 16px; margin-bottom: 10px;
}
.cgch-section-title { font-size: 0.9375rem; font-weight: 680; }
.cgch-section-desc { margin-top: 2px; color: var(--color-text-tertiary); font-size: 0.75rem; }

/* session tabs */
.cgch-tabs {
  display: inline-flex; align-items: center; gap: 2px; padding: 2px;
  background: var(--color-bg-hover);
  border: 1px solid var(--color-border-secondary);
  border-radius: var(--radius-md, 8px);
}
.cgch-tab {
  padding: 4px 10px; border: none; border-radius: calc(var(--radius-md, 8px) - 2px);
  font-size: 0.6875rem; font-weight: 600; cursor: pointer;
  color: var(--color-text-tertiary); background: transparent;
  transition: color var(--transition-fast, 120ms), background var(--transition-fast, 120ms);
}
.cgch-tab:hover { color: var(--color-text-secondary); }
.cgch-tab.is-active {
  color: var(--color-text-primary);
  background: var(--color-bg-card);
  box-shadow: var(--shadow-xs, 0 1px 2px rgba(0,0,0,0.06));
}

/* cards */
.cgch-card {
  box-sizing: border-box; padding: 14px 16px;
  background: var(--color-bg-card);
  border: 1px solid var(--color-border-primary);
  border-radius: var(--radius-lg, 10px);
  box-shadow: var(--shadow-xs);
  font-size: 0.8125rem; line-height: 1.7;
}

/* 未连接引导(error 态卡,青狮 overview-error 同款) */
.cgch-guide {
  display: flex; gap: 14px; align-items: flex-start; max-width: 1120px; margin: 0 auto;
  box-sizing: border-box; padding: 20px 18px;
  background: var(--color-bg-card);
  border: 1px solid var(--color-border-primary);
  border-radius: var(--radius-lg, 10px);
  box-shadow: var(--shadow-xs);
}
.cgch-guide-icon {
  display: inline-flex; align-items: center; justify-content: center; flex: none;
  width: 36px; height: 36px; padding: 9px; box-sizing: border-box;
  color: var(--color-text-tertiary);
  background: var(--color-bg-hover);
  border-radius: var(--radius-md, 8px);
}
.cgch-guide-icon svg { width: 100%; height: 100%; }
.cgch-guide-title { font-size: 0.875rem; font-weight: 620; }
.cgch-guide-desc { margin-top: 5px; color: var(--color-text-secondary); font-size: 0.75rem; line-height: 1.6; }
.cgch-connect-form {
  max-width: 1120px; margin: 14px auto 26px; box-sizing: border-box; padding: 16px 18px;
  background: var(--color-bg-card);
  border: 1px solid var(--color-border-primary);
  border-radius: var(--radius-lg, 10px);
  box-shadow: var(--shadow-xs);
}
.cgch-form-row { display: flex; gap: 10px; align-items: center; margin-bottom: 10px; }
.cgch-form-row:last-child { margin-bottom: 0; }
.cgch-input {
  flex: 1; min-width: 0; padding: 8px 12px;
  border: 1px solid var(--color-border-primary); border-radius: var(--radius-md, 8px);
  background: var(--color-bg-primary, var(--color-bg-card)); color: var(--color-text-primary);
  font-size: 0.8125rem; font-family: ui-monospace, Menlo, monospace;
}
.cgch-input:focus { outline: none; border-color: var(--color-accent-primary); }

/* 功能目录(extension-card 同款:icon 容器/名称/状态 pill/描述/箭头) */
.cgch-catalog-grid {
  display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 14px;
}
.cgch-catalog-card {
  display: flex; align-items: center; gap: 12px; min-height: 104px;
  padding: 16px; text-align: left; cursor: pointer;
  color: var(--color-text-primary); font: inherit;
  background: var(--color-bg-card);
  border: 1px solid var(--color-border-primary);
  border-radius: var(--radius-lg, 10px);
  box-shadow: var(--shadow-xs);
  transition: border-color var(--transition-fast), box-shadow var(--transition-fast);
}
.cgch-catalog-card:hover { border-color: var(--color-border-strong); box-shadow: var(--shadow-sm); }
.cgch-catalog-card.is-busy { opacity: 0.72; }
.cgch-catalog-card:focus-visible { outline: 2px solid var(--color-accent-primary); outline-offset: 2px; }
.cgch-catalog-icon {
  display: inline-flex; align-items: center; justify-content: center; flex: none;
  width: 42px; height: 42px; padding: 10px; box-sizing: border-box;
  color: var(--color-accent-primary);
  background: var(--color-accent-soft);
  border: 1px solid color-mix(in srgb, var(--color-accent-primary) 20%, var(--color-border-primary));
  border-radius: var(--radius-lg, 10px);
}
.cgch-catalog-icon svg { width: 100%; height: 100%; }
.cgch-catalog-copy { display: flex; flex: 1; flex-direction: column; min-width: 0; }
.cgch-catalog-heading { display: flex; align-items: center; flex-wrap: wrap; gap: 8px; }
.cgch-catalog-title { font-size: 0.9375rem; font-weight: 650; }
.cgch-catalog-status {
  display: inline-flex; align-items: center; min-height: 18px; padding: 0 7px;
  color: var(--color-accent-primary);
  background: var(--color-accent-soft);
  border: 1px solid color-mix(in srgb, var(--color-accent-primary) 24%, var(--color-border-primary));
  border-radius: 999px; font-size: 0.625rem; font-weight: 650; line-height: 1;
}
.cgch-catalog-desc { margin-top: 5px; color: var(--color-text-secondary); font-size: 0.75rem; line-height: 1.5; }
.cgch-catalog-arrow {
  width: 16px; height: 16px; flex: none;
  color: var(--color-text-muted);
  transition: transform var(--transition-fast), color var(--transition-fast);
}
.cgch-catalog-arrow svg { width: 100%; height: 100%; }
.cgch-catalog-card:hover .cgch-catalog-arrow { transform: translateX(2px); color: var(--color-text-secondary); }

/* 行列表(任务/活动,session-row 同款) */
.cgch-row-list { display: flex; flex-direction: column; }
.cgch-row {
  display: flex; gap: 10px; align-items: baseline; padding: 8px 6px;
  border-bottom: 1px solid var(--color-border-secondary);
  font-size: 0.8125rem;
}
.cgch-row:last-child { border-bottom: 0; }
.cgch-row:hover { background: var(--color-bg-hover); }
.cgch-row-copy { flex: 1; min-width: 0; word-break: break-all; }
.cgch-row-time { flex: none; color: var(--color-text-tertiary); font-size: 0.6875rem; }
.cgch-row-meta { flex: none; color: var(--color-text-tertiary); font-size: 0.6875rem; }
.cgch-row-arrow {
  width: 14px; height: 14px; flex: none; align-self: center;
  color: var(--color-text-muted);
  transition: transform var(--transition-fast), color var(--transition-fast);
}
.cgch-row-arrow svg { width: 100%; height: 100%; }
.cgch-row:hover .cgch-row-arrow { transform: translateX(2px); color: var(--color-text-secondary); }
.cgch-ok { flex: none; color: var(--color-success, #27ae60); }
.cgch-session-row {
  width: 100%; background: transparent; border: 0; border-bottom: 1px solid var(--color-border-secondary);
  border-radius: 0; color: inherit; font: inherit; cursor: pointer; text-align: left;
}
.cgch-session-row:last-child { border-bottom: 0; }
.cgch-row-dot {
  flex: none; align-self: center; width: 7px; height: 7px; border-radius: 999px;
  background: var(--color-border-secondary);
}
.cgch-row-dot.is-running { background: var(--color-success, #27ae60); }
.cgch-err { flex: none; color: var(--color-error, #c0392b); }

/* 身份 chips / 选择器 */
.cgch-identity {
  display: flex; gap: 8px; align-items: baseline; flex-wrap: wrap; margin-bottom: 10px;
}
.cgch-identity-line { font-size: 0.8125rem; }
.cgch-chip {
  display: inline-flex; align-items: center; padding: 0 8px; min-height: 20px;
  color: var(--color-text-secondary);
  background: var(--color-bg-hover);
  border: 1px solid var(--color-border-secondary);
  border-radius: 999px; font-size: 0.6875rem; font-weight: 650; line-height: 1;
}
.cgch-chip-admin {
  color: var(--color-accent-primary);
  background: var(--color-accent-soft);
  border-color: color-mix(in srgb, var(--color-accent-primary) 24%, var(--color-border-primary));
}
.cgch-picker-label { font-size: 0.75rem; color: var(--color-text-tertiary); margin-right: 8px; }
.cgch-select {
  padding: 5px 10px; border: 1px solid var(--color-border-primary); border-radius: var(--radius-md, 8px);
  background: var(--color-bg-card); color: inherit; font-size: 0.8125rem; margin-bottom: 10px;
}

/* 横幅 / 空态 / 错误 */
.cgch-banner {
  border: 1px solid color-mix(in srgb, var(--color-error, #c0392b) 40%, var(--color-border-primary));
  background: color-mix(in srgb, var(--color-error, #c0392b) 7%, var(--color-bg-card));
  border-radius: var(--radius-md, 8px); padding: 10px 12px; margin-bottom: 10px;
  color: var(--color-error, #c0392b); font-size: 0.8125rem;
}
.cgch-banner-hint { margin-top: 4px; opacity: 0.85; }
.cgch-empty { color: var(--color-text-tertiary); font-size: 0.8125rem; padding: 4px 0; }
.cgch-err { color: var(--color-error, #c0392b); font-size: 0.8125rem; }

@media (max-width: 900px) {
  .cgch-catalog-grid { grid-template-columns: 1fr; }
  .cgch-header { flex-direction: column; }
}
`;
    document.head.appendChild(style);
  }

  // 焦点回归重拉:角色/身份是页面闭包快照,后台变更(如授角色)后回到前台
  // 自动刷新——未连接态不拉(503 会误报错误);无输入态,重渲染安全
  document.addEventListener("visibilitychange", function () {
    if (document.hidden || !currentContainer || !configured) return;
    loadWorkspaces(currentContainer);
  });

  injectStyles();
  Clacky.ext.subscribe("ext.cgc-2046.mcp_error", onMcpError);
  Clacky.ext.ui.registerWorkspace(HOME_ID, { title: "程序媛汇 2046", render: render });
  // order: 1——顶部 slot 内排最前(宿主 ext.js:opts.order 纵向权重,小者在前,
  // 默认 100;青狮/电脑操作等入口默认序,我们压到它们之上)
  Clacky.ext.ui.mount("sidebar.nav.top", navRow, { workspace: HOME_ID, order: 1 });
})();
