// CGC 管理侧边栏(admin aside,session.aside,attach cgc-admin)。
//
// 定位:管理会话(cgc-admin)右侧的实时工作台状态视图——待办审批(最 actionable)、
// 管理快捷入口(注入指令)。同学习地图(cgla)/教研产出(cgta)的 qingclaw 骨架。
//
// 数据源(loopback 透传,零新增路由):
//   /me/workspaces — 找 admin/owner 角色的工作台 + 成员数概览
//   /tasks?workspace_id= — 管理待办(审批截止时间)
//
// 快捷入口:点按钮 = 注入管理指令到当前会话(不创建新会话——侧栏已在管理会话内)。

(() => {
  "use strict";
  if (!window.Clacky || !Clacky.ext || Clacky.ext.pure) return;

  const API = "/api/ext/cgc-2046";
  const AGENT = "cgc-admin";
  const ADMIN_ROLES = ["owner", "admin"];
  const POLL_MS = 10000;
  let root = null;
  let pollTimer = null;

  const state = {
    workspaces: [],       // [{ workspace_id, name, slug, roles }]
    selectedWsId: "",
    tasks: [],
    loading: true,
    error: null,
    lastRefresh: ""
  };

  function escapeHtml(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  // 任务 kind 中文标签(与 hub TASK_KINDS 同口径)
  const TASK_KINDS = {
    course_prep_review: { label: "教研审核" },
    enrollment_approval: { label: "报名审批" },
    join_request: { label: "加入申请" },
    sponsorship_review: { label: "赞助审核" }
  };
  function taskKindLabel(kind) {
    return (TASK_KINDS[kind] || {}).label || kind || "";
  }

  async function rawGet(path) {
    const res = await fetch(API + path, { headers: { Accept: "application/json" } });
    const body = await res.json().catch(function () { return {}; });
    if (!res.ok) throw Object.assign(new Error(body.error || ("HTTP " + res.status)), { status: res.status });
    return body;
  }

  // 只显示 admin/owner 角色的工作台
  function loadWorkspaces() {
    return rawGet("/me/workspaces").then(function (payload) {
      const all = ((payload.result || {}).workspaces) || [];
      state.workspaces = all.filter(function (w) {
        return (w.roles || []).some(function (r) { return ADMIN_ROLES.indexOf(r) >= 0; });
      });
      const stored = localStorage.getItem("cgc2046.adminAside.workspaceId") || "";
      const found = state.workspaces.find(function (w) { return w.workspace_id === stored; });
      state.selectedWsId = (found || state.workspaces[0] || {}).workspace_id || "";
      if (state.selectedWsId) localStorage.setItem("cgc2046.adminAside.workspaceId", state.selectedWsId);
    });
  }

  function loadTasks() {
    if (!state.selectedWsId) {
      state.tasks = [];
      return Promise.resolve();
    }
    return rawGet("/tasks?workspace_id=" + encodeURIComponent(state.selectedWsId)).then(function (payload) {
      state.tasks = (((payload.result || {}).tasks) || []);
      state.lastRefresh = new Date().toLocaleTimeString();
    });
  }

  async function boot() {
    state.loading = true;
    state.error = null;
    renderPanel();
    try {
      await loadWorkspaces();
      await loadTasks();
      state.error = null;
    } catch (e) {
      state.error = e;
    } finally {
      state.loading = false;
      renderPanel();
    }
  }

  // 注入管理指令(当前已在 cgc-admin 会话,直接注入不创建)
  function injectIntoComposer(text) {
    const input = document.getElementById("user-input");
    const send = document.getElementById("btn-send");
    if (!input || !send) {
      window.prompt("复制以下指令:", text);
      return;
    }
    input.textContent = text;
    input.dispatchEvent(new Event("input", { bubbles: true }));
    send.click();
    if (send.disabled) {
      const timer = setInterval(function () {
        if (!send.disabled) { clearInterval(timer); send.click(); }
      }, 200);
      setTimeout(function () { clearInterval(timer); }, 8000);
    }
  }

  // ---- 渲染 ----
  function renderPanel() {
    if (!root) return;

    const adminWsCount = state.workspaces.length;
    const pendingCount = state.tasks.length;

    let html =
      '<div class="cgaa-header">' +
        '<div class="cgaa-header-copy">' +
          '<div class="cgaa-title">工作台管理</div>' +
          '<div class="cgaa-progress-text">' +
            (adminWsCount > 0 ? adminWsCount + ' 个管理台' : '') +
            (pendingCount > 0 ? ' · 待办 ' + pendingCount : '') +
          '</div>' +
        '</div>' +
        '<button id="cgaa-refresh" class="cgaa-sync" type="button">刷新</button>' +
      '</div>' +
      '<div class="cgaa-source">' +
        '<span class="cgaa-source-dot"></span><span>管理助手</span>' +
        (state.lastRefresh ? '<span class="cgaa-source-date">' + escapeHtml(state.lastRefresh) + '</span>' : "") +
      '</div>' +
      '<div class="cgaa-content">';

    if (state.loading) {
      root.innerHTML = html + '<div class="cgaa-empty">加载中…</div></div>';
      bind();
      return;
    }
    if (state.error) {
      root.innerHTML = html + '<div class="cgaa-empty cgaa-error">加载失败:' + escapeHtml(state.error.message || "") + '</div></div>';
      bind();
      return;
    }
    if (adminWsCount === 0) {
      root.innerHTML = html + '<div class="cgaa-empty">你在任何工作台都没有 Owner/Admin 角色。</div></div>';
      bind();
      return;
    }

    // 工作台选择(admin 角色的台)
    if (adminWsCount > 1) {
      html += '<select id="cgaa-ws" class="cgaa-select">' + state.workspaces.map(function (w) {
        const sel = w.workspace_id === state.selectedWsId ? " selected" : "";
        return '<option value="' + escapeHtml(w.workspace_id) + '"' + sel + '>' + escapeHtml(w.name) + '</option>';
      }).join("") + '</select>';
    } else {
      html += '<div class="cgaa-ws-name">' + escapeHtml(state.workspaces[0].name) + '</div>';
    }

    // 待办列表
    if (pendingCount === 0) {
      html += '<div class="cgaa-empty">暂无管理待办。</div>';
    } else {
      html += '<div class="cgaa-task-list">' + state.tasks.map(function (t) {
        const dl = t.approval_deadline
          ? new Date(t.approval_deadline)
          : null;
        const dlText = dl && !isNaN(dl.getTime()) ? dl.toLocaleString() : "";
        return (
          '<div class="cgaa-task" data-testid="cgaa-task">' +
            '<span class="cgaa-task-kind">' + escapeHtml(taskKindLabel(t.kind)) + '</span>' +
            '<span class="cgaa-task-copy">' +
              escapeHtml(t.context_title || t.title || t.requester_name || "") +
            '</span>' +
            (dlText ? '<span class="cgaa-task-dl">截止 ' + escapeHtml(dlText) + '</span>' : "") +
          '</div>'
        );
      }).join("") + '</div>';
    }

    // 快捷入口(注入指令,不创建新会话)
    html +=
      '<div class="cgaa-actions">' +
        '<button class="cgaa-action" type="button" data-action="create-course" data-testid="cgaa-quick-create">+ 创建课程</button>' +
        '<button class="cgaa-action" type="button" data-action="invite">✉ 邀请成员</button>' +
        '<button class="cgaa-action" type="button" data-action="review">☑ 处理待办</button>' +
      '</div>';

    html += '</div>';
    root.innerHTML = html;
    bind();
  }

  const ACTION_PROMPTS = {
    "create-course": "请帮我创建一门新课程，引导我描述课程定位(受众/章节/时长)。",
    "invite": "请帮我邀请一位成员加入当前工作台。",
    "review": "请列出我当前所有待审批事项，逐条告诉我详情。"
  };

  function bind() {
    const refresh = root.querySelector("#cgaa-refresh");
    if (refresh) refresh.addEventListener("click", boot);
    const ws = root.querySelector("#cgaa-ws");
    if (ws) ws.addEventListener("change", function () {
      state.selectedWsId = ws.value;
      localStorage.setItem("cgc2046.adminAside.workspaceId", ws.value);
      loadTasks().then(renderPanel);
    });
    root.querySelectorAll("[data-action]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        const action = btn.getAttribute("data-action");
        const prompt = ACTION_PROMPTS[action];
        if (prompt) injectIntoComposer(prompt);
      });
    });
  }

  // ---- 样式(qingclaw 骨架,cgaa-* 前缀) ----
  function injectStyles() {
    if (document.getElementById("cgaa-styles")) return;
    const css = document.createElement("style");
    css.id = "cgaa-styles";
    css.textContent = [
      ".cgaa-root{min-height:100%;color:var(--color-text-primary);background:var(--color-bg-primary);font-size:0.75rem}",
      ".cgaa-header{display:flex;align-items:center;gap:12px;padding:16px 16px 10px}",
      ".cgaa-header-copy{flex:1;min-width:0}",
      ".cgaa-title{font-size:0.9375rem;font-weight:680}",
      ".cgaa-progress-text{margin-top:3px;color:var(--color-text-tertiary);font-size:0.6875rem}",
      ".cgaa-sync{flex:none;margin:0;padding:6px 10px;font-size:0.6875rem;font-weight:600;border:1px solid var(--color-border-primary);border-radius:var(--radius-sm,6px);background:transparent;color:var(--color-text-secondary);cursor:pointer;transition:color var(--transition-fast),border-color var(--transition-fast)}",
      ".cgaa-sync:hover{color:var(--color-text-primary);border-color:var(--color-border-strong)}",
      ".cgaa-source{display:flex;align-items:center;gap:6px;padding:0 16px 12px;color:var(--color-text-tertiary);font-size:0.625rem}",
      ".cgaa-source-dot{width:6px;height:6px;background:var(--color-accent-primary);border-radius:50%;flex:none}",
      ".cgaa-source-date{margin-left:auto}",
      ".cgaa-content{display:flex;flex-direction:column;gap:10px;padding:0 12px 16px}",
      ".cgaa-empty{padding:12px 14px;color:var(--color-text-secondary);background:var(--color-bg-subtle);border:1px solid var(--color-border-secondary);border-radius:var(--radius-md,8px);font-size:0.6875rem;line-height:1.5}",
      ".cgaa-error{color:var(--color-error,#c0392b)}",
      ".cgaa-select{width:100%;padding:5px 8px;border:1px solid var(--color-border-primary);border-radius:6px;background:var(--color-bg-card);color:inherit;font-size:0.75rem}",
      ".cgaa-ws-name{padding:6px 10px;background:var(--color-bg-subtle);border:1px solid var(--color-border-secondary);border-radius:var(--radius-md,8px);font-size:0.75rem;font-weight:650}",
      ".cgaa-task-list{display:flex;flex-direction:column;border:1px solid var(--color-border-primary);border-radius:var(--radius-lg,10px);overflow:hidden;background:var(--color-bg-card)}",
      ".cgaa-task{display:flex;gap:8px;align-items:baseline;padding:8px 10px;border-bottom:1px solid var(--color-border-secondary);font-size:0.6875rem}",
      ".cgaa-task:last-child{border-bottom:0}",
      ".cgaa-task-kind{flex:none;font-size:0.5625rem;font-weight:700;padding:0 5px;min-height:14px;display:inline-flex;align-items:center;border-radius:999px;border:1px solid color-mix(in srgb,var(--color-accent-primary) 35%,var(--color-border-primary));color:var(--color-accent-primary)}",
      ".cgaa-task-copy{flex:1;min-width:0;word-break:break-all}",
      ".cgaa-task-dl{flex:none;font-size:0.5625rem;color:var(--color-warning,#fbbf24)}",
      ".cgaa-actions{display:grid;grid-template-columns:repeat(3,1fr);gap:6px}",
      ".cgaa-action{padding:8px 6px;border:1px solid var(--color-border-secondary);border-radius:var(--radius-md,8px);background:var(--color-bg-subtle);color:var(--color-text-primary);font-size:0.625rem;font-weight:650;cursor:pointer;font-family:inherit;text-align:center;transition:border-color var(--transition-fast),color var(--transition-fast)}",
      ".cgaa-action:hover{border-color:var(--color-accent-primary);color:var(--color-accent-primary)}"
    ].join("\n");
    document.head.appendChild(css);
  }

  injectStyles();

  Clacky.ext.ui.mount("session.aside", function (container, ctx) {
    if (!ctx || ctx.agentProfile !== AGENT || !ctx.sessionId) return;
    root = document.createElement("div");
    root.className = "cgaa-root";
    container.appendChild(root);
    boot();
    pollTimer = setInterval(async function () {
      if (!root || !document.contains(root) || document.hidden) return;
      try { await loadTasks(); } catch (e) { /* 静默 */ }
      renderPanel();
    }, POLL_MS);
  }, {
    agents: [AGENT],
    order: 20,
    tab: {
      id: "cgc-2046-admin-aside",
      label: function () { return "工作台管理"; }
    }
  });
})();
