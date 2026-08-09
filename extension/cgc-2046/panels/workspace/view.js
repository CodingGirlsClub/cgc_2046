// CGC-2046 连接面板（v1 薄面板，Issue #100）。
//
// 能力：
//   - 侧边栏入口（sidebar.nav.bottom）→ 打开本面板页
//   - 连接状态卡：configured / url / token_configured（GET /api/ext/cgc-2046/status，脱敏）
//   - 断开连接：DELETE /api/ext/cgc-2046/connect（带 confirm，移除 mcp.json 的 cgc 条目）
//   - 跳转网站（status.web_url，来自 ext.yml config）
//
// 安全红线：面板只展示 status 的布尔/URL 字段，绝不渲染 token/headers。
// 参考宿主侧边栏样式（task-item 系列）与 ext-studio / trading-cockpit 面板先例。

(() => {
  "use strict";
  if (!window.Clacky || !Clacky.ext || Clacky.ext.pure) return;

  const API = "/api/ext/cgc-2046";
  const WS_ID = "cgc-2046";

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
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
    container.innerHTML =
      '<div class="cgc-panel">' +
        '<h3 class="cgc-panel-title">CGC-2046 连接</h3>' +
        '<p class="cgc-panel-sub">平台 MCP 连接状态与配置管理</p>' +
        '<div class="cgc-card" id="cgc-status">加载中…</div>' +
        '<div class="cgc-actions">' +
          '<a id="cgc-open-web" class="cgc-btn cgc-btn-secondary" href="#" ' +
             'target="_blank" rel="noopener noreferrer">打开 CGC-2046 网站</a>' +
          '<button id="cgc-disconnect" class="cgc-btn cgc-btn-danger" type="button" disabled>断开连接</button>' +
        '</div>' +
      '</div>';

    const webEl = container.querySelector("#cgc-open-web");
    const discEl = container.querySelector("#cgc-disconnect");
    discEl.addEventListener("click", function () { disconnect(container); });
    refresh(container, webEl, discEl);
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
    if (!window.confirm("确认断开 CGC-2046 连接？将移除 mcp.json 中的 cgc 条目。")) return;

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

  // ---- 轻量样式（面板内自包含，不依赖宿主 class 细节）----
  function injectStyles() {
    const style = document.createElement("style");
    style.textContent =
      ".cgc-panel { padding: 16px; }" +
      ".cgc-panel-title { margin: 0 0 4px; font-size: 18px; font-weight: 600; }" +
      ".cgc-panel-sub { margin: 0 0 16px; font-size: 13px; opacity: .6; }" +
      ".cgc-card { border: 1px solid rgba(128,128,128,.3); border-radius: 8px; " +
        "padding: 12px 14px; font-size: 13px; line-height: 1.7; margin-bottom: 14px; }" +
      ".cgc-actions { display: flex; gap: 8px; flex-wrap: wrap; }" +
      ".cgc-btn { display: inline-block; padding: 6px 12px; border-radius: 6px; " +
        "font-size: 13px; text-decoration: none; cursor: pointer; border: 1px solid transparent; }" +
      ".cgc-btn-secondary { background: transparent; border-color: rgba(128,128,128,.4); color: inherit; }" +
      ".cgc-btn-danger { background: #c0392b; color: #fff; }" +
      ".cgc-btn-danger:disabled { opacity: .45; cursor: not-allowed; }";
    document.head.appendChild(style);
  }

  injectStyles();
  Clacky.ext.ui.registerWorkspace(WS_ID, { title: "CGC-2046", render: render });
  Clacky.ext.ui.mount("sidebar.nav", navRow, { workspace: WS_ID });
})();
