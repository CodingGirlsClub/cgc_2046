// CGC-2046 发现面板 v2(S7-extension,R30–R35/AE3/AE6/AE7;KTD3/KTD9)。
//
// 合并发现流(公开 ∪ 本人各 workspace 可访问,服务端按可见性过滤去重),
// 条目携带 workspace 名与 my_enrollment。数据通道:面板 fetch 扩展 loopback
// 路由(/api/ext/cgc-2046/discover)→ 扩展经宿主 MCP registry 透传
// discover_offerings(KD3 单一口径:侧边栏与聊天面共用同一 MCP 工具,
// 不直连 web GraphQL)。
//
// 状态机:Loading → NotConnected(loopback 503,AE5 连接引导)/ Error(502/500,
// 点重试回 Loading)/ Empty(0 条)/ List(≥1 条);NotConnected 连接后重进面板
// 自动回 Loading 重拉。
//
// 报名旅程(R31/AE3):
//   报名 → GET /enrollment_summary → 面板内确认卡(标题/价格档或免费/策略/
//   deadline/将创建状态:直接确认·需审批·需支付;invite_only → 仅邀请徽章,
//   无确认按钮)→ 确认 → POST /enrollments(幂等,重放安全)→
//   confirmed 已报名 / pending 待审批 / payment_pending 去支付。
//
// 支付旅程(R33/AE7):payment_pending → 去支付(checkout_url 经 anchor
// target=_blank 外部打开)+ 支付中徽章 + 5s 轮询 /order_status(终态/面板
// 离开/10 分钟上限即停);paid → 自动翻 已报名;expired → 已过期徽章。
// 既有 my_enrollment 直接渲染状态徽章(待审批/待支付+去支付/已报名/已拒绝/
// 已过期/已取消),不再出现报名按钮。
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
  let csrfToken = "";                 // advisor F2:写路由 CSRF token(经 /status 同源下发)
  const PAY_POLL_MS = 5000;               // AE7:支付状态 5s 轮询
  const PAY_POLL_CAP_MS = 10 * 60 * 1000; // 轮询 10 分钟上限
  let currentContainer = null;
  let payTimer = null;

  // ---- 面板状态机 ----
  const state = {
    view: "idle",     // idle | loading | not-connected | error | empty | list
    items: [],        // [{ id, slug, title, kind, status, visibility, workspace, pricing, registration_deadline, my_enrollment }]
    webUrl: "",
    error: null,
    confirm: null     // 报名确认卡 { item, summary, tierId, loading, saving, error }
  };

  // 进行中的支付:enrollmentId → { workspaceId, checkoutUrl, startedAt }
  const activePayments = {};

  function escapeHtml(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  // ---- 标签映射(中文) ----
  // offering 状态徽章
  function badgeLabel(status) {
    if (status === "open") return "报名中";
    if (status === "closed") return "报名截止";
    return status || "";
  }

  function kindLabel(kind) {
    if (kind === "event") return "活动";
    if (kind === "course") return "课程";
    return kind || "";
  }

  // my_enrollment 状态徽章(支付中 = 本面板已启动轮询的 payment_pending)
  function enrollmentBadge(status) {
    if (status === "confirmed") return "已报名";
    if (status === "pending") return "待审批";
    if (status === "payment_pending") return "待支付";
    if (status === "rejected") return "已拒绝";
    if (status === "expired") return "已过期";
    if (status === "cancelled") return "已取消";
    return status || "";
  }

  // 确认卡:报名策略
  function policyLabel(policy) {
    if (policy === "open") return "开放报名";
    if (policy === "request") return "需审批";
    if (policy === "invite_only") return "仅邀请";
    return policy || "";
  }

  // 确认卡:确认后将创建的状态
  function wouldCreateLabel(would) {
    if (would === "confirmed") return "直接确认";
    if (would === "pending") return "需审批";
    if (would === "payment_pending") return "需支付";
    return would || "";
  }

  // 价格:免费 或 ¥<min_amount> 起(分 → 元)
  function priceLabel(pricing) {
    if (!pricing || !pricing.enabled) return "免费";
    const cents = Number(pricing.min_amount_cents);
    if (!isFinite(cents)) return "";
    return "¥" + (cents / 100).toFixed(2) + " 起";
  }

  function formatCents(cents) {
    const n = Number(cents);
    return isFinite(n) ? "¥" + (n / 100).toFixed(2) : "";
  }

  // 报名截止时间;无 deadline 不渲染时间槽
  function deadlineLabel(deadline) {
    if (!deadline) return "";
    const d = new Date(deadline);
    return isNaN(d.getTime()) ? "" : "报名截止 " + d.toLocaleString();
  }

  // summary 价格档:pricing.tiers 优先,兑底 offering.price_tiers
  function summaryTiers(summary) {
    const pricing = (summary && summary.pricing) || {};
    if (Array.isArray(pricing.tiers)) return pricing.tiers;
    const offering = (summary && summary.offering) || {};
    return Array.isArray(offering.price_tiers) ? offering.price_tiers : [];
  }

  // ---- 数据加载 ----
  async function apiGet(path) {
    const headers = { Accept: "application/json" };
    if (csrfToken) headers["X-CGC-CSRF-Token"] = csrfToken;
    const res = await fetch(API + path, { headers: headers });
    const body = await res.json().catch(function () { return {}; });
    if (!res.ok) throw Object.assign(new Error(body.error || "HTTP " + res.status), { body, status: res.status });
    return body;
  }

  // 重取 CSRF token(宿主热重载会轮换进程级 token——advisor R2 自愈路径)
  async function refreshCsrf() {
    try {
      const res = await fetch(API + "/status", { headers: { Accept: "application/json" } });
      const body = await res.json().catch(function () { return {}; });
      if (res.ok && body.csrf_token) { csrfToken = String(body.csrf_token); return true; }
    } catch (e) { /* 静默 */ }
    return false;
  }

  function postHeaders() {
    const headers = { "Content-Type": "application/json", Accept: "application/json" };
    if (csrfToken) headers["X-CGC-CSRF-Token"] = csrfToken;
    return headers;
  }

  // 报名提交:POST JSON;错误体挂 status/body;403-on-CSRF 重取 token 重试一次
  async function apiPost(path, payload) {
    let res = await fetch(API + path, { method: "POST", headers: postHeaders(), body: JSON.stringify(payload) });
    if (res.status === 403 && (await refreshCsrf())) {
      res = await fetch(API + path, { method: "POST", headers: postHeaders(), body: JSON.stringify(payload) });
    }
    const body = await res.json().catch(function () { return {}; });
    if (!res.ok) throw Object.assign(new Error(body.message || body.error || "HTTP " + res.status), { body, status: res.status });
    return body;
  }

  async function loadOfferings() {
    state.view = "loading";
    state.error = null;
    state.confirm = null;
    paint();
    try {
      // web_url 经 /status 透传;status 失败只意味着条目退化为纯文本(无链接),
      // 不把已拿到的列表拖进错误态
      const [listRes, statusRes] = await Promise.all([
        apiGet("/discover"),
        apiGet("/status").catch(function () { return {}; })
      ]);
      const result = listRes.result || {};
      state.items = Array.isArray(result.offerings) ? result.offerings : [];
      state.webUrl = statusRes.web_url || "";
      if (statusRes.csrf_token) csrfToken = String(statusRes.csrf_token);
      state.view = state.items.length === 0 ? "empty" : "list";
    } catch (e) {
      state.error = e;
      state.items = [];
      state.view = e && e.status === 503 ? "not-connected" : "error";
    }
    paint();
  }

  // ---- 报名旅程(R31) ----
  // 报名 → 摘要确认卡;invite_only 策略在卡内降级为 仅邀请 徽章(无确认按钮)
  async function startEnroll(item) {
    state.confirm = { item: item, summary: null, tierId: "", loading: true, saving: false, error: null };
    paint();
    try {
      // advisor F4:动作安全作用域 = workspace_id 原值优先（invite_only 台对
      // 非成员展示块 workspace 为 nil，但动作仍可携真实作用域走通）
      const wsId = (item.workspace && item.workspace.id) || item.workspace_id || "";
      const payload = await apiGet("/enrollment_summary?workspace_id=" + encodeURIComponent(wsId) +
        "&kind=" + encodeURIComponent(item.kind) +
        "&offering_id=" + encodeURIComponent(item.id));
      if (state.confirm && state.confirm.item === item) {
        state.confirm.summary = payload.result || {};
        state.confirm.loading = false;
        const tiers = summaryTiers(state.confirm.summary);
        if (tiers.length === 1) state.confirm.tierId = String(tiers[0].id || "");
      }
    } catch (e) {
      if (state.confirm && state.confirm.item === item) {
        state.confirm.loading = false;
        state.confirm.error = e;
      }
    }
    paint();
  }

  // 确认报名(幂等,AE3:重放返回既有 enrollment,可安全重试)
  async function submitEnroll() {
    const c = state.confirm;
    if (!c || !c.summary || c.saving) return;
    const item = c.item;
    const wsId = (item.workspace && item.workspace.id) || item.workspace_id || "";
    c.saving = true;
    c.error = null;
    paint();
    try {
      const body = { workspace_id: wsId, kind: item.kind, offering_id: item.id };
      if (c.tierId) body.tier_id = c.tierId;
      const payload = await apiPost("/enrollments", body);
      const result = payload.result || {};
      const enr = result.enrollment || {};
      item.my_enrollment = { id: enr.id, status: enr.status };
      state.confirm = null;
      // R33/AE7:收费条目 → 支付中徽章 + 去支付 + 5s 轮询订单
      if (enr.status === "payment_pending" && result.checkout_url) {
        startPaymentWatch(String(enr.id), wsId, result.checkout_url);
      }
    } catch (e) {
      c.saving = false;
      c.error = e;
    }
    paint();
  }

  // 既有待支付报名:点击 去支付 → 取 checkout_url 外部打开 + 启动轮询;
  // 已终态则就地翻徽章
  async function resumePayment(enrollmentId, workspaceId) {
    try {
      const payload = await apiGet("/order_status?workspace_id=" + encodeURIComponent(workspaceId) +
        "&enrollment_id=" + encodeURIComponent(enrollmentId));
      const result = payload.result || {};
      const order = result.order || null;
      if ((order && order.status === "paid") || result.enrollment_status === "confirmed") {
        markEnrollment(enrollmentId, "confirmed");
        paint();
        return;
      }
      if (order && order.status === "expired") {
        markEnrollment(enrollmentId, "expired");
        paint();
        return;
      }
      if (typeof result.checkout_url === "string" && /^https?:\/\//.test(result.checkout_url)) {
        window.open(result.checkout_url, "_blank", "noopener");
        startPaymentWatch(enrollmentId, workspaceId, result.checkout_url);
        paint();
      }
    } catch (e) { /* 失败静默,用户可重新点击 */ }
  }

  // ---- 支付状态轮询(AE7) ----
  // 5s 轮询 /order_status;终态(paid/expired)/面板离开/10 分钟上限即停;
  // paid → 自动翻 已报名;失败静默下轮重试;有状态变化才重绘(不打断确认卡)。
  function startPaymentWatch(enrollmentId, workspaceId, checkoutUrl) {
    activePayments[enrollmentId] = { workspaceId: workspaceId, checkoutUrl: checkoutUrl, startedAt: Date.now() };
    if (!payTimer) payTimer = setInterval(payTick, PAY_POLL_MS);
  }

  function markEnrollment(enrollmentId, status) {
    state.items.forEach(function (it) {
      if (it.my_enrollment && String(it.my_enrollment.id) === String(enrollmentId)) {
        it.my_enrollment.status = status;
      }
    });
  }

  async function payTick() {
    // 面板离开(容器脱离 DOM):全部停止
    if (!currentContainer || !document.contains(currentContainer)) {
      Object.keys(activePayments).forEach(function (id) { delete activePayments[id]; });
      if (payTimer) { clearInterval(payTimer); payTimer = null; }
      return;
    }
    let changed = false;
    const ids = Object.keys(activePayments);
    for (let i = 0; i < ids.length; i++) {
      const id = ids[i];
      const p = activePayments[id];
      if (!p) continue;
      if (Date.now() - p.startedAt > PAY_POLL_CAP_MS) { delete activePayments[id]; continue; }
      try {
        const payload = await apiGet("/order_status?workspace_id=" + encodeURIComponent(p.workspaceId) +
          "&enrollment_id=" + encodeURIComponent(id));
        const result = payload.result || {};
        const order = result.order || null;
        if ((order && order.status === "paid") || result.enrollment_status === "confirmed") {
          markEnrollment(id, "confirmed");
          delete activePayments[id];
          changed = true;
        } else if (order && order.status === "expired") {
          markEnrollment(id, "expired");
          delete activePayments[id];
          changed = true;
        }
      } catch (e) { /* 轮询失败静默,下轮重试 */ }
    }
    if (payTimer && Object.keys(activePayments).length === 0) {
      clearInterval(payTimer);
      payTimer = null;
    }
    if (changed) paint();
  }

  // ---- 侧边栏入口 ----
  // 宿主合同(ext.js):registerWorkspace 只注册不开门,workspace 的入口 =
  // sidebar.nav mount(首面板 workspace/view.js 同款);data-ext-workspace
  // 供宿主路由在 #ext/<id> 直达时高亮本入口(app.js ext-workspace 视图)。
  function navRow() {
    const item = document.createElement("div");
    item.className = "task-item task-item-summary";
    item.dataset.extWorkspace = WS_ID;
    item.innerHTML =
      '<div class="task-row">' +
        '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" ' +
             'fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" ' +
             'stroke-linejoin="round" class="task-icon">' +
          '<circle cx="12" cy="12" r="10"/>' +
          '<polygon points="16.24 7.76 14.12 14.12 7.76 16.24 9.88 9.88 16.24 7.76"/>' +
        '</svg>' +
        '<div class="task-info"><span class="task-name">CGC 发现</span></div>' +
      '</div>';
    item.addEventListener("click", function () { Clacky.ext.ui.openWorkspace(WS_ID); });
    return item;
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
          '再打开发现面板浏览活动与课程(503)。</div>' +
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
      '<div class="cgc-card cgc-empty" data-testid="panel-empty">近期暂无活动或课程。</div>' +
      refreshRow()
    );
    bindRefresh();
  }

  function paintList() {
    const sub = '<p class="cgc-panel-sub">近期活动与课程(含你可访问的 Workspace 条目)</p>';

    const rows = state.items.map(function (item, idx) {
      const ws = item.workspace || {};
      const title = state.webUrl && item.slug
        ? '<a class="task-name cgc-offering-link" href="' + detailUrl(item) + '" target="_blank" rel="noopener noreferrer">' + escapeHtml(item.title) + '</a>'
        : '<span class="task-name">' + escapeHtml(item.title) + '</span>';
      const deadline = deadlineLabel(item.registration_deadline);
      return (
        '<div class="cgc-offering-row" data-testid="panel-offering" data-kind="' + escapeHtml(item.kind) + '">' +
          '<div class="cgc-offering-head">' +
            title +
            '<span class="cgc-badge cgc-badge-' + escapeHtml(item.status) + '" data-testid="panel-badge">' +
              escapeHtml(badgeLabel(item.status)) + '</span>' +
          '</div>' +
          '<span class="cgc-offering-meta">' +
            '<span class="cgc-offering-ws" data-testid="panel-offering-ws">' + escapeHtml(ws.name || "") + '</span>' +
            '<span class="cgc-offering-kind">' + escapeHtml(kindLabel(item.kind)) + '</span>' +
            (deadline ? '<span class="cgc-offering-time">' + escapeHtml(deadline) + '</span>' : "") +
            '<span class="cgc-offering-price">' + escapeHtml(priceLabel(item.pricing)) + '</span>' +
          '</span>' +
          '<div class="cgc-offering-actions">' + actionCell(item, idx) + '</div>' +
        '</div>'
      );
    }).join("");

    shell(sub + '<div class="cgc-card cgc-offering-list">' + rows + '</div>' + confirmCard() + refreshRow());
    bindRefresh();
    bindEnroll();
  }

  // 行尾动作格:既有报名 → 状态徽章(待支付附 去支付);开放报名 → 报名按钮;其余留空
  function actionCell(item, idx) {
    const enr = item.my_enrollment;
    if (enr && enr.status) {
      if (enr.status === "payment_pending") {
        const active = activePayments[String(enr.id)];
        if (active) {
          return '<span class="cgc-badge cgc-badge-paying" data-testid="panel-enroll-badge">支付中</span>' +
                 payLink(active.checkoutUrl);
        }
        const wsId = (item.workspace && item.workspace.id) || "";
        return '<span class="cgc-badge cgc-badge-pending" data-testid="panel-enroll-badge">待支付</span>' +
               '<button class="cgc-btn cgc-btn-primary cgc-btn-sm" type="button" data-resume-pay="' + escapeHtml(enr.id) +
                 '" data-ws="' + escapeHtml(wsId) + '" data-testid="panel-pay-resume">去支付</button>';
      }
      return '<span class="cgc-badge cgc-badge-enr-' + escapeHtml(enr.status) + '" data-testid="panel-enroll-badge">' +
             escapeHtml(enrollmentBadge(enr.status)) + '</span>';
    }
    if (item.status === "open") {
      return '<button class="cgc-btn cgc-btn-primary cgc-btn-sm" type="button" data-enroll="' + idx +
             '" data-testid="panel-enroll">报名</button>';
    }
    return "";
  }

  // 去支付 = 既有外链机制(anchor target=_blank);非 http(s) 的 checkout_url 不渲染链接
  function payLink(url) {
    if (typeof url !== "string" || !/^https?:\/\//.test(url)) return "";
    return '<a class="cgc-btn cgc-btn-primary cgc-btn-sm" href="' + escapeHtml(url) +
           '" target="_blank" rel="noopener noreferrer" data-testid="panel-pay-link">去支付</a>';
  }

  // ---- 报名确认卡(R31;面板内渲染,不走原生确认框) ----
  function confirmCard() {
    const c = state.confirm;
    if (!c) return "";
    if (c.loading) {
      return '<div class="cgc-card cgc-confirm-card" data-testid="panel-enroll-confirm">加载报名摘要…</div>';
    }
    if (c.error) {
      return (
        '<div class="cgc-card cgc-confirm-card cgc-ev-err" data-testid="panel-enroll-confirm">' +
          '报名摘要加载失败:' + escapeHtml(c.error.message || "") +
          '<div class="cgc-actions">' +
            '<button id="cgc-enroll-cancel" class="cgc-btn cgc-btn-secondary cgc-btn-sm" type="button" data-testid="panel-enroll-cancel">取消</button>' +
          '</div>' +
        '</div>'
      );
    }
    const s = c.summary || {};
    const offering = s.offering || {};
    const tiers = summaryTiers(s);
    const inviteOnly = s.policy === "invite_only";
    const deadline = offering.registration_deadline || "";

    const priceBlock = tiers.length === 0
      ? '<div class="cgc-confirm-row"><label>价格</label><span data-testid="panel-confirm-price">' +
        escapeHtml(s.pricing && s.pricing.enabled ? formatCents(s.pricing.min_amount_cents) : "免费") + '</span></div>'
      : '<div class="cgc-confirm-row"><label>价格档</label>' +
        (tiers.length > 1
          ? '<select id="cgc-enroll-tier" class="cgc-select" data-testid="panel-confirm-tiers">' +
            tiers.map(function (t) {
              const sel = String(t.id) === c.tierId ? " selected" : "";
              return '<option value="' + escapeHtml(t.id) + '"' + sel + '>' +
                     escapeHtml(t.name || "") + ' ' + escapeHtml(formatCents(t.amount_cents)) + '</option>';
            }).join("") + '</select>'
          : '<span data-testid="panel-confirm-tiers">' +
            tiers.map(function (t) { return escapeHtml(t.name || "") + " " + escapeHtml(formatCents(t.amount_cents)); }).join(" / ") +
            '</span>') +
        '</div>';

    return (
      '<div class="cgc-card cgc-confirm-card" data-testid="panel-enroll-confirm">' +
        '<h4 class="cgc-confirm-title">确认报名:' + escapeHtml(offering.title || c.item.title || "") + '</h4>' +
        priceBlock +
        '<div class="cgc-confirm-row"><label>报名策略</label><span data-testid="panel-confirm-policy">' +
          escapeHtml(policyLabel(s.policy)) + '</span></div>' +
        (deadline
          ? '<div class="cgc-confirm-row"><label>报名截止</label><span>' + escapeHtml(deadlineLabel(deadline).replace(/^报名截止 /, "")) + '</span></div>'
          : "") +
        '<div class="cgc-confirm-row"><label>确认后状态</label><span data-testid="panel-confirm-would">' +
          escapeHtml(wouldCreateLabel(s.would_create_status)) + '</span></div>' +
        (inviteOnly
          ? '<span class="cgc-badge" data-testid="panel-invite-only">仅邀请</span>'
          : "") +
        '<div class="cgc-actions">' +
          (inviteOnly
            ? ""
            : '<button id="cgc-enroll-submit" class="cgc-btn cgc-btn-primary cgc-btn-sm" type="button" data-testid="panel-enroll-submit"' +
              (c.saving ? " disabled" : "") + '>' + (c.saving ? "提交中…" : "确认报名") + '</button>') +
          '<button id="cgc-enroll-cancel" class="cgc-btn cgc-btn-secondary cgc-btn-sm" type="button" data-testid="panel-enroll-cancel"' +
            (c.saving ? " disabled" : "") + '>取消</button>' +
        '</div>' +
      '</div>'
    );
  }

  function bindEnroll() {
    currentContainer.querySelectorAll("[data-enroll]").forEach(function (el) {
      el.addEventListener("click", function () {
        const item = state.items[Number(el.getAttribute("data-enroll"))];
        if (item) startEnroll(item);
      });
    });
    currentContainer.querySelectorAll("[data-resume-pay]").forEach(function (el) {
      el.addEventListener("click", function () {
        resumePayment(el.getAttribute("data-resume-pay"), el.getAttribute("data-ws"));
      });
    });
    const submit = currentContainer.querySelector("#cgc-enroll-submit");
    if (submit) submit.addEventListener("click", submitEnroll);
    const cancel = currentContainer.querySelector("#cgc-enroll-cancel");
    if (cancel) cancel.addEventListener("click", function () { state.confirm = null; paint(); });
    const tier = currentContainer.querySelector("#cgc-enroll-tier");
    if (tier && state.confirm) {
      tier.addEventListener("change", function () { state.confirm.tierId = tier.value; });
    }
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
      ".cgc-offering-head{display:flex;justify-content:space-between;align-items:center;gap:8px}" +
      ".cgc-offering-link{color:inherit;text-decoration:none}" +
      ".cgc-offering-link:hover{text-decoration:underline}" +
      ".cgc-offering-meta{display:flex;gap:8px;align-items:center;margin-top:3px;font-size:12px;color:#9ca3af}" +
      ".cgc-offering-actions{display:flex;gap:8px;align-items:center;margin-top:6px}" +
      ".cgc-badge{border:1px solid var(--border,#444);border-radius:999px;padding:0 8px;font-size:11px}" +
      ".cgc-badge-open{color:#34d399;border-color:#34d399}" +
      ".cgc-badge-closed{color:#9ca3af}" +
      ".cgc-badge-enr-confirmed{color:#34d399;border-color:#34d399}" +
      ".cgc-badge-pending,.cgc-badge-enr-pending,.cgc-badge-paying{color:#fbbf24;border-color:#fbbf24}" +
      ".cgc-badge-enr-rejected,.cgc-badge-enr-expired,.cgc-badge-enr-cancelled{color:#9ca3af}" +
      ".cgc-btn-sm{padding:2px 8px;font-size:12px;text-decoration:none}" +
      ".cgc-btn-primary{background:#6366f1;color:#fff;border:none;border-radius:6px}" +
      ".cgc-confirm-card{margin-top:10px;border:1px solid var(--border,#444)}" +
      ".cgc-confirm-title{font-size:13px;font-weight:600;margin:0 0 8px}" +
      ".cgc-confirm-row{display:flex;gap:8px;align-items:center;font-size:12px;margin-bottom:6px}" +
      ".cgc-confirm-row label{color:#9ca3af;min-width:60px}" +
      ".cgc-select{padding:4px 8px;border:1px solid var(--border,#444);border-radius:6px;background:transparent;color:inherit;font-size:12px}";
    document.head.appendChild(css);
  }

  injectStyles();
  Clacky.ext.ui.registerWorkspace(WS_ID, { title: "CGC 发现", render: render });
  Clacky.ext.ui.mount("sidebar.nav", navRow, { workspace: WS_ID });
})();
