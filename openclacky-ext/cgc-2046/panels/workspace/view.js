// CGC-2046 连接面板（v1 薄面板，Issue #100）。
//
// 能力：
//   - 侧边栏入口（sidebar.nav.bottom）→ 打开本面板页
//   - 连接状态卡：configured / url / token_configured（GET /api/ext/cgc-2046/status，脱敏）
//   - 断开连接：DELETE /api/ext/cgc-2046/connect（带 confirm，移除 mcp.json 的 cgc-2046 条目）
//   - 跳转网站（status.web_url，来自 ext.yml config）
//   - 最近活动：订阅扩展事件总线（ext.cgc-2046.*，宿主 Agent#emit_event → ws 路由）
//       - ext.cgc-2046.tool_used —— 每次 CGC MCP 调用完成（hooks/after_tool_use.rb）
//       - ext.cgc-2046.mcp_error —— MCP 连接异常（hooks/on_tool_error.rb），显示引导横幅
//
// 安全红线：面板只展示 status 的布尔/URL 字段与事件脱敏文本，绝不渲染 token/headers。
// 参考宿主侧边栏样式（task-item 系列）与 ext-studio / trading-cockpit 面板先例。

(() => {
  "use strict";
  if (!window.Clacky || !Clacky.ext || Clacky.ext.pure) return;

  const API = "/api/ext/cgc-2046";
  const WS_ID = "cgc-2046";
  const EVENTS_MAX = 20;

  // ---- 事件总线状态（闭包内，跨面板开关保持）----
  let events = [];          // { type, tool, status, error, at }
  let mcpError = null;      // 最近的连接异常文本（横幅）
  let currentContainer = null;

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
    renderActivity(container);
    refresh(container, webEl, discEl);
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
    statusEl.textContent = "加载中…";
    discEl.disabled = true;

    let st;
    try {
      const res = await fetch(API + "/status", { headers: { Accept: "application/json" } });
      st = await res.json().catch(function () { return {}; });
      if (!res.ok || !st.ok) throw new Error(st.error || ("HTTP " + res.status));
    } catch (e) {
      statusEl.innerHTML = "<b>获取状态失败：</b>" + escapeHtml(String(e.message || e));
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
