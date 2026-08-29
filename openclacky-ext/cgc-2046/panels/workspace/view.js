// CGC-2046 连接面板（v1 薄面板，Issue #100；role-agent-journeys-v2 S1-extension 增加工作台身份区）。
//
// 能力：
//   - 侧边栏入口（sidebar.nav.bottom）→ 打开本面板页
//   - 工作台身份区（已连接时置顶展示，R3/R4）：
//       - 身份栏：身份模式徽章（is_platform_admin →「平台管理模式」）+ 当前 Workspace 名
//         + 角色徽章（GET /me/workspaces 透传 list_my_workspaces）
//       - Workspace 选择器：按名称切换（用户永不手填 workspace_id），选择持久化到
//         localStorage(cgc2046.workspacePanel.workspaceId)；存储 id 失效时回退列表第一项
//       - 我的任务：GET /tasks?workspace_id=<选中>（透传 list_my_tasks），
//         行 = kind 标签 + 摘要（申请人 → 目标资源）+ 截止时间（若有）；空态「暂无待办」；
//         手动刷新按钮
//   - 连接状态卡：configured / url / token_configured（GET /api/ext/cgc-2046/status，脱敏）
//   - 断开连接：DELETE /api/ext/cgc-2046/connect（带 confirm，移除 mcp.json 的 cgc-2046 条目）
//   - 跳转网站（status.web_url，来自 ext.yml config）
//   - 最近活动：订阅扩展事件总线（ext.cgc-2046.*，宿主 Agent#emit_event → ws 路由）
//       - ext.cgc-2046.tool_used —— 每次 CGC MCP 调用完成（hooks/after_tool_use.rb）
//       - ext.cgc-2046.mcp_error —— MCP 连接异常（hooks/on_tool_error.rb），显示引导横幅
//
// 安全红线：面板只展示 status 的布尔/URL 字段、loopback 透传的工作台数据与事件
// 脱敏文本，绝不渲染 token/headers；所有服务端字符串一律经 escapeHtml 渲染。

(() => {
  "use strict";
  if (!window.Clacky || !Clacky.ext || Clacky.ext.pure) return;

  const API = "/api/ext/cgc-2046";
  const WS_ID = "cgc-2046";
  const EVENTS_MAX = 20;
  const LS_WORKSPACE = "cgc2046.workspacePanel.workspaceId";

  // ---- 事件总线状态（闭包内，跨面板开关保持）----
  let events = [];          // { type, tool, status, error, at }
  let mcpError = null;      // 最近的连接异常文本（横幅）
  let currentContainer = null;

  // ---- 工作台身份区状态 ----
  let workspaces = [];        // [{ workspace_id, name, slug, roles }]
  let isPlatformAdmin = false;
  let selectedWorkspaceId = "";

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function pushEvent(ev) {
    events.unshift(ev);
    if (events.length > EVENTS_MAX) events.length = EVENTS_MAX;
  }

  // ---- 侧边栏入口 ----
  function navRow() {
    const item = document.createElement("div");
    item.className = "task-item task-item-summary";
    item.innerHTML =
      '<div class="task-row">' +
        '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" ' +
             'fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" ' +
             'stroke-linejoin="round" class="task-icon">' +
          '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/>' +
          '<path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>' +
        '</svg>' +
        '<div class="task-info"><span class="task-name">CGC-2046</span></div>' +
      '</div>';
    item.addEventListener("click", function () { Clacky.ext.ui.openWorkspace(WS_ID); });
    return item;
  }

  // ---- 面板页 ----
  function render(container) {
    currentContainer = container;
    container.innerHTML =
      '<div class="cgc-panel">' +
        '<h3 class="cgc-panel-title">CGC-2046 连接</h3>' +
        '<p class="cgc-panel-sub">平台 MCP 连接状态与配置管理</p>' +
        '<div class="cgc-card" id="cgc-workbench" style="display:none">' +
          '<div class="cgc-identity" id="cgc-identity">加载中…</div>' +
          '<div id="cgc-picker-slot"></div>' +
          '<div class="cgc-tasks-head">' +
            '<span class="cgc-activity-title">我的任务</span>' +
            '<button id="cgc-tasks-refresh" class="cgc-btn cgc-btn-secondary cgc-btn-mini" type="button">刷新</button>' +
          '</div>' +
          '<div id="cgc-tasks"><div class="cgc-empty">加载中…</div></div>' +
        '</div>' +
        '<div class="cgc-card" id="cgc-status">加载中…</div>' +
        '<div class="cgc-card" id="cgc-activity"></div>' +
        '<div class="cgc-actions">' +
          '<a id="cgc-open-web" class="cgc-btn cgc-btn-secondary" href="#" ' +
             'target="_blank" rel="noopener noreferrer">打开 CGC-2046 网站</a>' +
          '<button id="cgc-disconnect" class="cgc-btn cgc-btn-danger" type="button" disabled>断开连接</button>' +
        '</div>' +
      '</div>';

    const webEl = container.querySelector("#cgc-open-web");
    const discEl = container.querySelector("#cgc-disconnect");
    discEl.addEventListener("click", function () { disconnect(container); });
    // 选择器选项随身份区重渲染而重建,change 监听委托给父卡(不随 option 重建失效)
    container.querySelector("#cgc-workbench").addEventListener("change", function (e) {
      if (e.target && e.target.id === "cgc-ws-select") selectWorkspace(container, e.target.value);
    });
    container.querySelector("#cgc-tasks-refresh").addEventListener("click", function () {
      loadTasks(container);
    });
    renderActivity(container);
    refresh(container, webEl, discEl);
  }

  // ---- 工作台身份区 ----
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
      loadTasks(container);
    } catch (e) {
      workspaces = [];
      isPlatformAdmin = false;
      selectedWorkspaceId = "";
      if (idEl) idEl.innerHTML = '<span class="cgc-ev-err">加载 Workspace 列表失败：' + escapeHtml(String(e.message || e)) + '</span>';
      if (pickerEl) pickerEl.innerHTML = "";
      if (tasksEl) tasksEl.innerHTML = '<div class="cgc-empty">暂无待办</div>';
    }
  }

  function renderIdentity(container) {
    const idEl = container.querySelector("#cgc-identity");
    const pickerEl = container.querySelector("#cgc-picker-slot");
    if (!idEl || !pickerEl) return;

    const current = workspaces.find(function (w) { return w.workspace_id === selectedWorkspaceId; });
    let html = "";
    if (isPlatformAdmin) html += '<span class="cgc-badge cgc-badge-admin">平台管理模式</span>';
    if (current) {
      html += '<span class="cgc-identity-line">当前：<b>' + escapeHtml(current.name || current.slug || "") + '</b></span>';
      (Array.isArray(current.roles) ? current.roles : []).forEach(function (r) {
        html += '<span class="cgc-badge">' + escapeHtml(r) + '</span>';
      });
    }
    idEl.innerHTML = html || '<span class="cgc-empty">无可访问的 Workspace</span>';

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
      '<label class="cgc-picker-label" for="cgc-ws-select">Workspace</label>' +
      '<select id="cgc-ws-select" class="cgc-select">' + opts + '</select>';
  }

  function selectWorkspace(container, id) {
    selectedWorkspaceId = id;
    localStorage.setItem(LS_WORKSPACE, id);
    renderIdentity(container);
    loadTasks(container);
  }

  // 任务行摘要:申请人 → 目标资源(context_title);缺省兜底 id 短码
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
    return '<span class="cgc-ev-time">截止 ' + escapeHtml(text) + '</span>';
  }

  async function loadTasks(container) {
    const tasksEl = container.querySelector("#cgc-tasks");
    if (!tasksEl) return;
    if (!selectedWorkspaceId) {
      tasksEl.innerHTML = '<div class="cgc-empty">暂无待办</div>';
      return;
    }
    tasksEl.innerHTML = '<div class="cgc-empty">加载中…</div>';
    try {
      const res = await fetch(API + "/tasks?workspace_id=" + encodeURIComponent(selectedWorkspaceId), {
        headers: { Accept: "application/json" }
      });
      const body = await res.json().catch(function () { return {}; });
      if (!res.ok) throw new Error(body.error || ("HTTP " + res.status));

      const result = body.result || {};
      const tasks = Array.isArray(result.tasks) ? result.tasks : [];
      if (tasks.length === 0) {
        tasksEl.innerHTML = '<div class="cgc-empty">暂无待办</div>';
        return;
      }
      const rows = tasks.map(function (t) {
        return (
          '<div class="cgc-ev cgc-task-row">' +
            '<span class="cgc-kind">' + escapeHtml(t.kind || "") + '</span>' +
            '<span class="cgc-task-summary">' + escapeHtml(taskSummary(t)) + '</span>' +
            taskDeadline(t) +
          '</div>'
        );
      }).join("");
      tasksEl.innerHTML = '<div class="cgc-ev-list">' + rows + '</div>';
    } catch (e) {
      tasksEl.innerHTML = '<div class="cgc-ev-err">加载失败：' + escapeHtml(String(e.message || e)) + '</div>';
    }
  }

  // 渲染最近活动卡：连接异常横幅（若有）+ 事件列表（倒序，最多 EVENTS_MAX 条）。
  function renderActivity(container) {
    const el = container.querySelector("#cgc-activity");
    if (!el) return;

    let html = '<div class="cgc-activity-title">最近活动</div>';
    if (mcpError) {
      html +=
        '<div class="cgc-banner">' +
          '<b>CGC MCP 连接异常：</b>' + escapeHtml(mcpError) +
          '<div class="cgc-banner-hint">请运行 <code>cgc2046-onboarding</code> skill 重新连接，' +
            '或在网站「MCP」页重新生成 token。</div>' +
        '</div>';
    }
    if (!events.length) {
      html += '<div class="cgc-empty">暂无活动。在 OpenClacky 会话中使用 CGC 助手后，这里会显示调用记录。</div>';
    } else {
      const rows = events.map(function (ev) {
        const status = ev.status === "ok" ? "成功" : "失败";
        const cls = ev.status === "ok" ? "cgc-ev-ok" : "cgc-ev-err";
        return (
          '<div class="cgc-ev">' +
            '<span class="cgc-ev-time">' + escapeHtml(ev.at) + '</span>' +
            '<span class="cgc-ev-tool">' + escapeHtml(ev.tool || ev.type) + '</span>' +
            '<span class="' + cls + '">' + status + '</span>' +
          '</div>'
        );
      }).join("");
      html += '<div class="cgc-ev-list">' + rows + '</div>';
    }
    el.innerHTML = html;
  }

  async function refresh(container, webEl, discEl) {
    const statusEl = container.querySelector("#cgc-status");
    const workbenchEl = container.querySelector("#cgc-workbench");
    statusEl.textContent = "加载中…";
    discEl.disabled = true;

    let st;
    try {
      const res = await fetch(API + "/status", { headers: { Accept: "application/json" } });
      st = await res.json().catch(function () { return {}; });
      if (!res.ok || !st.ok) throw new Error(st.error || ("HTTP " + res.status));
    } catch (e) {
      statusEl.innerHTML = "<b>获取状态失败：</b>" + escapeHtml(String(e.message || e));
      if (workbenchEl) workbenchEl.style.display = "none";
      return;
    }

    const lines = [];
    lines.push("<b>连接：</b>" + (st.configured ? "已连接" : "未连接"));
    if (st.url) lines.push("<b>端点：</b>" + escapeHtml(st.url));
    lines.push("<b>Token：</b>" + (st.token_configured ? "已配置" : "未配置"));
    statusEl.innerHTML = lines.join("<br>");

    discEl.disabled = !st.configured;
    if (st.web_url) {
      webEl.href = st.web_url;
      webEl.style.display = "";
    } else {
      webEl.style.display = "none";
    }

    // 已连接才展开工作台身份区(身份/任务数据走 loopback,未连接必 503)
    if (st.configured) {
      workbenchEl.style.display = "";
      loadWorkspaces(container);
    } else {
      workbenchEl.style.display = "none";
    }
  }

  async function disconnect(container) {
    if (!window.confirm("确认断开 CGC-2046 连接？将移除 mcp.json 中的 cgc-2046 条目。")) return;

    const discEl = container.querySelector("#cgc-disconnect");
    const webEl = container.querySelector("#cgc-open-web");
    discEl.disabled = true;

    try {
      const res = await fetch(API + "/connect", { method: "DELETE" });
      const body = await res.json().catch(function () { return {}; });
      if (!res.ok || !body.ok) throw new Error(body.error || ("HTTP " + res.status));
      await refresh(container, webEl, discEl);
    } catch (e) {
      window.alert("断开失败：" + String(e.message || e));
      discEl.disabled = false;
    }
  }

  // ---- 扩展事件总线订阅 ----
  function onToolUsed(payload) {
    pushEvent({
      type: payload.type || "tool_used",
      tool: payload.tool || "",
      status: payload.status === "ok" ? "ok" : "error",
      at: new Date().toLocaleTimeString()
    });
    if (currentContainer) renderActivity(currentContainer);
  }

  function onMcpError(payload) {
    mcpError = String(payload.error || "未知连接错误").slice(0, 300);
    pushEvent({
      type: payload.type || "mcp_error",
      tool: payload.tool || "",
      status: "error",
      at: new Date().toLocaleTimeString()
    });
    if (currentContainer) renderActivity(currentContainer);
  }

  // ---- 轻量样式（面板内自包含，不依赖宿主 class 细节）----
  function injectStyles() {
    const style = document.createElement("style");
    style.textContent =
      ".cgc-panel { padding: 16px; }" +
      ".cgc-panel-title { margin: 0 0 4px; font-size: 18px; font-weight: 600; }" +
      ".cgc-panel-sub { margin: 0 0 16px; font-size: 13px; opacity: .6; }" +
      ".cgc-card { border: 1px solid rgba(128,128,128,.3); border-radius: 8px; " +
        "padding: 12px 14px; font-size: 13px; line-height: 1.7; margin-bottom: 14px; }" +
      ".cgc-activity-title { font-weight: 600; margin-bottom: 8px; }" +
      ".cgc-banner { border: 1px solid rgba(192,57,43,.5); background: rgba(192,57,43,.08); " +
        "border-radius: 6px; padding: 8px 10px; margin-bottom: 8px; color: #c0392b; }" +
      ".cgc-banner-hint { margin-top: 4px; opacity: .8; }" +
      ".cgc-banner code { font-family: ui-monospace, Menlo, monospace; }" +
      ".cgc-empty { opacity: .55; }" +
      ".cgc-ev-list { display: flex; flex-direction: column; gap: 4px; }" +
      ".cgc-ev { display: flex; gap: 8px; align-items: baseline; }" +
      ".cgc-ev-time { opacity: .5; font-size: 12px; flex: none; }" +
      ".cgc-ev-tool { flex: 1; word-break: break-all; }" +
      ".cgc-ev-ok { color: #27ae60; flex: none; }" +
      ".cgc-ev-err { color: #c0392b; flex: none; }" +
      ".cgc-identity { display: flex; gap: 6px; align-items: baseline; flex-wrap: wrap; margin-bottom: 8px; }" +
      ".cgc-identity-line { font-size: 13px; }" +
      ".cgc-badge { font-size: 11px; border: 1px solid rgba(128,128,128,.4); border-radius: 999px; " +
        "padding: 1px 8px; opacity: .8; }" +
      ".cgc-badge-admin { border-color: #6366f1; color: #6366f1; opacity: 1; }" +
      ".cgc-picker-label { font-size: 12px; opacity: .6; margin-right: 6px; }" +
      ".cgc-select { padding: 4px 8px; border: 1px solid rgba(128,128,128,.4); border-radius: 6px; " +
        "background: transparent; color: inherit; font-size: 13px; margin-bottom: 8px; }" +
      ".cgc-tasks-head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 6px; }" +
      ".cgc-btn-mini { padding: 2px 8px; font-size: 12px; }" +
      ".cgc-task-row .cgc-kind { flex: none; font-size: 11px; border: 1px solid rgba(128,128,128,.4); " +
        "border-radius: 999px; padding: 1px 8px; opacity: .8; }" +
      ".cgc-task-summary { flex: 1; word-break: break-all; }" +
      ".cgc-actions { display: flex; gap: 8px; flex-wrap: wrap; }" +
      ".cgc-btn { display: inline-block; padding: 6px 12px; border-radius: 6px; " +
        "font-size: 13px; text-decoration: none; cursor: pointer; border: 1px solid transparent; }" +
      ".cgc-btn-secondary { background: transparent; border-color: rgba(128,128,128,.4); color: inherit; }" +
      ".cgc-btn-danger { background: #c0392b; color: #fff; }" +
      ".cgc-btn-danger:disabled { opacity: .45; cursor: not-allowed; }";
    document.head.appendChild(style);
  }

  injectStyles();
  Clacky.ext.subscribe("ext.cgc-2046.tool_used", onToolUsed);
  Clacky.ext.subscribe("ext.cgc-2046.mcp_error", onMcpError);
  Clacky.ext.ui.registerWorkspace(WS_ID, { title: "CGC-2046", render: render });
  Clacky.ext.ui.mount("sidebar.nav", navRow, { workspace: WS_ID });
})();
