// CGC-2046 课程学习面板(U9,plan 001 / #180 R15;role-agent-journeys-v2 S4-extension
// 加教研侧草稿编辑与自动刷新;S5-extension 加教研流程状态区)。
//
// 结构:Workspace 选择器(按名选择,用户永不手填 UUID,S1 finding 收敛)→
// 我的课程 → issue 列表(三态)→ 当前 issue 卡(goal/given/materials/checklist
// 打勾态)→「和导师学这一节」唤起学习会话(Rsk3 降级:复制任务指令文本,粘贴
// 到会话;记录写回发生在 session 工具调用)。
//
// S4 教研侧编辑(R9/R10,AE2):当前 Workspace 角色含 tutor|owner|admin 时
// (canEdit)详情页出现「编辑内容」入口——goals/issues 表单化编辑,保存走
// POST /courses/:id/content(透传 save_course_content,携带 base_version);
// 409 version_conflict → 丢弃本地编辑 + 红色横幅 + 重载最新草稿。
// 编辑仅做 UX 门控,网站 RBAC 为唯一权威(工具层 tutor ∪ owner/admin 判定)。
//
// S5 教研流程状态区(R22-R28):canEdit 详情页拉取 GET /courses/:id/prep
// (透传 get_prep_status)——prep_state badge / 生效策略(阈值与是否需人工审核)/
// 结构门禁违规清单 / 最新质量报告。存量课程无 prep run(上游「no preparation
// run found」)或拉取失败时本区不渲染,不置面板错误态。
//
// R11 自动刷新:面板可见时 10s 轮询(详情 = 草稿 version + 记录签名,列表 =
// 记录签名),变化只亮非侵入更新条,不打断浏览;编辑/保存态轮询挂起(陈旧基准
// 由保存时 409 兜底);手动刷新按钮常驻。
//
// 数据通道:面板 fetch 扩展 loopback 路由(/api/ext/cgc-2046/*)→
// 扩展 core 作为 MCP 客户端透传学习面工具(S8:get_learning_state /
// start_learning_run / get_course_revision;内容编辑面 get_course_content /
// save_course_content / get_prep_status;dsh-cgc-core 已验证模式)。
//
// 未连接态(loopback 503 或 status 未配置)→ 引导视图(去连接面板)。

(() => {
  "use strict";
  if (!window.Clacky || !Clacky.ext || Clacky.ext.pure) return;

  const API = "/api/ext/cgc-2046";
  const WS_ID = "cgc-2046-course";
  const STORE_KEY = "cgc2046.coursePanel.workspaceId";
  let csrfToken = "";                 // advisor F2:写路由 CSRF token(lazy 经 /status 取)
  const POLL_MS = 10000;
  let currentContainer = null;
  let pollTimer = null;

  // ---- 面板状态 ----
  const state = {
    bootStarted: false,
    loadingBoot: false,
    bootError: null,
    workspaces: [],    // [{ workspace_id, name, slug, roles }](list_my_workspaces)
    workspaceId: "",
    canEdit: false,    // 当前 Workspace 角色含 tutor|owner|admin(S4 编辑入口)
    prep: null,        // S5 教研流程状态(get_prep_status;仅 canEdit 详情拉取,无 prep run → null)
    courses: [],       // [{ courseId, title, workspaceId, workspaceName }]（S7:/me/enrollments 源）
    inFlight: [],      // 报名进行中(pending/payment_pending 课程报名)
    coursesSig: "",    // 列表签名(轮询变更检测)
    selected: null,    // { courseId, content, records }
    detailSig: "",     // 详情签名(version + 记录;轮询变更检测)
    currentIssue: null,
    editing: false,    // S4 草稿编辑态(编辑中轮询挂起)
    draft: null,       // 编辑工作副本 { goals: [], issues: [] }
    draftContent: null,// 编辑基准草稿原文(get_course_content 全量,含 version 与未知键)
    saving: false,
    saveError: null,
    conflict: null,    // 409 冲突横幅文案(AE2)
    updateNotice: false, // 详情轮询发现变化(非侵入条)
    listNotice: false, // 列表轮询发现变化(非侵入条)
    loading: false,
    error: null,
    copied: false
  };

  function escapeHtml(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  // 记录 → (issue_id, item_id) done 集
  // ---- 角色 / 版本 / 签名 ----
  const EDIT_ROLES = ["tutor", "owner", "admin"];

  // 网站 RBAC 为唯一权威,面板只做 UX 门控
  function computeCanEdit() {
    const ws = state.workspaces.find(function (w) { return w.workspace_id === state.workspaceId; });
    const roles = (ws && ws.roles) || [];
    state.canEdit = roles.some(function (r) { return EDIT_ROLES.indexOf(r) >= 0; });
  }

  // 草稿版本:进入编辑时拉取的 get_course_content 结果顶层 version;缺失按 0(首存)
  function draftVersion() {
    const v = state.draftContent && state.draftContent.version;
    return Number.isInteger(v) ? v : 0;
  }

  // S8 学习状态签名(objective mastery/attempt_count + progress + next_action;
  // 不含 version/时间戳——详情轮询变更检测用);S9 起并入 review_queue 四字段
  // (里程碑到期/恢复条目变化同样亮更新条)
  function learningSignature(learning) {
    const mastery = {};
    ((learning && learning.objectives) || []).forEach(function (o) {
      mastery[String(o.id)] = String(o.mastery) + ":" + String(o.attempt_count);
    });
    const progress = (learning && learning.progress) || {};
    const next = (learning && learning.next_action) || {};
    const review = ((learning && learning.review_queue) || []).map(function (e) {
      return String(e.objective_id) + ":" + String(e.due_at) + ":" +
        String(e.milestone_days) + ":" + String(e.needs_review);
    });
    return [JSON.stringify(mastery),
            String(progress.mastered_required) + "/" + String(progress.total_required) + ":" + String(progress.complete),
            String(next.objective_id || ""), review.join("|")].join(";");
  }

  // 报名列表签名(enrollment id + status),S7 列表轮询变更检测用
  function enrollmentsSignature(enrollments) {
    return (enrollments || []).map(function (e) {
      return String(e.id) + ":" + String(e.status);
    }).sort().join(",");
  }

  // 学习记录签名(issue/item/done 三元组),轮询变更检测用
  function recordsSignature(records) {
    return (records || []).map(function (r) {
      return String(r.course_id) + "/" + String(r.issue_id) + "/" + String(r.item_id) + ":" + (r.done ? "1" : "0");
    }).sort().join("|");
  }

  // 详情签名:草稿 version(编辑域外的他人写入检测)+ 记录签名
  function detailSignature(content, records) {
    const v = content && Number.isInteger(content.version) ? content.version : 0;
    return "v" + v + ";" + recordsSignature(records);
  }

  // ---- 数据加载 ----
  // 不带 workspace_id 的裸 GET(仅 /me/workspaces 身份路由用)
  async function rawGet(path) {
    const res = await fetch(API + path, { headers: { Accept: "application/json" } });
    const body = await res.json().catch(function () { return {}; });
    if (!res.ok) throw Object.assign(new Error(body.error || "HTTP " + res.status), { body, status: res.status });
    return body;
  }

  // advisor F2:写路由 CSRF token(lazy 经 /status 同源取一次,失败静默——
  // 写请求会因缺 token 403,用户重试时 /status 已恢复)
  async function ensureCsrf() {
    if (csrfToken) return;
    try {
      const res = await fetch(API + "/status", { headers: { Accept: "application/json" } });
      const body = await res.json().catch(function () { return {}; });
      if (res.ok && body.csrf_token) csrfToken = String(body.csrf_token);
    } catch (e) { /* 静默:写请求会因缺 token 403,用户可重试 */ }
  }

  async function apiGet(path) {
    const sep = path.indexOf("?") >= 0 ? "&" : "?";
    const res = await fetch(API + path + sep + "workspace_id=" + encodeURIComponent(state.workspaceId), {
      headers: { Accept: "application/json" }
    });
    const body = await res.json().catch(function () { return {}; });
    if (!res.ok) throw Object.assign(new Error(body.error || "HTTP " + res.status), { body, status: res.status });
    return body;
  }

  // POST JSON(S4 草稿保存);错误体挂 status/body(409 走冲突 UX)
  function postHeaders() {
    const headers = { "Content-Type": "application/json", Accept: "application/json" };
    if (csrfToken) headers["X-CGC-CSRF-Token"] = csrfToken;
    return headers;
  }

  // advisor R2:403-on-CSRF 自愈——重取 token(宿主热重载轮换进程级 token)
  async function refreshCsrf() {
    csrfToken = "";
    await ensureCsrf();
    return !!csrfToken;
  }

  async function apiPost(path, payload) {
    await ensureCsrf();
    let res = await fetch(API + path, { method: "POST", headers: postHeaders(), body: JSON.stringify(payload) });
    if (res.status === 403 && (await refreshCsrf())) {
      res = await fetch(API + path, { method: "POST", headers: postHeaders(), body: JSON.stringify(payload) });
    }
    const body = await res.json().catch(function () { return {}; });
    if (!res.ok) throw Object.assign(new Error(body.message || body.error || "HTTP " + res.status), { body, status: res.status });
    return body;
  }

  // ---- 10s 轮询(R11) ----
  // 只探测不打断:发现变化只亮非侵入条,视图由用户点击刷新;编辑/保存/加载态
  // 挂起;容器脱离 DOM(面板关闭)自停;失败静默下轮重试。
  function stopPolling() {
    if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
  }

  function startPolling() {
    stopPolling();
    pollTimer = setInterval(pollTick, POLL_MS);
  }

  // R1 P2-1:页面隐藏跳本轮(R11「面板可见时」口径);in-flight 闸防单轮 >10s 叠请求。
  let pollInFlight = false;

  async function pollTick() {
    if (!currentContainer || !document.contains(currentContainer)) { stopPolling(); return; }
    if (document.hidden || pollInFlight) return;
    if (state.editing || state.saving || state.loading || state.loadingBoot) return;
    if (state.error) return;
    // 详情态的作用域查询(草稿/记录)需要 workspaceId;列表态轮询 /me/enrollments 无需
    if (state.selected && !state.workspaceId) return;
    pollInFlight = true;
    try {
      if (state.selected) {
        // 详情页:学习状态签名(mastery/attempt/progress 变化检测)
        const learningRes = await apiGet("/learning_state?workspace_id=" + encodeURIComponent(state.workspaceId) +
          "&course_id=" + encodeURIComponent(state.selected.courseId));
        const sig = learningSignature(learningRes.result || {});
        if (sig !== state.detailSig) {
          state.updateNotice = true;
          render();
        }
      } else {
        // S7:列表页轮询报名列表(签名为 enrollment id+status)
        const payload = await rawGet("/me/enrollments");
        const sig = enrollmentsSignature((payload.result && payload.result.enrollments) || []);
        if (sig !== state.coursesSig) {
          state.listNotice = true;
          render();
        }
      }
    } catch (e) { /* 轮询失败静默,下轮重试 */ } finally { pollInFlight = false; }
  }

  // 开面板引导:拉可访问 Workspace 列表 → 解析选中(持久化 id 有效则沿用,
  // 否则回退第一项)→ 自动加载课程。503 走未连接引导,其它错误进 gate 视图。
  async function boot() {
    state.loadingBoot = true;
    state.bootError = null;
    state.error = null;
    render();
    try {
      const payload = await rawGet("/me/workspaces");
      const result = payload.result || {};
      state.workspaces = Array.isArray(result.workspaces) ? result.workspaces : [];
      const stored = localStorage.getItem(STORE_KEY) || "";
      const found = state.workspaces.find(function (w) { return w.workspace_id === stored; });
      const chosen = found || state.workspaces[0] || null;
      state.workspaceId = chosen ? String(chosen.workspace_id) : "";
      if (chosen) localStorage.setItem(STORE_KEY, state.workspaceId);
      computeCanEdit();
    } catch (e) {
      state.workspaces = [];
      if (e && e.status === 503) state.error = e; else state.bootError = e;
    } finally {
      state.loadingBoot = false;
      render();
    }
    // advisor F1(AE8/R35):/me/enrollments 是 actor 锚定跨台读,与 workspace
    // 选择解耦——零成员身份的公开课报名(confirmed)同样要出现在列表。
    // workspace 选择仅在打开作用域详情时要求(openCourse 以报名行
    // data-ws/workspace_id 原值驱动)。
    loadCourses();
  }

  // S7(AE8/R35):列表源 = /me/enrollments(跨 workspace,无需 workspace_id);
  // confirmed 课程报名 = 可学习课程(零学习记录也显示),pending/payment_pending
  // 入「报名进行中」区
  async function loadCourses() {
    state.loading = true;
    state.error = null;
    state.listNotice = false;
    render();
    try {
      const payload = await rawGet("/me/enrollments");
      const enrollments = (payload.result && payload.result.enrollments) || [];
      state.coursesSig = enrollmentsSignature(enrollments);
      const courseEnrollments = enrollments.filter(function (e) { return e.kind === "course"; });
      state.courses = courseEnrollments
        .filter(function (e) { return e.status === "confirmed"; })
        .map(function (e) {
          const offering = e.offering || {};
          const ws = e.workspace || {};
          return {
            courseId: String(offering.id || ""),
            title: String(offering.title || ""),
            // advisor F4:workspace_id 原值兜底（invite_only 台 ws 块 nil 场景）
            workspaceId: String(ws.id || e.workspace_id || ""),
            workspaceName: String(ws.name || ws.slug || "")
          };
        })
        .filter(function (c) { return c.courseId !== ""; });
      state.inFlight = courseEnrollments.filter(function (e) {
        return e.status === "pending" || e.status === "payment_pending";
      });
      state.selected = null;
      state.currentIssue = null;
    } catch (e) {
      state.error = e;
      state.courses = [];
      state.inFlight = [];
    } finally {
      state.loading = false;
      render();
    }
  }

  // S7:报名跨 workspace——行携带 data-ws,打开时若目标工作台 ≠ 当前选中,
  // 切换读面上下文(详情/草稿/教研都按该 workspace 读)
  async function openCourse(courseId, workspaceId) {
    if (workspaceId && workspaceId !== state.workspaceId) {
      state.workspaceId = workspaceId;
      localStorage.setItem(STORE_KEY, workspaceId);
      computeCanEdit();
    }
    state.loading = true;
    state.error = null;
    state.updateNotice = false;
    state.prep = null;
    render();
    try {
      // S8(ADR-0011):详情主数据源 = /learning_state(objective 课程地图);
      // /content 仍拉(编辑器与教研视图用);/revision 展示增强(state 为底
      // 永不丢 objective;未发布课程无 revision 退化 state 自带字段,不算失败)
      const [contentRes, learningRes] = await Promise.all([
        apiGet("/courses/" + encodeURIComponent(courseId) + "/content").catch(function () { return { result: {} }; }),
        apiGet("/learning_state?workspace_id=" + encodeURIComponent(state.workspaceId) +
          "&course_id=" + encodeURIComponent(courseId))
      ]);
      let revision = null;
      try {
        const revRes = await apiGet("/courses/" + encodeURIComponent(courseId) + "/revision");
        revision = revRes.result || null;
      } catch (e) {
        if (!(e && /no published revision/.test(e.message || ""))) throw e;
      }
      const content = contentRes.result || {};
      const learning = learningRes.result || {};
      state.selected = { courseId: courseId, content: content, learning: learning, revision: revision };
      state.detailSig = learningSignature(learning);
      state.currentIssue = null;
      // S5:教研状态仅 canEdit 视图拉取;存量课程无 prep run(上游
      // 「no preparation run found」)或任何失败都按无流程处理,不置错误态
      if (state.canEdit) {
        try {
          const prepRes = await apiGet("/courses/" + encodeURIComponent(courseId) + "/prep");
          state.prep = prepRes.result || null;
        } catch (e) {
          state.prep = null;
        }
      }
    } catch (e) {
      state.error = e;
      state.selected = null;
    } finally {
      state.loading = false;
      render();
    }
  }

  // S8 CTA 话术:objective 口径(objective_id + submit_learning_attempt);
  // 课程名走 get_learning_state 无 title,退 content.course_title
  function learningPrompt(objectiveId, reviewEntry) {
    const sel = state.selected || {};
    const learning = sel.learning || {};
    const obj = (learning.objectives || []).find(function (o) { return o.id === objectiveId; }) || {};
    const title = (sel.content && sel.content.course_title) || "本课程";
    const objTitle = obj.title || objectiveId;
    if (reviewEntry) {
      return [
        "请带我复习课程《" + title + "》的学习目标「" + objTitle + "」。",
        "(objective_id: " + objectiveId + ")",
        "这是一次到期复习——先诊断我的保留度,再针对性讲解;",
        "复习后正式评价:调用 submit_learning_attempt,evidence 写一句证据摘要,",
        "rubric_results 精确覆盖该目标 rubric 全部 criterion id。"
      ].join("\n");
    }
    return [
      "请和我一起学习课程《" + title + "》的学习目标「" + objTitle + "」。",
      "(objective_id: " + objectiveId + ")",
      "请按 learner playbook 的七步学习循环:先 get_learning_state 读取课程地图与当前进度,",
      "按 next_action 的 reason 从该目标开始教学;正式评价时调用 submit_learning_attempt,",
      "evidence 写一句证据摘要,rubric_results 精确覆盖该目标 rubric 全部 criterion id。"
    ].join("\n");
  }

  async function copySessionPrompt(objectiveId, reviewById) {
    const text = learningPrompt(objectiveId, (reviewById || {})[String(objectiveId)]);
    try {
      await navigator.clipboard.writeText(text);
      state.copied = true;
      setTimeout(function () { state.copied = false; render(); }, 2000);
    } catch (e) {
      window.prompt("复制以下指令到会话开始学习:", text);
    }
    render();
  }

  // ---- 渲染 ----
  function render(container) {
    currentContainer = container || currentContainer;
    if (!currentContainer) return;
    if (!state.bootStarted) {
      state.bootStarted = true;
      shell('<div class="cgc-card">加载中…</div>');
      boot();
      return;
    }
    if (state.error && state.error.status === 503) {
      stopPolling();
      renderNotConnected();
      return;
    }
    if (state.error && state.error.status !== 503) {
      stopPolling();
      shell('<div class="cgc-card cgc-ev-err">加载失败:' + escapeHtml(state.error.message || "") + '</div>');
      return;
    }
    if (!state.selected) {
      renderCourseList();
    } else {
      renderCourseDetail();
    }
    maybeStartPolling();
  }

  // 编辑/保存态不轮询(陈旧基准由保存时 409 兜底);其余可见态确保轮询在跑
  function maybeStartPolling() {
    if (state.editing || state.saving) return;
    startPolling();
  }

  function shell(inner) {
    currentContainer.innerHTML =
      '<div class="cgc-panel cgc-course-panel">' +
        '<h3 class="cgc-panel-title">CGC 课程学习</h3>' +
        inner +
      '</div>';
  }

  // 课程列表头部的 Workspace 选择器:按名称切换(S1 finding:用户永不手填 UUID)
  function pickerRow() {
    const opts = state.workspaces.map(function (w) {
      const sel = w.workspace_id === state.workspaceId ? " selected" : "";
      return '<option value="' + escapeHtml(w.workspace_id) + '"' + sel + '>' +
             escapeHtml(w.name || w.slug || w.workspace_id) + '</option>';
    }).join("");
    return '<div class="cgc-ws-row"><select id="cgc-ws-switch" class="cgc-select">' + opts + '</select></div>';
  }

  function bindWorkspaceSwitch() {
    const sw = currentContainer.querySelector("#cgc-ws-switch");
    if (!sw) return;
    sw.addEventListener("change", function () {
      state.workspaceId = sw.value;
      localStorage.setItem(STORE_KEY, sw.value);
      // R1 P2-2:切换 Workspace 清空旧课程详情与编辑态——否则旧 course_id 滞留,
      // 轮询拿旧 course_id + 新 workspace_id 静默失败,编辑保存更是写错目标。
      state.selected = null;
      state.currentIssue = null;
      state.conflict = null;
      state.updateNotice = false;
      state.editing = false;
      state.prep = null;
      state.draft = null;
      state.draftContent = null;
      state.saveError = null;
      computeCanEdit();
      loadCourses();
    });
  }

  function renderNotConnected() {
    shell(
      '<div class="cgc-banner" data-testid="panel-not-connected">' +
        '<b>CGC-2046 未连接。</b>' + escapeHtml(state.error.message || "") +
        '<div class="cgc-banner-hint">请先在 CGC-2046 连接面板完成连接(生成 token 并连接),再使用课程学习面板。</div>' +
      '</div>' +
      // smoke01 #2:显式重试入口——boot 重探 loopback(先 /me/workspaces 后 /courses),
      // 成功进课程列表、仍 503 则回到本引导视图(不再需要整页刷新恢复)。
      '<div class="cgc-actions">' +
        '<button id="cgc-retry" class="cgc-btn cgc-btn-secondary" type="button" data-testid="panel-retry">重试</button>' +
      '</div>'
    );
    currentContainer.querySelector("#cgc-retry").addEventListener("click", boot);
  }

  function renderCourseList() {
    let inner = pickerRow();

    // advisor F1:workspace 列表加载失败或零成员身份——非阻断提示条
    // (报名列表跨台加载照常;详情打开由报名行作用域驱动)
    if (state.bootError) {
      inner += '<div class="cgc-card cgc-ev-err" data-testid="panel-ws-boot-error">Workspace 列表加载失败:' +
        escapeHtml(state.bootError.message || "") +
        ' <button id="cgc-boot-retry" class="cgc-btn cgc-btn-secondary cgc-btn-mini" type="button">重试</button></div>';
    } else if (state.workspaces.length === 0) {
      inner += '<p class="cgc-panel-sub">当前账号没有可访问的 Workspace——课程列表来自你的报名,跨 Workspace 显示。</p>';
    }

    inner +=
      '<p class="cgc-panel-sub">我的课程(按报名推导,跨 Workspace)</p>' +
      '<div class="cgc-actions"><button id="cgc-refresh" class="cgc-btn cgc-btn-secondary" type="button">刷新</button></div>';

    // R11 列表轮询更新条:点击才刷新(不在用户浏览时抽换视图)
    if (state.listNotice) {
      inner +=
        '<div class="cgc-update-bar" data-testid="panel-list-update-bar">课程列表已更新 ' +
          '<button id="cgc-list-refresh" class="cgc-btn cgc-btn-secondary cgc-btn-mini" type="button">刷新查看</button>' +
        '</div>';
    }

    if (state.loading) {
      shell(inner + '<div class="cgc-card">加载中…</div>');
      bindListExtras();
      return;
    }
    if (state.error) {
      shell(inner + '<div class="cgc-card cgc-ev-err">加载失败:' + escapeHtml(state.error.message || "") + '</div>');
      bindListExtras();
      return;
    }
    if (state.courses.length === 0 && state.inFlight.length === 0) {
      shell(inner + '<div class="cgc-card cgc-empty">暂无在学课程。报名课程后,这里会显示课程列表。</div>');
      bindListExtras();
      return;
    }

    // S7:报名进行中(pending/payment_pending)——状态徽章,无学习入口
    if (state.inFlight.length > 0) {
      const inflightRows = state.inFlight.map(function (e) {
        const offering = e.offering || {};
        const ws = e.workspace || {};
        return (
          '<div class="cgc-course-row cgc-inflight-row" data-testid="panel-inflight">' +
            '<span class="task-name">' + escapeHtml(offering.title || "课程") + '</span>' +
            '<span class="cgc-inflight-meta">' + escapeHtml(ws.name || "") +
              '<span class="cgc-kind">' + escapeHtml(inFlightStatusBadge(e.status)) + '</span></span>' +
          '</div>'
        );
      }).join("");
      inner += '<p class="cgc-panel-sub">报名进行中</p>' +
        '<div class="cgc-card cgc-inflight-list">' + inflightRows + '</div>';
    }

    // S7:可学习课程(confirmed 报名;零学习记录的新报名同样出现)按 workspace 分组
    if (state.courses.length > 0) {
      const groups = {};
      state.courses.forEach(function (c) {
        const key = c.workspaceName || "未命名工作台";
        (groups[key] = groups[key] || []).push(c);
      });
      inner += Object.keys(groups).sort().map(function (name) {
        const rows = groups[name].map(function (c) {
          const title = c.title || ("课程 " + c.courseId.slice(0, 8) + "…");
          return (
            '<div class="cgc-course-row" data-testid="panel-course" data-course="' + escapeHtml(c.courseId) +
              '" data-ws="' + escapeHtml(c.workspaceId) + '">' +
              '<span class="task-name">' + escapeHtml(title) + '</span>' +
              '<span class="cgc-ev">开始学习 ›</span>' +
            '</div>'
          );
        }).join("");
        return '<div class="cgc-ws-group" data-testid="panel-course-group">' +
          '<div class="cgc-ws-group-name">' + escapeHtml(name) + '</div>' + rows + '</div>';
      }).join("");
    }

    shell(inner);
    bindListExtras();
    currentContainer.querySelectorAll("[data-course]").forEach(function (el) {
      el.addEventListener("click", function () { openCourse(el.getAttribute("data-course"), el.getAttribute("data-ws")); });
    });
  }

  // 报名进行中状态徽章(发现面板同款口径)
  function inFlightStatusBadge(status) {
    if (status === "pending") return "待审批";
    if (status === "payment_pending") return "待支付";
    return status || "";
  }

  function bindListExtras() {
    bindWorkspaceSwitch();
    const refresh = currentContainer.querySelector("#cgc-refresh");
    if (refresh) refresh.addEventListener("click", loadCourses);
    const bar = currentContainer.querySelector("#cgc-list-refresh");
    if (bar) bar.addEventListener("click", loadCourses);
    const bootRetry = currentContainer.querySelector("#cgc-boot-retry");
    if (bootRetry) bootRetry.addEventListener("click", boot);
  }

  // S8 掌握四态中文标签(旧 ref 语义)
  function masteryLabel(m) {
    if (m === "mastered") return "已掌握";
    if (m === "developing") return "学习中";
    if (m === "needs_review") return "待复习";
    return "未学";
  }

  function renderCourseDetail() {
    const sel = state.selected;
    const learning = sel.learning || {};
    const objectives = learning.objectives || [];
    const progress = learning.progress || {};
    const next = learning.next_action || null;

    // 编辑态:整体换编辑器视图(轮询已挂起)
    if (state.editing) {
      shell(renderEditor());
      bindEditor();
      return;
    }

    let inner =
      pickerRow() +
      '<div class="cgc-actions">' +
        '<button id="cgc-back" class="cgc-btn cgc-btn-secondary" type="button">← 返回课程</button>' +
        '<button id="cgc-detail-refresh" class="cgc-btn cgc-btn-secondary" type="button">刷新</button>' +
        '<span class="cgc-panel-sub">' + objectives.length + ' 个学习目标 · 已掌握 ' +
          escapeHtml(progress.mastered_required || 0) + '/' + escapeHtml(progress.total_required || 0) + '</span>' +
        (progress.complete
          ? '<span class="cgc-badge cgc-badge-done" data-testid="panel-complete">已结业</span>'
          : "") +
        (Number.isInteger(sel.content && sel.content.version)
          ? '<span class="cgc-badge" data-testid="panel-draft-version">草稿 v' + sel.content.version + '</span>'
          : "") +
        (state.canEdit
          ? '<button id="cgc-edit-toggle" class="cgc-btn cgc-btn-secondary" type="button" data-testid="panel-edit-toggle">编辑内容</button>'
          : "") +
      '</div>';

    // AE2:409 冲突横幅(本地编辑已丢弃,展示最新草稿)
    if (state.conflict) {
      inner += '<div class="cgc-banner cgc-banner-err" data-testid="panel-conflict">' + escapeHtml(state.conflict) + '</div>';
    }

    // R11 详情轮询更新条
    if (state.updateNotice) {
      inner +=
        '<div class="cgc-update-bar" data-testid="panel-update-bar">内容已更新 ' +
          '<button id="cgc-update-refresh" class="cgc-btn cgc-btn-secondary cgc-btn-mini" type="button">刷新查看</button>' +
        '</div>';
    }

    if (state.saveError) {
      inner += '<div class="cgc-card cgc-ev-err">保存失败:' + escapeHtml(state.saveError.message || "") + '</div>';
    }

    inner += prepSection();

    // stale 横幅:课程已发新版(run 绑旧版)——学习新版走 startLearning
    if (learning.stale_revision) {
      inner +=
        '<div class="cgc-banner" data-testid="panel-stale">' +
          '课程已发布新版本,你正在学旧版(进度保留) ' +
          '<button id="cgc-learn-new" class="cgc-btn cgc-btn-secondary cgc-btn-sm" type="button">学习新版</button>' +
        '</div>';
    }

    if (objectives.length === 0) {
      shell(inner + '<div class="cgc-card cgc-empty">该课程暂无学习目标(教研未完成或未发布)。</div>');
      bindDetailExtras(sel.courseId);
      bindStartLearning(sel.courseId);
      return;
    }

    // 当前任务卡(next_action):推荐徽章 + reason + CTA(会话指令含 objective_id)
    if (next && next.objective_id) {
      inner +=
        '<div class="cgc-card cgc-next-card" data-testid="panel-next-action">' +
          '<span class="cgc-badge cgc-badge-next">当前任务</span> ' +
          escapeHtml(next.reason || "") +
          '<button class="cgc-btn cgc-btn-primary cgc-btn-sm" type="button" data-cta="' +
            escapeHtml(next.objective_id) + '" data-testid="panel-cta">复制学习指令</button>' +
        '</div>';
    }

    // 进度条(mastered_required/total_required)
    const total = Number(progress.total_required) || 0;
    const done = Number(progress.mastered_required) || 0;
    const pct = total > 0 ? Math.round((done * 100) / total) : 0;
    inner +=
      '<div class="cgc-progress" data-testid="panel-progress">' +
        '<div class="cgc-progress-bar" style="width:' + pct + '%"></div>' +
      '</div>' +
      '<p class="cgc-panel-sub">必修掌握 ' + done + '/' + total + '</p>';

    const list = objectives.map(function (o) {
      return objectiveRow(o, next);
    }).join("");

    // S9:复习队列置顶(objective 地图之上;空队列不渲染)
    shell(inner + reviewQueueSection(learning) + '<div class="cgc-card cgc-obj-list">' + list + '</div>');

    bindDetailExtras(sel.courseId);
    bindStartLearning(sel.courseId);
    // S9:复习队列行点击 → 展开对应 objective 并滚动定位到地图行
    currentContainer.querySelectorAll("[data-review-obj]").forEach(function (el) {
      el.addEventListener("click", function () {
        const id = el.getAttribute("data-review-obj");
        state.currentObjective = id;
        render();
        const row = currentContainer.querySelector('[data-objective="' + id + '"]');
        if (row && row.scrollIntoView) row.scrollIntoView({ block: "nearest" });
      });
    });
    const reviewById = reviewEntryMap(learning);
    const cta = currentContainer.querySelector("[data-testid='panel-cta']");
    if (cta) {
      cta.addEventListener("click", function () {
        copySessionPrompt(cta.getAttribute("data-cta"), reviewById);
      });
    }
  }

  // S8 objective 行:四态徽章 / 锁与缺失先修 / 选修 chip / 尝试次数 /
  // 推荐徽章(next_action 命中)/ reason 行
  // S9:review_queue → objective id 查找表(行点击展开与 CTA 复习口吻判定用)
  function reviewEntryMap(learning) {
    const byObjective = {};
    ((learning && learning.review_queue) || []).forEach(function (entry) {
      if (entry && entry.objective_id != null) byObjective[String(entry.objective_id)] = entry;
    });
    return byObjective;
  }

  // S9 复习队列区(详情页置顶,objective 地图之上;队列空 → 不渲染):
  // 间隔重复 1/7/30 天里程碑按序消费——里程碑条目「第 N 天复习到期」;
  // needs_review 条目 = 复习失败待恢复掌握(立即到期,红色调区分,「待复习恢复」徽章;
  // 其 milestone_days 是重新达标后的下一里程碑,不作到期信息展示)。
  // 标题优先取 state 投影(stale run 报旧版 objectives 同样覆盖),缺则 id 兜底。
  function reviewQueueSection(learning) {
    const queue = (learning && learning.review_queue) || [];
    if (queue.length === 0) return "";
    const stateTitles = {};
    ((learning && learning.objectives) || []).forEach(function (o) {
      if (o) stateTitles[String(o.id)] = o.title;
    });
    const rows = queue.map(function (entry) {
      const id = String(entry.objective_id || "");
      const title = stateTitles[id] || id;
      const urgent = entry.needs_review === true;
      return (
        '<div class="cgc-review-row' + (urgent ? " cgc-review-urgent" : "") + '"' +
          ' data-testid="panel-review-row" data-review-obj="' + escapeHtml(id) + '">' +
          '<span class="task-name">' + escapeHtml(title) + '</span>' +
          '<span class="cgc-obj-meta">' +
            (urgent
              ? '<span class="cgc-badge cgc-obj-review" data-testid="panel-review-needs">待复习恢复</span>'
              : "") +
            (!urgent && Number.isInteger(entry.milestone_days)
              ? '<span class="cgc-review-due" data-testid="panel-review-due">第 ' + entry.milestone_days + ' 天复习到期</span>'
              : "") +
          '</span>' +
        '</div>'
      );
    }).join("");
    return (
      '<div class="cgc-card cgc-review-section" data-testid="panel-review-queue">' +
        '<div class="cgc-issue-head">待复习</div>' + rows +
      '</div>'
    );
  }

  function objectiveRow(o, next) {
    const locked = !!o.locked;
    const missing = o.missing_prereq_ids || [];
    const isNext = next && next.objective_id === o.id;
    return (
      '<div class="cgc-obj-row' + (locked ? " cgc-obj-locked" : "") + '"' +
        ' data-testid="panel-obj-row" data-objective="' + escapeHtml(o.id) + '">' +
        '<span class="cgc-badge cgc-obj-' + escapeHtml(o.mastery) + '" data-testid="panel-obj-badge">' +
          escapeHtml(masteryLabel(o.mastery)) + '</span>' +
        (isNext ? '<span class="cgc-badge cgc-badge-next">推荐</span>' : "") +
        '<span class="task-name">' + escapeHtml(o.title || o.id) + '</span>' +
        (o.required ? "" : '<span class="cgc-badge cgc-obj-elective">选修</span>') +
        '<span class="cgc-obj-meta">' +
          (o.attempt_count > 0 ? '<span>尝试 ' + escapeHtml(o.attempt_count) + ' 次</span>' : "") +
          (locked
            ? '<span class="cgc-obj-missing" data-testid="panel-obj-locked">🔒 需先修:' +
                escapeHtml((missing || []).map(function (m) { return m.title || m.id; }).join("、")) + '</span>'
            : "") +
        '</span>' +
        (isNext && next && next.reason
          ? '<div class="cgc-obj-reason">' + escapeHtml(next.reason) + '</div>'
          : "") +
      '</div>'
    );
  }

  // S8 学习新版(POST /learning/start):新版 key 自动开新 run,重载详情
  function bindStartLearning(courseId) {
    const btn = currentContainer.querySelector("#cgc-learn-new");
    if (btn) {
      btn.addEventListener("click", async function () {
        try {
          await apiPost("/learning/start", { workspace_id: state.workspaceId, course_id: courseId });
          await openCourse(courseId, state.workspaceId);
        } catch (e) {
          state.error = e;
          render();
        }
      });
    }
  }

  // S5 教研流程区(仅 canEdit 且课程有 prep run 时渲染):prep_state badge +
  // 生效策略 + 结构门禁违规清单 + 最新质量报告。全部经 escapeHtml 转义。
  function prepSection() {
    const prep = state.prep;
    if (!state.canEdit || !prep) return "";

    const policy = prep.policy || {};
    const violations = Array.isArray(prep.gate_violations) ? prep.gate_violations : [];
    const report = prep.latest_quality_report || null;
    const tutor = prep.tutor || null;

    let html =
      '<div class="cgc-card cgc-prep" data-testid="panel-prep">' +
        '<div class="cgc-prep-head">' +
          '<b>教研流程</b>' +
          '<span class="cgc-badge" data-testid="panel-prep-state">' + escapeHtml(prep.prep_state || "") + '</span>' +
          (tutor
            ? '<span class="cgc-panel-sub">tutor:' + escapeHtml(tutor.display_name || tutor.user_id || "") + '</span>'
            : "") +
          '<span class="cgc-panel-sub">阈值 ' + escapeHtml(policy.quality_threshold) +
            (policy.review_required ? ' · 需人工审核' : ' · 达标自动发布') + '</span>' +
        '</div>';

    if (violations.length > 0) {
      html +=
        '<ul class="cgc-prep-violations" data-testid="panel-prep-violations">' +
          violations.map(function (v) { return '<li>' + escapeHtml(v) + '</li>'; }).join("") +
        '</ul>';
    }

    if (report) {
      html +=
        '<div class="cgc-prep-quality" data-testid="panel-prep-quality">' +
          '质量报告 ' + escapeHtml(report.score) + '/100 · ' + escapeHtml(report.outcome || "") +
          (report.summary ? '<div class="cgc-panel-sub">' + escapeHtml(report.summary) + '</div>' : "") +
        '</div>';
    }

    return html + '</div>';
  }

  // 详情页公共绑定:返回 + 手动刷新 + S4 编辑入口 + R11 轮询更新条
  function bindDetailExtras(courseId) {
    bindWorkspaceSwitch();
    const back = currentContainer.querySelector("#cgc-back");
    if (back) back.addEventListener("click", function () { state.selected = null; state.currentIssue = null; state.conflict = null; state.prep = null; render(); });
    const refresh = currentContainer.querySelector("#cgc-detail-refresh");
    if (refresh) refresh.addEventListener("click", function () { openCourse(courseId); });
    const toggle = currentContainer.querySelector("#cgc-edit-toggle");
    if (toggle) toggle.addEventListener("click", enterEdit);
    const upd = currentContainer.querySelector("#cgc-update-refresh");
    if (upd) upd.addEventListener("click", function () { openCourse(courseId); });
  }

  // ---- S4 草稿编辑(教研侧;tutor|owner|admin;v1 schema:goals + issues/checklist) ----
  // 编辑基准 = get_course_content 草稿(含 version 与未知键);进入编辑时才拉取。
  async function enterEdit() {
    if (!state.selected || state.loading) return;
    const courseId = state.selected.courseId;
    state.loading = true;
    state.saveError = null;
    render();
    try {
      const res = await apiGet("/courses/" + encodeURIComponent(courseId) + "/content");
      const content = res.result || {};
      state.draftContent = content;
      state.draft = {
        goals: Array.isArray(content.goals) ? content.goals.slice() : [],
        issues: JSON.parse(JSON.stringify(Array.isArray(content.issues) ? content.issues : []))
      };
      state.editing = true;
      state.conflict = null;
      state.updateNotice = false;
    } catch (e) {
      state.error = e;
    } finally {
      state.loading = false;
      render();
    }
  }

  function exitEdit() {
    state.editing = false;
    state.draft = null;
    state.draftContent = null;
    state.saveError = null;
    render();
  }

  function trim(s) { return String(s == null ? "" : s).trim(); }

  // 材料:每行「标题 | 链接」;无 | 整行当标题
  function parseMaterials(text) {
    return text.split("\n").map(trim).filter(Boolean).map(function (line) {
      const i = line.indexOf("|");
      return i < 0
        ? { title: line, ref: "" }
        : { title: trim(line.slice(0, i)), ref: trim(line.slice(i + 1)) };
    });
  }

  // checklist:每行「id | 文本」;无 | 自动补 c<行号> 作 id
  function parseChecklist(text) {
    return text.split("\n").map(trim).filter(Boolean).map(function (line, n) {
      const i = line.indexOf("|");
      return i < 0
        ? { id: "c" + (n + 1), text: line }
        : { id: trim(line.slice(0, i)), text: trim(line.slice(i + 1)) };
    });
  }

  // 编辑器 DOM → draft(结构性动作与保存前调用,re-render 不丢输入)。
  // 只写编辑器暴露的已知键——issue/story 上的未知键随深拷贝对象原样保留
  // (无损往返:未来新增字段不被编辑器丢弃)。
  function collectEditor() {
    if (!state.draft || !currentContainer) return;
    const goalsEl = currentContainer.querySelector("#cgc-edit-goals");
    if (goalsEl) state.draft.goals = goalsEl.value.split("\n").map(trim).filter(Boolean);
    currentContainer.querySelectorAll("[data-edit-issue]").forEach(function (el) {
      const issue = state.draft.issues[Number(el.getAttribute("data-edit-issue"))];
      if (!issue) return;
      const story = issue.story = issue.story || {};
      issue.kind = el.querySelector("[data-f='kind']").value;
      issue.title = trim(el.querySelector("[data-f='title']").value);
      story.as_a = trim(el.querySelector("[data-f='as_a']").value);
      story.given = el.querySelector("[data-f='given']").value.split("/").map(trim).filter(Boolean);
      story.goal = trim(el.querySelector("[data-f='goal']").value);
      story.materials = parseMaterials(el.querySelector("[data-f='materials']").value);
      story.checklist = parseChecklist(el.querySelector("[data-f='checklist']").value);
    });
  }

  async function saveDraft() {
    if (!state.selected || !state.draft || state.saving) return;
    const courseId = state.selected.courseId;
    collectEditor();
    // 保留 content 上未编辑的键(如 course_title),剥离 version(并发控制走顶层 base_version)
    const content = Object.assign({}, state.draftContent, {
      goals: state.draft.goals,
      issues: state.draft.issues
    });
    delete content.version;
    state.saving = true;
    state.saveError = null;
    render();
    try {
      await apiPost("/courses/" + encodeURIComponent(courseId) + "/content", {
        workspace_id: state.workspaceId,
        content: content,
        base_version: draftVersion()
      });
      // 成功:退出编辑态并重载(只读视图展示最新草稿)
      state.editing = false;
      state.draft = null;
      state.draftContent = null;
      await openCourse(courseId);
    } catch (e) {
      if (e && e.status === 409) {
        // AE2:版本冲突——丢弃本地编辑(不做 diff),回只读视图 + 红色横幅
        state.editing = false;
        state.draft = null;
        state.draftContent = null;
        state.conflict = "内容已被他人更新到更新版本,本地编辑已丢弃;请重新进入编辑,基于最新草稿修改";
        await openCourse(courseId);
      } else {
        state.saveError = e;
      }
    } finally {
      state.saving = false;
      render();
    }
  }

  function renderEditor() {
    const draft = state.draft || { goals: [], issues: [] };
    const goalRows = (draft.goals || []).join("\n");

    const issueCards = draft.issues.map(function (issue, idx) {
      const story = issue.story || {};
      const mats = (Array.isArray(story.materials) ? story.materials : []).map(function (m) {
        return (m.title || "") + (m.ref ? " | " + m.ref : "");
      }).join("\n");
      const checks = (Array.isArray(story.checklist) ? story.checklist : []).map(function (c) {
        return (c.id || "") + " | " + (c.text || "");
      }).join("\n");
      return (
        '<div class="cgc-card cgc-issue-edit" data-edit-issue="' + idx + '" data-testid="panel-issue-edit">' +
          '<div class="cgc-edit-row cgc-edit-head">' +
            '<span class="cgc-issue-key">id:' + escapeHtml(issue.id) + '</span>' +
            '<button class="cgc-btn cgc-btn-secondary cgc-btn-mini" type="button" data-remove-issue="' + idx + '">删除</button>' +
          '</div>' +
          '<div class="cgc-edit-row"><label>kind</label>' +
            '<select data-f="kind">' +
              '<option value="handwork"' + (issue.kind === "handwork" ? " selected" : "") + '>handwork(动手型)</option>' +
              '<option value="thoughtwork"' + (issue.kind === "thoughtwork" ? " selected" : "") + '>thoughtwork(知识型)</option>' +
            '</select></div>' +
          '<div class="cgc-edit-row"><label>标题</label>' +
            '<input data-f="title" type="text" value="' + escapeHtml(issue.title || "") + '"></div>' +
          '<div class="cgc-edit-row"><label>as_a(目标学员画像)</label>' +
            '<input data-f="as_a" type="text" value="' + escapeHtml(story.as_a || "") + '"></div>' +
          '<div class="cgc-edit-row"><label>given(先修状态,/ 分隔)</label>' +
            '<input data-f="given" type="text" value="' + escapeHtml((Array.isArray(story.given) ? story.given : []).join(" / ")) + '"></div>' +
          '<div class="cgc-edit-row"><label>goal(完成后能独立做到什么)</label>' +
            '<input data-f="goal" type="text" value="' + escapeHtml(story.goal || "") + '"></div>' +
          '<div class="cgc-edit-row"><label>materials(每行一条,格式:标题 | 链接)</label>' +
            '<textarea data-f="materials" rows="2">' + escapeHtml(mats) + '</textarea></div>' +
          '<div class="cgc-edit-row"><label>checklist(每行一条,格式:id | 文本)</label>' +
            '<textarea data-f="checklist" rows="3">' + escapeHtml(checks) + '</textarea></div>' +
        '</div>'
      );
    }).join("");

    return (
      '<div class="cgc-actions">' +
        '<span class="cgc-badge" data-testid="panel-draft-version">草稿 v' + draftVersion() + '</span>' +
        '<span class="cgc-panel-sub">编辑课程草稿(保存经 save_course_content,base_version 乐观并发)</span>' +
      '</div>' +
      '<div class="cgc-card" data-testid="panel-editor">' +
        '<div class="cgc-edit-row"><label>课程目标 goals(每行一条)</label>' +
          '<textarea id="cgc-edit-goals" rows="3">' + escapeHtml(goalRows) + '</textarea></div>' +
        issueCards +
        '<div class="cgc-edit-row">' +
          '<button id="cgc-add-issue" class="cgc-btn cgc-btn-secondary" type="button" data-testid="panel-add-issue">+ 添加 issue</button>' +
        '</div>' +
        (state.saveError
          ? '<div class="cgc-ev-err">保存失败:' + escapeHtml(state.saveError.message || "") + '</div>'
          : "") +
        '<div class="cgc-actions">' +
          '<button id="cgc-save" class="cgc-btn cgc-btn-primary" type="button" data-testid="panel-save"' +
            (state.saving ? " disabled" : "") + '>' + (state.saving ? "保存中…" : "保存草稿") + '</button>' +
          '<button id="cgc-cancel-edit" class="cgc-btn cgc-btn-secondary" type="button">取消</button>' +
        '</div>' +
      '</div>'
    );
  }

  function bindEditor() {
    const save = currentContainer.querySelector("#cgc-save");
    if (save) save.addEventListener("click", saveDraft);
    const cancel = currentContainer.querySelector("#cgc-cancel-edit");
    if (cancel) cancel.addEventListener("click", exitEdit);
    const add = currentContainer.querySelector("#cgc-add-issue");
    if (add) {
      add.addEventListener("click", function () {
        collectEditor();
        state.draft.issues.push({
          id: "issue-" + Date.now(),
          kind: "handwork",
          title: "",
          story: { as_a: "", given: [], goal: "", materials: [], checklist: [] }
        });
        render();
      });
    }
    currentContainer.querySelectorAll("[data-remove-issue]").forEach(function (el) {
      el.addEventListener("click", function () {
        collectEditor();
        state.draft.issues.splice(Number(el.getAttribute("data-remove-issue")), 1);
        render();
      });
    });
  }

  // ---- 样式(面板自包含) ----
  function injectStyles() {
    if (document.getElementById("cgc-course-styles")) return;
    const css = document.createElement("style");
    css.id = "cgc-course-styles";
    css.textContent =
      ".cgc-course-panel .cgc-input{width:70%;margin-right:8px;padding:6px 10px;border:1px solid var(--border,#444);border-radius:8px;background:transparent;color:inherit;font-size:13px}" +
      ".cgc-course-list{margin-top:10px}" +
      ".cgc-course-row{display:flex;justify-content:space-between;align-items:center;padding:8px 10px;border-radius:8px;cursor:pointer}" +
      ".cgc-course-row:hover{background:rgba(127,127,127,.12)}" +
      ".cgc-obj-row{display:flex;flex-wrap:wrap;gap:8px;align-items:center;padding:8px 10px;border-radius:8px}" +
      ".cgc-obj-row:hover{background:rgba(127,127,127,.12)}" +
      ".cgc-obj-locked .task-name{color:#6b7280}" +
      ".cgc-obj-unassessed{color:#9ca3af;border-color:#9ca3af}" +
      ".cgc-obj-developing{color:#fbbf24;border-color:#fbbf24}" +
      ".cgc-obj-mastered{color:#34d399;border-color:#34d399}" +
      ".cgc-obj-needs_review{color:#f97316;border-color:#f97316}" +
      ".cgc-obj-elective{color:#a78bfa;border-color:#a78bfa}" +
      ".cgc-obj-review{color:#f87171;border-color:#f87171}" +
      ".cgc-badge-next{color:#6366f1;border-color:#6366f1}" +
      ".cgc-obj-meta{display:flex;gap:8px;font-size:12px;color:#9ca3af}" +
      ".cgc-obj-missing{color:#f97316}" +
      ".cgc-obj-reason{width:100%;font-size:12px;color:#9ca3af;margin:2px 0 0}" +
      ".cgc-next-card{display:flex;gap:8px;align-items:center;flex-wrap:wrap}" +
      ".cgc-review-section{margin-top:10px}" +
      ".cgc-review-row{display:flex;justify-content:space-between;align-items:center;gap:8px;padding:6px 10px;border-radius:8px;cursor:pointer;box-shadow:inset 2px 0 0 #fbbf24}" +
      ".cgc-review-row:hover{background:rgba(127,127,127,.12)}" +
      ".cgc-review-row.cgc-review-urgent{box-shadow:inset 2px 0 0 #f87171}" +
      ".cgc-review-due{font-size:11px;color:#fbbf24;white-space:nowrap}" +
      ".cgc-progress{height:6px;border-radius:3px;background:rgba(127,127,127,.25);overflow:hidden;margin:6px 0}" +
      ".cgc-progress-bar{height:100%;background:#34d399}" +
      ".cgc-badge-done{color:#34d399;border-color:#34d399}" +
      ".cgc-ws-group{margin-bottom:6px}" +
      ".cgc-ws-group-name{font-size:11px;color:#9ca3af;margin:6px 4px 2px}" +
      ".cgc-inflight-row{cursor:default}" +
      ".cgc-inflight-meta{display:flex;gap:8px;align-items:center;font-size:12px;color:#9ca3af}" +
      ".cgc-kind{border:1px solid var(--border,#444);border-radius:999px;padding:0 8px;font-size:11px}" +
      ".cgc-issue-list{margin-top:10px}" +
      ".cgc-issue-row{display:flex;align-items:center;gap:8px;padding:7px 10px;border-radius:8px;cursor:pointer}" +
      ".cgc-issue-row:hover,.cgc-issue-row.cgc-issue-active{background:rgba(127,127,127,.12)}" +
      ".cgc-st{width:18px;text-align:center}" +
      ".cgc-st-done{color:#34d399}.cgc-st-progress{color:#fbbf24}.cgc-st-todo{color:#9ca3af}" +
      ".cgc-issue-key{font-family:ui-monospace,monospace;font-size:11px;color:#9ca3af}" +
      ".cgc-kind{margin-left:auto;font-size:11px;border:1px solid var(--border,#444);border-radius:999px;padding:1px 8px;color:#9ca3af}" +
      ".cgc-issue-card{margin-top:10px}" +
      ".cgc-issue-title{font-size:14px;font-weight:600;display:flex;align-items:center;gap:8px}" +
      ".cgc-goal{font-size:12px;color:#9ca3af;margin:4px 0}" +
      ".cgc-checklist{list-style:none;padding:0;margin:8px 0}" +
      ".cgc-check{display:flex;gap:8px;padding:4px 0;font-size:13px}" +
      ".cgc-check-done{color:var(--text,#eee)}" +
      ".cgc-ev-hint{font-size:11px;color:#9ca3af;margin-top:6px}" +
      ".cgc-btn-primary{background:#6366f1;color:#fff;border:none}" +
      ".cgc-ws-row{margin-bottom:8px}" +
      ".cgc-select{padding:4px 8px;border:1px solid var(--border,#444);border-radius:6px;background:transparent;color:inherit;font-size:13px}" +
      ".cgc-badge{font-size:11px;border:1px solid var(--border,#444);border-radius:999px;padding:1px 8px;color:#9ca3af}" +
      ".cgc-btn-mini{padding:2px 8px;font-size:12px}" +
      ".cgc-banner-err{border-color:rgba(192,57,43,.5);background:rgba(192,57,43,.08);color:#c0392b}" +
      ".cgc-update-bar{display:flex;gap:8px;align-items:center;font-size:12px;color:#9ca3af;border:1px dashed var(--border,#444);border-radius:8px;padding:6px 10px;margin:8px 0}" +
      ".cgc-edit-row{display:flex;flex-direction:column;gap:4px;margin-bottom:8px;font-size:12px}" +
      ".cgc-edit-row label{opacity:.65}" +
      ".cgc-edit-row input,.cgc-edit-row textarea,.cgc-edit-row select{padding:6px 10px;border:1px solid var(--border,#444);border-radius:8px;background:transparent;color:inherit;font-size:13px;font-family:inherit}" +
      ".cgc-edit-head{flex-direction:row;justify-content:space-between;align-items:center}" +
      ".cgc-issue-edit{margin-top:10px}" +
      ".cgc-prep{margin-top:10px}" +
      ".cgc-prep-head{display:flex;align-items:center;gap:8px;font-size:13px}" +
      ".cgc-prep-violations{margin:6px 0 0;padding-left:18px;font-size:12px;color:#c0392b}" +
      ".cgc-prep-quality{margin-top:6px;font-size:12px}";
    document.head.appendChild(css);
  }

  injectStyles();
  Clacky.ext.ui.registerWorkspace(WS_ID, { title: "CGC 课程学习", render: render });
})();
