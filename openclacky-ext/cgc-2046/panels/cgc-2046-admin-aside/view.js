// CGC 管理侧边栏(admin aside,session.aside,attach cgc-admin)。
//
// 定位:管理会话(cgc-admin)右侧的实时工作台状态视图——待办审批(跨台聚合,行可点
// 注入处理指令)、供给区(课程+活动统一投影,行点击下钻报名队列)、订单区(非终态
// 优先)、管理快捷入口(按域分组注入指令)、网站管理页深链(重 UI 不重造)。
// 边界:侧栏 = 纯读投影 + 意图注入;写操作一律走 agent 对话确认流(two-tool),
// 不在面板重造确认 UI。
//
// 数据源(loopback 透传):
//   /me/workspaces — 找 admin/owner 角色的工作台(含 slug 供深链)
//   /tasks?workspace_id= — 管理待办(跨台聚合,审批截止时间)
//   /workspace/courses?workspace_id= — 当前台全部课程(含 draft)
//   /workspace/events?workspace_id= — 当前台全部活动(含 draft,P3 起与课程同面)
//   /workspace/enrollments?workspace_id=&kind=&offering_id= — 供给报名队列(下钻)
//   /workspace/orders?workspace_id= — 当前台订单(封顶 200,more 透传)
//   /status — web_url 透传(深链基址;未配置则深链区隐藏)
//
// 刷新闭环:Clacky.ext.subscribe("ext.cgc-2046.tool_used") 事件驱动即时刷新(agent
// 完成 MCP 调用即反映,debounce 合并连续调用),10s 轮询降为兜底。

(() => {
  "use strict";
  if (!window.Clacky || !Clacky.ext || Clacky.ext.pure) return;
  const Kit = window.CgcKit;
  if (!Kit) return; // 共享骨架未注入(ext.yml 首位 cgc-2046-shared 异常)

  const AGENT = "cgc-admin";
  const ADMIN_ROLES = ["owner", "admin"];
  const POLL_MS = 10000;
  const EVENT_REFRESH_DEBOUNCE_MS = 400;
  let root = null;
  let pollStop = null;
  let refreshDebouncer = null;

  const state = {
    workspaces: [],       // [{ workspace_id, name, slug, roles }]
    selectedWsId: "",
    tasks: [],
    tasksError: false,
    courses: [],          // 当前台课程 [{ course_id, title, status, prep_state }]
    coursesError: false,
    events: [],           // 当前台活动 [{ event_id, title, status, enrollment_badge }]
    eventsError: false,
    orders: [],           // 当前台订单(已按管理关注序排序)
    ordersMore: false,
    ordersError: false,
    enrollments: {},      // offering_id → { rows, count, error }(course/event 统一,id 均 UUID 不撞)
    expandedOfferingId: "",
    webUrl: "",           // status 透传的 web_url(深链基址)
    loading: true,
    error: null,
    lastRefresh: ""
  };

  const escapeHtml = Kit.escapeHtml;
  const rawGet = Kit.rawGet;

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

  // 供给状态徽章(课程/活动同 status 值域;draft 课叠 prep_state 徽章,open 活动
  // 叠 enrollment_badge 徽章——教研流程对草稿课最相关,报名徽章对开放活动最相关)
  const OFFERING_STATUS = {
    draft: { label: "草稿", cls: "draft" },
    open: { label: "开放报名", cls: "open" },
    closed: { label: "已关闭", cls: "closed" },
    cancelled: { label: "已取消", cls: "closed" }
  };
  const PREP_STATE = {
    authoring: "教研中",
    quality_check: "质检中",
    review: "待审核",
    published: "已发布"
  };
  // R6/KTD1 派生活动报名徽章
  const ENROLL_BADGE = {
    enrolling: "报名中",
    starting_soon: "即将开始",
    closed: "已截止",
    full: "已满"
  };
  const KIND_LABEL = { course: "课程", event: "活动" };

  // 对象级生命周期动作(状态门:draft 可发布/取消,open 可结束/取消,终态无动作;
  // 动词与 web 端 offerings 文案同款:发布(开放报名)/结束/取消)
  const LIFECYCLE_ACTIONS = {
    draft: [{ key: "launch", label: "发布" }, { key: "cancel", label: "取消" }],
    open: [{ key: "close", label: "结束" }, { key: "cancel", label: "取消" }]
  };
  const LC_VERB = { launch: "发布", close: "结束", cancel: "取消" };

  // 报名状态(管理视角:pending/payment_pending 是可行动行)
  const ENROLL_STATUS = {
    pending: { label: "待审批", actionable: true },
    payment_pending: { label: "待支付", actionable: true },
    confirmed: { label: "已确认", actionable: false },
    rejected: { label: "已拒绝", actionable: false },
    expired: { label: "已过期", actionable: false },
    cancelled: { label: "已取消", actionable: false }
  };

  // 订单状态与管理关注序(refund_failed 可重试最前,终态垫底)
  // attention = 非终态(待支付/退款中/退款失败)——侧栏只渲染这些「需要注意」的;
  // 终态(已支付/已退款/已取消/已过期)可达性在 agent 对话与 web 订单页
  const ORDER_STATUS = {
    pending: { label: "待支付", rank: 2, attention: true },
    paid: { label: "已支付", rank: 3 },
    refunding: { label: "退款中", rank: 1, attention: true },
    refunded: { label: "已退款", rank: 4 },
    refund_failed: { label: "退款失败", rank: 0, warn: true, attention: true },
    cancelled: { label: "已取消", rank: 5 },
    expired: { label: "已过期", rank: 5 }
  };
  function orderRank(status) {
    return ((ORDER_STATUS[status] || {}).rank != null) ? ORDER_STATUS[status].rank : 3;
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
    // 聚合所有 admin/owner 角色工作台的待办(不按选中台过滤——同 hub loadTasks);
    // allSettled:单台失败跳过不拖空
    if (state.workspaces.length === 0) {
      state.tasks = [];
      return Promise.resolve();
    }
    return Promise.allSettled(state.workspaces.map(function (w) {
      return rawGet("/tasks?workspace_id=" + encodeURIComponent(w.workspace_id)).then(function (payload) {
        return { name: w.name || "", tasks: (((payload.result || {}).tasks) || []) };
      });
    })).then(function (settled) {
      const fulfilled = settled.filter(function (r) { return r.status === "fulfilled"; });
      // 全部失败 ≠ 暂无待办(同 hub loadTasks——空态掩盖后端不可用/token 过期)
      state.tasksError = fulfilled.length === 0;
      state.tasks = fulfilled.flatMap(function (r) {
        return r.value.tasks.map(function (t) {
          t._ws_name = r.value.name;
          return t;
        });
      });
      state.lastRefresh = new Date().toLocaleTimeString();
    });
  }

  // 当前台全部课程(含 draft;管理/教研共面)
  function loadCourses() {
    if (!state.selectedWsId) { state.courses = []; return Promise.resolve(); }
    return rawGet("/workspace/courses?workspace_id=" + encodeURIComponent(state.selectedWsId))
      .then(function (payload) {
        state.courses = ((payload.result || {}).courses) || [];
        state.coursesError = false;
      })
      .catch(function () { state.courses = []; state.coursesError = true; });
  }

  // 当前台全部活动(含 draft;P3 起与课程同面)
  function loadEvents() {
    if (!state.selectedWsId) { state.events = []; return Promise.resolve(); }
    return rawGet("/workspace/events?workspace_id=" + encodeURIComponent(state.selectedWsId))
      .then(function (payload) {
        state.events = ((payload.result || {}).events) || [];
        state.eventsError = false;
      })
      .catch(function () { state.events = []; state.eventsError = true; });
  }

  // 供给报名队列(下钻懒加载;kind=course|event 分派,offering_id 为课程或活动 UUID)
  function loadEnrollments(kind, offeringId) {
    if (!state.selectedWsId || !offeringId) return Promise.resolve();
    return rawGet("/workspace/enrollments?workspace_id=" + encodeURIComponent(state.selectedWsId) +
        "&kind=" + encodeURIComponent(kind) + "&offering_id=" + encodeURIComponent(offeringId))
      .then(function (payload) {
        const result = payload.result || {};
        state.enrollments[offeringId] = {
          rows: result.enrollments || [],
          count: result.count || 0,
          error: false
        };
      })
      .catch(function () {
        state.enrollments[offeringId] = { rows: [], count: 0, error: true };
      });
  }

  // 当前台订单(管理关注序:refund_failed → refunding → pending → paid → 终态)
  function loadOrders() {
    if (!state.selectedWsId) { state.orders = []; return Promise.resolve(); }
    return rawGet("/workspace/orders?workspace_id=" + encodeURIComponent(state.selectedWsId))
      .then(function (payload) {
        const result = payload.result || {};
        state.orders = (result.orders || []).slice().sort(function (a, b) {
          return orderRank(a.status) - orderRank(b.status);
        });
        state.ordersMore = !!result.more;
        state.ordersError = false;
      })
      .catch(function () { state.orders = []; state.ordersMore = false; state.ordersError = true; });
  }

  // web_url 透传(深链基址);未配置/未连接时静默——深链区隐藏
  function loadStatus() {
    return rawGet("/status").then(function (body) {
      state.webUrl = (body.web_url || "").toString();
    }).catch(function () { state.webUrl = ""; });
  }

  // 数据刷新统一入口(事件驱动与轮询共用)。报名缓存随刷新失效(agent 写操作
  // 后旧行不可信);展开态保留,展开供给重拉。
  function refreshData() {
    state.enrollments = {};
    const loads = [loadTasks(), loadCourses(), loadEvents(), loadOrders()];
    return Promise.all(loads).then(function () {
      const expanded = state.expandedOfferingId;
      if (expanded) return loadEnrollments(offeringKindOf(expanded), expanded);
    });
  }

  async function boot() {
    state.loading = true;
    state.error = null;
    renderPanel();
    try {
      await loadWorkspaces();
      await Promise.all([loadTasks(), loadStatus(), loadCourses(), loadEvents(), loadOrders()]);
      state.error = null;
    } catch (e) {
      state.error = e;
    } finally {
      state.loading = false;
      renderPanel();
    }
  }

  // 用户可控文本(姓名/标题/邮箱)进注入指令前中性化:换行/制表等折成空格,
  // 防伪造多行指令结构(写操作仍由 agent 两段式确认门兜底)
  function oneLine(s) {
    return String(s == null ? "" : s).replace(/[\r\n\t\u2028\u2029]+/g, " ").trim();
  }

  // 注入管理指令(当前已在 cgc-admin 会话,直接注入不创建)
  function injectIntoComposer(text) {
    const input = document.getElementById("user-input");
    const send = document.getElementById("btn-send");
    if (!input || !send) {
      window.prompt("复制以下指令:", text);
      return;
    }
    Kit.injectIntoComposer(input, send, text);
  }

  // 待办行 → 处理指令(台名前缀消歧:待办跨台聚合,agent 按名称切换上下文;
  // 行只带语义,id 由 agent 调 list_my_tasks 自取)
  function taskPrompt(t) {
    const ws = t._ws_name ? "[" + oneLine(t._ws_name) + "] " : "";
    const title = oneLine(t.context_title || t.title || t.requester_name || "");
    return "请处理 " + ws + "工作台的" + taskKindLabel(t.kind) + "待办：" + title +
      "。先调用 list_my_tasks 获取该待办详情，再按 playbook 流程处理。";
  }

  // 生命周期动作 → 注入指令(带 MCP 来源 id;提醒 agent 两段式:先看确认摘要)
  function lifecyclePrompt(kind, action, offeringId) {
    const offering = offeringById(offeringId) || {};
    const tool = action + "_" + kind;
    return "请" + LC_VERB[action] + KIND_LABEL[kind] + "「" + oneLine(offering.title || "") + "」" +
      "(" + kind + "_id=" + offeringId + "；调用 " + tool + " 先给我看确认摘要，我同意后再执行）。";
  }

  // 对话轻改 → 注入指令(单字段轻改走对话;重编辑由「网站编辑」深链承接)
  function editPrompt(kind, offeringId) {
    const offering = offeringById(offeringId) || {};
    return "我想修改" + KIND_LABEL[kind] + "「" + oneLine(offering.title || "") + "」的设置" +
      "(" + kind + "_id=" + offeringId + "；先告诉我 update_" + kind +
      " 可改哪些字段，我说一项你改一项，走确认流）。";
  }

  // 可行动报名行(pending/payment_pending) → 处理指令(offering_id 来自 MCP
  // 返回,可信标识直接带上,agent 无需先列表)
  function enrollPrompt(kind, offeringId, row) {
    const offering = offeringById(offeringId) || {};
    const who = oneLine((row.user && (row.user.display_name || row.user.email)) || "该报名人");
    return "请处理" + (KIND_LABEL[kind] || "课程/活动") + "「" + oneLine(offering.title || "") + "」中 " + who + " 的报名" +
      "（list_enrollments kind=" + kind + " offering_id=" + offeringId +
      " 确认详情后，按确认流处理，enrollment_id=" + row.enrollment_id + "）。";
  }

  // 供给查找(课程/活动统一,id 均 UUID 不撞)
  function offeringById(offeringId) {
    return state.courses.find(function (c) { return c.course_id === offeringId; }) ||
      state.events.find(function (e) { return e.event_id === offeringId; }) || null;
  }
  function offeringKindOf(offeringId) {
    if (state.events.some(function (e) { return e.event_id === offeringId; })) return "event";
    return "course";
  }

  // 订单行 → 查看指令(写动作由 agent 对话引导,行点击不直接发起退款)
  function orderPrompt(row) {
    const label = (ORDER_STATUS[row.status] || {}).label || row.status || "";
    return "请查看订单 " + row.order_id + " 的状态与关联报名，告诉我可执行的管理动作" +
      "（当前状态 " + label + "）。";
  }

  // 当前选中工作台(深链锚)
  function selectedWorkspace() {
    return state.workspaces.find(function (w) { return w.workspace_id === state.selectedWsId; }) || null;
  }

  function money(cents) {
    if (cents == null) return "";
    return "¥" + (Number(cents) / 100).toFixed(2);
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

    // 待办列表(行可点 → 注入处理指令)
    if (pendingCount === 0) {
      html += (state.tasksError
          ? '<div class="cgaa-empty">待办加载失败：所有工作台请求均未成功。</div>'
          : '<div class="cgaa-empty">暂无管理待办。</div>');
    } else {
      html += '<div class="cgaa-task-list">' + state.tasks.map(function (t, idx) {
        const dl = t.approval_deadline
          ? new Date(t.approval_deadline)
          : null;
        const dlText = dl && !isNaN(dl.getTime()) ? dl.toLocaleString() : "";
        return (
          '<button class="cgaa-task" type="button" data-task-idx="' + idx + '" data-testid="cgaa-task">' +
            '<span class="cgaa-task-kind">' + escapeHtml(taskKindLabel(t.kind)) + '</span>' +
            '<span class="cgaa-task-copy">' +
              escapeHtml(t._ws_name ? "[" + t._ws_name + "] " : "") +
              escapeHtml(t.context_title || t.title || t.requester_name || "") +
            '</span>' +
            (dlText ? '<span class="cgaa-task-dl">截止 ' + escapeHtml(dlText) + '</span>' : "") +
            '<span class="cgaa-task-go">›</span>' +
          '</button>'
        );
      }).join("") + '</div>';
    }

    html += renderSupplySection();
    html += renderOrdersSection();

    // 快捷入口(按域分组;注入指令,不创建新会话;写操作走对话确认流)
    html += '<div class="cgaa-groups">' + ACTION_GROUPS.map(function (g) {
      return '<div class="cgaa-group">' +
        '<div class="cgaa-group-label">' + escapeHtml(g.label) + '</div>' +
        '<div class="cgaa-actions">' + g.actions.map(function (a) {
          return '<button class="cgaa-action" type="button" data-action="' + escapeHtml(a.key) + '"' +
            (a.key === "create-course" ? ' data-testid="cgaa-quick-create"' : "") +
            '>' + escapeHtml(a.label) + '</button>';
        }).join("") + '</div>' +
      '</div>';
    }).join("") + '</div>';

    // 网站管理页深链(成员/权限/支付等重 UI 域不重造,跳 web 完成)
    const ws = selectedWorkspace();
    if (state.webUrl && ws && ws.slug) {
      const base = state.webUrl.replace(/\/+$/, "") + "/w/" + encodeURIComponent(ws.slug);
      html += '<div class="cgaa-links">' + WEB_LINKS.map(function (l) {
        return '<button class="cgaa-link" type="button" data-link-url="' +
          escapeHtml(base + l.path) + '">' + escapeHtml(l.label) + ' ↗</button>';
      }).join("") + '</div>';
    }

    html += '</div>';
    root.innerHTML = html;
    bind();
  }

  // 供给区(课程+活动统一投影,kind 徽章区分;课程在前活动在后,组内保持后端序。
  // 行点击展开/收起报名队列,可行动报名行可点注入。
  // 课程/活动错误隔离:扩展与后端部署天然不同步(新扩展连旧后端时活动面报错),
  // 任一源失败不拖死另一源;双源皆败才整体报错)
  function renderSupplySection() {
    const total = state.courses.length + state.events.length;
    let html = '<div class="cgaa-sec-label">课程与活动(' + total + ')</div>';
    if (state.coursesError && state.eventsError) {
      return html + '<div class="cgaa-empty">课程与活动加载失败。</div>';
    }
    if (total === 0 && !state.coursesError && !state.eventsError) {
      return html + '<div class="cgaa-empty">当前工作台暂无课程或活动。</div>';
    }
    const courseRows = state.coursesError
      ? ['<div class="cgaa-empty">课程加载失败。</div>']
      : state.courses.map(function (c) { return supplyRow("course", c); });
    const eventRows = state.eventsError
      ? ['<div class="cgaa-empty">活动加载失败。</div>']
      : state.events.map(function (e) { return supplyRow("event", e); });
    return html + '<div class="cgaa-course-list">' + courseRows.concat(eventRows).join("") + '</div>';
  }

  // 单个供给行 + 展开时的报名队列
  function supplyRow(kind, item) {
    const id = kind === "event" ? item.event_id : item.course_id;
    const st = OFFERING_STATUS[item.status] || { label: item.status || "", cls: "closed" };
    // draft 课叠教研徽章;open 活动叠报名徽章
    const extra = kind === "course"
      ? (item.status === "draft" ? PREP_STATE[item.prep_state] : null)
      : (item.status === "open" ? ENROLL_BADGE[item.enrollment_badge] : null);
    const expanded = state.expandedOfferingId === id;
    let row =
      '<button class="cgaa-course" type="button" data-offering-kind="' + kind + '"' +
        ' data-offering-id="' + escapeHtml(id) + '" data-testid="cgaa-course">' +
        '<span class="cgaa-badge cgaa-badge-kind-' + kind + '">' + KIND_LABEL[kind] + '</span>' +
        '<span class="cgaa-course-title">' + escapeHtml(item.title || (kind === "event" ? "未命名活动" : "未命名课程")) + '</span>' +
        (extra ? '<span class="cgaa-badge cgaa-badge-prep">' + escapeHtml(extra) + '</span>' : "") +
        '<span class="cgaa-badge cgaa-badge-' + st.cls + '">' + escapeHtml(st.label) + '</span>' +
        '<span class="cgaa-task-go">' + (expanded ? "⌄" : "›") + '</span>' +
      '</button>';
    if (expanded) row += renderEnrollments(kind, id) + renderOfferingActions(kind, item, id);
    return row;
  }

  // 报名队列(展开供给的下钻视图;pending/payment_pending 行可点注入处理指令)
  function renderEnrollments(kind, offeringId) {
    const enr = state.enrollments[offeringId];
    if (!enr) return '<div class="cgaa-enrolls"><div class="cgaa-enroll-loading">加载报名…</div></div>';
    if (enr.error) return '<div class="cgaa-enrolls"><div class="cgaa-enroll-loading">报名加载失败。</div></div>';
    if (enr.rows.length === 0) return '<div class="cgaa-enrolls"><div class="cgaa-enroll-loading">暂无报名。</div></div>';
    const rows = enr.rows.map(function (r, idx) {
      const st = ENROLL_STATUS[r.status] || { label: r.status || "", actionable: false };
      const who = (r.user && (r.user.display_name || r.user.email)) || "报名人";
      const tier = r.tier && r.tier.name ? " · " + r.tier.name : "";
      const inner =
        '<span class="cgaa-enroll-who">' + escapeHtml(who) + '</span>' +
        '<span class="cgaa-enroll-meta">' + escapeHtml(st.label + tier) + '</span>';
      if (st.actionable) {
        return '<button class="cgaa-enroll cgaa-enroll-act" type="button"' +
          ' data-enroll-kind="' + kind + '" data-enroll-offering="' + escapeHtml(offeringId) +
          '" data-enroll-idx="' + idx + '">' +
          inner + '<span class="cgaa-task-go">›</span></button>';
      }
      return '<div class="cgaa-enroll">' + inner + '</div>';
    }).join("");
    return '<div class="cgaa-enrolls">' + rows + '</div>';
  }

  // 展开区动作排(生命周期按状态门渲染 + 对话轻改注入 + 网站编辑深链;
  // 深链复用 [data-link-url] 既有 handler——scheme 白名单 + noopener 已在)
  function renderOfferingActions(kind, item, id) {
    const acts = LIFECYCLE_ACTIONS[item.status] || [];
    let html = '<div class="cgaa-rowacts">' + acts.map(function (a) {
      return '<button class="cgaa-rowact" type="button" data-lc-action="' + a.key +
        '" data-lc-kind="' + kind + '" data-lc-id="' + escapeHtml(id) + '">' +
        escapeHtml(a.label) + '</button>';
    }).join("");
    html += '<button class="cgaa-rowact" type="button" data-edit-inject="' + kind + '"' +
      ' data-lc-id="' + escapeHtml(id) + '">✎ 对话修改</button>';
    const ws = selectedWorkspace();
    if (state.webUrl && ws && ws.slug) {
      const url = state.webUrl.replace(/\/+$/, "") + "/w/" + encodeURIComponent(ws.slug) +
        (kind === "event" ? "/events/" : "/courses/") + encodeURIComponent(id);
      html += '<button class="cgaa-rowact" type="button" data-link-url="' + escapeHtml(url) +
        '">↗ 网站编辑</button>';
    }
    return html + '</div>';
  }

  // 订单区 = 注意力面:只渲染非终态(refund_failed 置顶),帽 5 行防待支付风暴;
  // 终态与帽外订单问助手(list_workspace_orders)或走 web 订单页。
  // 无非终态 = 无需要注意的订单,整区不渲染(同「无订单不渲染」哲学)
  const ORDER_ATTENTION_CAP = 5;
  function renderOrdersSection() {
    if (state.ordersError) {
      return '<div class="cgaa-sec-label">订单</div><div class="cgaa-empty">订单加载失败。</div>';
    }
    const attention = state.orders
      .map(function (o, idx) { return { o: o, idx: idx }; })
      .filter(function (r) { return (ORDER_STATUS[r.o.status] || {}).attention; })
      .sort(function (a, b) { return orderRank(a.o.status) - orderRank(b.o.status); });
    if (attention.length === 0) return "";
    const shown = attention.slice(0, ORDER_ATTENTION_CAP);
    const hidden = attention.length - shown.length;
    let html = '<div class="cgaa-sec-label">订单需处理（' + attention.length + '）</div>';
    html += '<div class="cgaa-order-list">' + shown.map(function (r) {
      const st = ORDER_STATUS[r.o.status] || { label: r.o.status || "", rank: 3 };
      const who = (r.o.enrollment && r.o.enrollment.learner_email) || "";
      const tier = r.o.tier_name ? " · " + r.o.tier_name : "";
      return '<button class="cgaa-order" type="button" data-order-idx="' + r.idx + '"' +
        ' data-testid="cgaa-order">' +
        '<span class="cgaa-order-amt">' + escapeHtml(money(r.o.amount_cents)) + '</span>' +
        '<span class="cgaa-badge' + (st.warn ? " cgaa-badge-warn" : "") + '">' + escapeHtml(st.label) + '</span>' +
        '<span class="cgaa-order-who">' + escapeHtml(who + tier) + '</span>' +
        '<span class="cgaa-task-go">›</span>' +
      '</button>';
    }).join("") + '</div>';
    if (hidden > 0 || state.ordersMore) {
      html += '<div class="cgaa-more">还有 ' + hidden + ' 笔非终态' +
        (state.ordersMore ? "（后端还有更多）" : "") + '，问助手看全部。</div>';
    }
    return html;
  }

  const ACTION_GROUPS = [
    { label: "课程与活动", actions: [
      { key: "create-course", label: "+ 创建课程" },
      { key: "create-event", label: "+ 创建活动" }
    ]},
    { label: "成员", actions: [
      { key: "invite", label: "✉ 邀请成员" },
      { key: "join-requests", label: "☑ 加入申请" }
    ]},
    { label: "财务", actions: [
      { key: "orders", label: "◈ 订单" },
      { key: "review", label: "☑ 待办总览" }
    ]}
  ];

  const ACTION_PROMPTS = {
    "create-course": "请帮我创建一门新课程，引导我描述课程定位(受众/章节/时长)。",
    "create-event": "请帮我创建一场新活动，引导我描述活动主题、时间、地点(venue)、报名策略与定价。",
    "invite": "请帮我邀请一位成员加入当前工作台。",
    "join-requests": "请列出当前工作台的待审批加入申请，逐条告诉我申请人信息。",
    "orders": "请列出当前工作台的订单，非终态(待支付/退款中/退款失败)优先说明。",
    "review": "请列出我当前所有待审批事项，逐条告诉我详情。"
  };

  // 深链(相对 /w/<slug>;settings 重 UI 域 + 课程/活动业务页)
  const WEB_LINKS = [
    { label: "成员", path: "/settings/members" },
    { label: "权限", path: "/settings/permissions" },
    { label: "邀请", path: "/settings/invitations" },
    { label: "加入策略", path: "/settings/join-policy" },
    { label: "支付", path: "/settings/payments" },
    { label: "赞助", path: "/settings/sponsorship" },
    { label: "课程页", path: "/courses" },
    { label: "活动页", path: "/events" }
  ];

  function bind() {
    const refresh = root.querySelector("#cgaa-refresh");
    if (refresh) refresh.addEventListener("click", boot);
    const ws = root.querySelector("#cgaa-ws");
    if (ws) ws.addEventListener("change", function () {
      state.selectedWsId = ws.value;
      localStorage.setItem("cgc2046.adminAside.workspaceId", ws.value);
      state.enrollments = {};
      state.expandedOfferingId = "";
      Promise.all([loadTasks(), loadCourses(), loadEvents(), loadOrders()]).then(renderPanel);
    });
    root.querySelectorAll("[data-task-idx]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        const t = state.tasks[parseInt(btn.getAttribute("data-task-idx"), 10)];
        if (t) injectIntoComposer(taskPrompt(t));
      });
    });
    root.querySelectorAll("[data-offering-id]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        const id = btn.getAttribute("data-offering-id");
        const kind = btn.getAttribute("data-offering-kind") || "course";
        if (!id) return;
        if (state.expandedOfferingId === id) {
          state.expandedOfferingId = "";
          renderPanel();
          return;
        }
        state.expandedOfferingId = id;
        renderPanel();
        loadEnrollments(kind, id).then(renderPanel);
      });
    });
    root.querySelectorAll("[data-enroll-offering]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        const offeringId = btn.getAttribute("data-enroll-offering");
        const kind = btn.getAttribute("data-enroll-kind") || "course";
        const enr = state.enrollments[offeringId];
        const row = enr && enr.rows[parseInt(btn.getAttribute("data-enroll-idx"), 10)];
        if (row) injectIntoComposer(enrollPrompt(kind, offeringId, row));
      });
    });
    root.querySelectorAll("[data-lc-action]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        injectIntoComposer(lifecyclePrompt(
          btn.getAttribute("data-lc-kind") || "course",
          btn.getAttribute("data-lc-action"),
          btn.getAttribute("data-lc-id")));
      });
    });
    root.querySelectorAll("[data-edit-inject]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        injectIntoComposer(editPrompt(
          btn.getAttribute("data-edit-inject"), btn.getAttribute("data-lc-id")));
      });
    });
    root.querySelectorAll("[data-order-idx]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        const o = state.orders[parseInt(btn.getAttribute("data-order-idx"), 10)];
        if (o) injectIntoComposer(orderPrompt(o));
      });
    });
    root.querySelectorAll("[data-action]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        const action = btn.getAttribute("data-action");
        const prompt = ACTION_PROMPTS[action];
        if (prompt) injectIntoComposer(prompt);
      });
    });
    root.querySelectorAll("[data-link-url]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        const url = btn.getAttribute("data-link-url");
        // scheme 白名单 + noopener(webUrl 来自 /status 透传,防配置污染注入 javascript:)
        if (url && /^https?:\/\//.test(url)) window.open(url, "_blank", "noopener,noreferrer");
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
      ".cgaa-sec-label{font-size:0.625rem;font-weight:700;color:var(--color-text-tertiary);padding:2px 2px 0}",
      ".cgaa-task-list{display:flex;flex-direction:column;border:1px solid var(--color-border-primary);border-radius:var(--radius-lg,10px);overflow:hidden;background:var(--color-bg-card)}",
      ".cgaa-task{display:flex;gap:8px;align-items:baseline;width:100%;padding:8px 10px;border:0;border-bottom:1px solid var(--color-border-secondary);background:transparent;color:inherit;font:inherit;font-size:0.6875rem;text-align:left;cursor:pointer;transition:background var(--transition-fast)}",
      ".cgaa-task:hover{background:var(--color-bg-subtle)}",
      ".cgaa-task:last-child{border-bottom:0}",
      ".cgaa-task-kind{flex:none;font-size:0.5625rem;font-weight:700;padding:0 5px;min-height:14px;display:inline-flex;align-items:center;border-radius:999px;border:1px solid color-mix(in srgb,var(--color-accent-primary) 35%,var(--color-border-primary));color:var(--color-accent-primary)}",
      ".cgaa-task-copy{flex:1;min-width:0;word-break:break-all}",
      ".cgaa-task-dl{flex:none;font-size:0.5625rem;color:var(--color-warning,#fbbf24)}",
      ".cgaa-task-go{flex:none;color:var(--color-text-tertiary);font-size:0.75rem}",
      ".cgaa-task:hover .cgaa-task-go{color:var(--color-accent-primary)}",
      ".cgaa-badge{flex:none;font-size:0.5625rem;font-weight:700;padding:0 5px;min-height:14px;display:inline-flex;align-items:center;border-radius:999px;border:1px solid var(--color-border-secondary);color:var(--color-text-secondary)}",
      ".cgaa-badge-kind-course{border-color:transparent;background:#2563eb;color:#fff}",
      ".cgaa-badge-kind-event{border-color:transparent;background:#b45309;color:#fff}",
      ".cgaa-badge-open{border-color:color-mix(in srgb,var(--color-success,#34d399) 40%,var(--color-border-primary));color:var(--color-success,#34d399)}",
      ".cgaa-badge-draft{border-color:color-mix(in srgb,var(--color-warning,#fbbf24) 40%,var(--color-border-primary));color:var(--color-warning,#fbbf24)}",
      ".cgaa-badge-prep{border-color:color-mix(in srgb,var(--color-accent-primary) 35%,var(--color-border-primary));color:var(--color-accent-primary)}",
      ".cgaa-badge-warn{border-color:color-mix(in srgb,var(--color-error,#c0392b) 45%,var(--color-border-primary));color:var(--color-error,#c0392b)}",
      ".cgaa-course-list{display:flex;flex-direction:column;border:1px solid var(--color-border-primary);border-radius:var(--radius-lg,10px);overflow:hidden;background:var(--color-bg-card)}",
      ".cgaa-course{display:flex;gap:6px;align-items:center;width:100%;padding:8px 10px;border:0;border-bottom:1px solid var(--color-border-secondary);background:transparent;color:inherit;font:inherit;font-size:0.6875rem;text-align:left;cursor:pointer;transition:background var(--transition-fast)}",
      ".cgaa-course:hover{background:var(--color-bg-subtle)}",
      ".cgaa-course:last-child{border-bottom:0}",
      ".cgaa-course-title{flex:1;min-width:0;word-break:break-all;font-weight:600}",
      ".cgaa-enrolls{border-bottom:1px solid var(--color-border-secondary);background:var(--color-bg-subtle);padding:2px 0}",
      ".cgaa-enroll{display:flex;gap:6px;align-items:baseline;width:100%;padding:5px 10px 5px 18px;font-size:0.6563rem;color:var(--color-text-secondary);border:0;background:transparent;font:inherit;text-align:left}",
      ".cgaa-enroll-act{cursor:pointer;color:var(--color-text-primary);transition:background var(--transition-fast)}",
      ".cgaa-enroll-act:hover{background:var(--color-bg-card)}",
      ".cgaa-enroll-who{flex:1;min-width:0;word-break:break-all}",
      ".cgaa-enroll-meta{flex:none;font-size:0.5625rem;color:var(--color-text-tertiary)}",
      ".cgaa-enroll-loading{padding:6px 18px;font-size:0.625rem;color:var(--color-text-tertiary)}",
      ".cgaa-rowacts{display:flex;gap:6px;align-items:center;padding:6px 10px 8px 18px;background:var(--color-bg-subtle);border-bottom:1px solid var(--color-border-secondary)}",
      ".cgaa-rowact{padding:3px 8px;border:1px solid var(--color-border-secondary);border-radius:var(--radius-md,8px);background:transparent;color:var(--color-text-secondary);font-size:0.625rem;font-weight:650;cursor:pointer;font-family:inherit;transition:border-color var(--transition-fast),color var(--transition-fast)}",
      ".cgaa-rowact:hover{border-color:var(--color-accent-primary);color:var(--color-accent-primary)}",
      ".cgaa-order-list{display:flex;flex-direction:column;border:1px solid var(--color-border-primary);border-radius:var(--radius-lg,10px);overflow:hidden;background:var(--color-bg-card)}",
      ".cgaa-order{display:flex;gap:6px;align-items:center;width:100%;padding:7px 10px;border:0;border-bottom:1px solid var(--color-border-secondary);background:transparent;color:inherit;font:inherit;font-size:0.6875rem;text-align:left;cursor:pointer;transition:background var(--transition-fast)}",
      ".cgaa-order:hover{background:var(--color-bg-subtle)}",
      ".cgaa-order:last-child{border-bottom:0}",
      ".cgaa-order-amt{flex:none;font-weight:650;font-variant-numeric:tabular-nums}",
      ".cgaa-order-who{flex:1;min-width:0;word-break:break-all;color:var(--color-text-secondary);font-size:0.625rem}",
      ".cgaa-more{padding:4px 2px 0;font-size:0.5625rem;color:var(--color-text-tertiary)}",
      ".cgaa-groups{display:flex;flex-direction:column;gap:8px}",
      ".cgaa-group-label{font-size:0.625rem;font-weight:700;color:var(--color-text-tertiary);padding:0 2px 4px}",
      ".cgaa-actions{display:grid;grid-template-columns:repeat(3,1fr);gap:6px}",
      ".cgaa-action{padding:8px 6px;border:1px solid var(--color-border-secondary);border-radius:var(--radius-md,8px);background:var(--color-bg-subtle);color:var(--color-text-primary);font-size:0.625rem;font-weight:650;cursor:pointer;font-family:inherit;text-align:center;transition:border-color var(--transition-fast),color var(--transition-fast)}",
      ".cgaa-action:hover{border-color:var(--color-accent-primary);color:var(--color-accent-primary)}",
      ".cgaa-links{display:flex;flex-wrap:wrap;gap:6px;border-top:1px solid var(--color-border-secondary);padding-top:10px}",
      ".cgaa-link{padding:4px 8px;border:0;background:transparent;color:var(--color-text-tertiary);font-size:0.625rem;font-weight:600;cursor:pointer;font-family:inherit;border-radius:var(--radius-sm,6px);transition:color var(--transition-fast),background var(--transition-fast)}",
      ".cgaa-link:hover{color:var(--color-accent-primary);background:var(--color-bg-subtle)}"
    ].join("\n");
    document.head.appendChild(css);
  }

  injectStyles();

  // 事件驱动即时刷新(模块顶层订阅一次——aside 随会话反复 mount,handler 内判
  // root 存活;debounce 合并 agent 连续工具调用,只刷新数据不重挂载)
  Clacky.ext.subscribe("ext.cgc-2046.tool_used", function (payload) {
    if (!payload || payload.status !== "ok") return;
    if (!root || !document.contains(root)) return;
    if (refreshDebouncer) clearTimeout(refreshDebouncer);
    refreshDebouncer = setTimeout(function () {
      refreshData().then(renderPanel).catch(function () { /* 静默 */ });
    }, EVENT_REFRESH_DEBOUNCE_MS);
  });

  Clacky.ext.ui.mount("session.aside", function (container, ctx) {
    if (!ctx || ctx.agentProfile !== AGENT || !ctx.sessionId) return;
    root = document.createElement("div");
    root.className = "cgaa-root";
    container.appendChild(root);
    boot();
    if (pollStop) pollStop();  // 重复 mount(多 cgc-admin 会话)不叠加轮询
    pollStop = Kit.poll(POLL_MS, async function () {
      try { await refreshData(); } catch (e) { /* 静默 */ }
      renderPanel();
    }, { container: function () { return root; } });
  }, {
    agents: [AGENT],
    order: 20,
    tab: {
      id: "cgc-2046-admin-aside",
      label: function () { return "工作台管理"; }
    }
  });
})();
