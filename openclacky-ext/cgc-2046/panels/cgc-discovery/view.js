// CGC-2046 发现面板(U6,R11/R12/R13/AE5;KTD3/KTD4/KTD9)。
//
// 列出全平台公开活动/课程(标题/时间/地点/状态标签),条目点击跳 web 详情页。
// 数据通道:面板 fetch 扩展 loopback 路由(/api/ext/cgc-2046/offerings)→
// 扩展经宿主 MCP registry 透传公开浏览工具 list_public_offerings
// (membership: :public 豁免家族,无需工作台作用域参数;KD3 单一口径:
// 侧边栏与聊天面共用同一 MCP 工具,不直连 web GraphQL)。
//
// 状态机:Loading → NotConnected(loopback 503,AE5 连接引导)/ Error(502/500,
// 点重试回 Loading)/ Empty(0 条)/ List(≥1 条);NotConnected 连接后重进面板
// 自动回 Loading 重拉。
//
// 详情链接(KTD9):web_url(经 /status 从 ext.yml config 透传)+ 裸路径
// /events|/courses/<slug>。web 侧实证:next-intl localePrefix 'as-needed',
// 默认 zh-CN 无前缀(裸路径直接命中),en 用户由 middleware 按 cookie 重定向
// 到 /en/ 前缀同路径——故面板按裸路径拼 slug 即可。

(() => {
  "use strict";
  if (!window.Clacky || !Clacky.ext || Clacky.ext.pure) return;

  const API = "/api/ext/cgc-2046";
  const WS_ID = "cgc-2046-discovery";
  let currentContainer = null;

  // ---- 面板状态机 ----
  const state = {
    view: "idle",     // idle | loading | not-connected | error | empty | list
    items: [],        // [{ id, slug, title, kind, badge, starts_at, city, district }]
    totalCount: 0,
    undatedCount: 0,
    webUrl: "",
    error: null
  };

  function escapeHtml(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  // badge 三态中文标签(KTD4)
  function badgeLabel(badge) {
    if (badge === "enrolling") return "报名中";
    if (badge === "starting_soon") return "即将开始";
    if (badge === "full") return "已满";
    return badge || "";
  }

  // 无时间条目展示「时间待定」(KTD4)
  function timeLabel(startsAt) {
    if (!startsAt) return "时间待定";
    const d = new Date(startsAt);
    return isNaN(d.getTime()) ? "时间待定" : d.toLocaleString();
  }

  // event 有 city/district 才显示;course 为线上,无位置槽(KD6)
  function placeLabel(item) {
    if (item.kind !== "event") return "";
    return [item.city, item.district].filter(function (v) { return !!v; }).join(" ");
  }

  // ---- 数据加载 ----
  async function apiGet(path) {
    const res = await fetch(API + path, { headers: { Accept: "application/json" } });
    const body = await res.json().catch(function () { return {}; });
    if (!res.ok) throw Object.assign(new Error(body.error || "HTTP " + res.status), { body, status: res.status });
    return body;
  }

  async function loadOfferings() {
    state.view = "loading";
    state.error = null;
    paint();
    try {
      // web_url 经 /status 透传;status 失败只意味着条目退化为纯文本(无链接),
      // 不把已拿到的列表拖进错误态
      const [listRes, statusRes] = await Promise.all([
        apiGet("/offerings"),
        apiGet("/status").catch(function () { return {}; })
      ]);
      const result = listRes.result || {};
      state.items = result.items || [];
      state.totalCount = result.total_count || 0;
      state.undatedCount = result.undated_count || 0;
      state.webUrl = statusRes.web_url || "";
      state.view = state.items.length === 0 ? "empty" : "list";
    } catch (e) {
      state.error = e;
      state.items = [];
      state.view = e && e.status === 503 ? "not-connected" : "error";
    }
    paint();
  }

  // ---- 渲染 ----
  // 宿主每次打开面板调 render:首开(idle)与「NotConnected 连接后重进」都回 Loading 重拉
  function render(container) {
    currentContainer = container || currentContainer;
    if (!currentContainer) return;
    if (state.view === "idle" || state.view === "not-connected") {
      loadOfferings();
      return;
    }
    paint();
  }

  function shell(inner) {
    currentContainer.innerHTML =
      '<div class="cgc-panel cgc-discovery-panel">' +
        '<h3 class="cgc-panel-title">CGC 发现</h3>' +
        inner +
      '</div>';
  }

  function paint() {
    if (!currentContainer) return;
    if (state.view === "loading") return paintLoading();
    if (state.view === "not-connected") return paintNotConnected();
    if (state.view === "error") return paintError();
    if (state.view === "empty") return paintEmpty();
    if (state.view === "list") return paintList();
  }

  function paintLoading() {
    shell('<div class="cgc-card" data-testid="panel-loading">加载中…</div>');
  }

  // AE5:未连接 → 连接引导视图(非报错非空白);重试/连接后重进都回 Loading
  function paintNotConnected() {
    shell(
      '<div class="cgc-banner" data-testid="panel-not-connected">' +
        '<b>CGC-2046 未连接。</b>' + escapeHtml((state.error && state.error.message) || "") +
        '<div class="cgc-banner-hint">请先在 CGC-2046 连接面板完成连接(生成 token 并连接),' +
          '再打开发现面板浏览公开活动与课程(503)。</div>' +
      '</div>' +
      '<div class="cgc-actions">' +
        '<button id="cgc-retry" class="cgc-btn cgc-btn-secondary" type="button" data-testid="panel-retry">重试</button>' +
      '</div>'
    );
    bindRetry();
  }

  function paintError() {
    shell(
      '<div class="cgc-card cgc-ev-err" data-testid="panel-error">加载失败:' +
        escapeHtml((state.error && state.error.message) || "") + '</div>' +
      '<div class="cgc-actions">' +
        '<button id="cgc-retry" class="cgc-btn cgc-btn-secondary" type="button" data-testid="panel-retry">重试</button>' +
      '</div>'
    );
    bindRetry();
  }

  function bindRetry() {
    currentContainer.querySelector("#cgc-retry").addEventListener("click", function () { loadOfferings(); });
  }

  function paintEmpty() {
    shell(
      '<div class="cgc-card cgc-empty" data-testid="panel-empty">近期暂无公开活动或课程。</div>' +
      refreshRow()
    );
    bindRefresh();
  }

  function paintList() {
    const sub =
      '<p class="cgc-panel-sub">近期公开活动与课程' +
        (state.undatedCount > 0 ? '(含 ' + state.undatedCount + ' 条时间待定)' : "") +
        (state.totalCount > state.items.length
          ? ' · 共 ' + state.totalCount + ' 条,显示前 ' + state.items.length + ' 条'
          : "") +
      '</p>';

    const rows = state.items.map(function (item) {
      const place = placeLabel(item);
      const title = state.webUrl && item.slug
        ? '<a class="task-name cgc-offering-link" href="' + detailUrl(item) + '" target="_blank" rel="noopener noreferrer">' + escapeHtml(item.title) + '</a>'
        : '<span class="task-name">' + escapeHtml(item.title) + '</span>';
      return (
        '<div class="cgc-offering-row" data-testid="panel-offering" data-kind="' + escapeHtml(item.kind) + '">' +
          title +
          '<span class="cgc-offering-meta">' +
            '<span class="cgc-badge cgc-badge-' + escapeHtml(item.badge) + '" data-testid="panel-badge">' +
              escapeHtml(badgeLabel(item.badge)) + '</span>' +
            '<span class="cgc-offering-time">' + escapeHtml(timeLabel(item.starts_at)) + '</span>' +
            (place ? '<span class="cgc-offering-place">' + escapeHtml(place) + '</span>' : "") +
          '</span>' +
        '</div>'
      );
    }).join("");

    shell(sub + '<div class="cgc-card cgc-offering-list">' + rows + '</div>' + refreshRow());
    bindRefresh();
  }

  // KTD9:web 详情 = web_url + 裸路径 + slug(event → /events/,course → /courses/)
  function detailUrl(item) {
    const base = state.webUrl.replace(/\/+$/, "");
    const section = item.kind === "course" ? "/courses/" : "/events/";
    return base + section + encodeURIComponent(item.slug);
  }

  function refreshRow() {
    return '<div class="cgc-actions">' +
      '<button id="cgc-refresh" class="cgc-btn cgc-btn-secondary" type="button">刷新</button>' +
    '</div>';
  }

  function bindRefresh() {
    const btn = currentContainer.querySelector("#cgc-refresh");
    if (btn) btn.addEventListener("click", function () { loadOfferings(); });
  }

  // ---- 样式(面板自包含) ----
  function injectStyles() {
    if (document.getElementById("cgc-discovery-styles")) return;
    const css = document.createElement("style");
    css.id = "cgc-discovery-styles";
    css.textContent =
      ".cgc-offering-list{margin-top:10px}" +
      ".cgc-offering-row{padding:8px 10px;border-radius:8px}" +
      ".cgc-offering-row:hover{background:rgba(127,127,127,.12)}" +
      ".cgc-offering-link{color:inherit;text-decoration:none}" +
      ".cgc-offering-link:hover{text-decoration:underline}" +
      ".cgc-offering-meta{display:flex;gap:8px;align-items:center;margin-top:3px;font-size:12px;color:#9ca3af}" +
      ".cgc-badge{border:1px solid var(--border,#444);border-radius:999px;padding:0 8px;font-size:11px}" +
      ".cgc-badge-enrolling{color:#34d399;border-color:#34d399}" +
      ".cgc-badge-starting_soon{color:#fbbf24;border-color:#fbbf24}" +
      ".cgc-badge-full{color:#9ca3af}";
    document.head.appendChild(css);
  }

  injectStyles();
  Clacky.ext.ui.registerWorkspace(WS_ID, { title: "CGC 发现", render: render });
})();
