// CGC-2046 教研工作台(cgc-2046-curriculum;S2 教研拆出)。
//
// 定位:course 面板收敛为学习中心后,教研编辑(草稿编辑器 + 乐观并发 +
// 教研流程状态区)独立成面板。入口:hub 目录卡「教研工作台」(仅 tutor
// 可见);本面板自身也做 canEdit 门控(双保险)。
//
// 能力(自旧 course 面板原样迁移):
//   - 课程选择(本人 confirmed 课程报名;编辑走 /content 全量草稿)
//   - S4 草稿编辑器:goals/issues 表单化,materials/checklist 解析预览,
//     base_version 乐观并发,409 冲突 UX(丢弃本地 + 横幅 + 重载)
//   - 未保存离开保护:取消/切换时 confirm(防误触丢稿)
//   - S5 教研流程状态区:prep_state / 生效策略 / 门禁违规 / 质量报告
//
// 安全红线:只渲染 loopback 透传数据,服务端字符串一律 escapeHtml;
// 写端点(Content-Type + CSRF,403-on-CSRF 自愈)。

(() => {
  "use strict";
  if (!window.Clacky || !Clacky.ext || Clacky.ext.pure) return;

  const API = "/api/ext/cgc-2046";
  const WS_ID = "cgc-2046-curriculum";
  const STORE_KEY = "cgc2046.coursePanel.workspaceId";
  let csrfToken = "";
  let currentContainer = null;

  const state = {
    bootStarted: false, loadingBoot: false, bootError: null,
    workspaces: [], workspaceId: "", canEdit: false,
    courses: [], selectedCourseId: "",
    loading: false, error: null,
    content: null, prep: null,
    editing: false, draft: null, draftContent: null,
    saving: false, saveError: null, conflict: null
  };

  function escapeHtml(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  // 教研权限按**课程归属工作台**判定(跨台角色:uat 台 learner + 2046 台 tutor
  // 时,编辑 2046 的课是合法的);无权限视图仅在用户任何台都没有教研角色时出现
  const EDIT_ROLES = ["tutor"];

  function rolesOf(workspaceId) {
    const ws = state.workspaces.find(function (w) { return w.workspace_id === workspaceId; });
    return (ws && ws.roles) || [];
  }

  function canEditCourse(courseId) {
    const course = state.courses.find(function (c) { return c.courseId === courseId; });
    const wsId = (course && course.workspaceId) || state.workspaceId;
    const roles = rolesOf(wsId);
    return EDIT_ROLES.some(function (r) { return roles.indexOf(r) >= 0; });
  }

  function hasAnyEditRole() {
    return state.workspaces.some(function (w) {
      const roles = Array.isArray(w.roles) ? w.roles : [];
      return EDIT_ROLES.some(function (r) { return roles.indexOf(r) >= 0; });
    });
  }

  async function rawGet(path) {
    const res = await fetch(API + path, { headers: { Accept: "application/json" } });
    const body = await res.json().catch(function () { return {}; });
    if (!res.ok) throw Object.assign(new Error(body.error || ("HTTP " + res.status)), { body, status: res.status });
    return body;
  }

  // 作用域 = 所选课程归属工作台(跨台教研;boot 台仅作无课程上下文时兜底)
  function scopeOf(courseId) {
    const course = state.courses.find(function (c) { return c.courseId === (courseId || state.selectedCourseId); });
    return (course && course.workspaceId) || state.workspaceId;
  }

  async function apiGet(path) {
    const sep = path.indexOf("?") >= 0 ? "&" : "?";
    return rawGet(path + sep + "workspace_id=" + encodeURIComponent(scopeOf()));
  }

  function postHeaders() {
    const headers = { "Content-Type": "application/json", Accept: "application/json" };
    if (csrfToken) headers["X-CGC-CSRF-Token"] = csrfToken;
    return headers;
  }

  async function ensureCsrf() {
    if (csrfToken) return;
    try {
      const res = await fetch(API + "/status", { headers: { Accept: "application/json" } });
      const body = await res.json().catch(function () { return {}; });
      if (res.ok && body.csrf_token) csrfToken = String(body.csrf_token);
    } catch (e) { /* 静默 */ }
  }

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

  // ---- 草稿版本:进入编辑时拉取的 get_course_content 顶层 version;缺失按 0 ----
  function draftVersion() {
    const v = state.draftContent && state.draftContent.version;
    return Number.isInteger(v) ? v : 0;
  }

  // ---- boot / 数据 ----
  async function boot() {
    state.loadingBoot = true;
    state.bootError = null;
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
    } catch (e) {
      state.workspaces = [];
      state.bootError = e;
    } finally {
      state.loadingBoot = false;
      render();
    }
    loadCourses();
  }

  // 焦点回归重拉角色快照;编辑态只更新 state.workspaces 不重渲染——
  // renderEditor 会用 state.draft 重建 DOM,未 collectEditor 的输入会丢
  async function reloadWorkspaces() {
    try {
      const payload = await rawGet("/me/workspaces");
      const result = payload.result || {};
      const next = Array.isArray(result.workspaces) ? result.workspaces : [];
      if (next.length > 0) state.workspaces = next;
    } catch (e) { /* 静默 */ }
    if (!state.editing && currentContainer) render();
  }

  // ---- 和教研助手共创(P1:创建 cgc-tutor 会话 + 注入教研指令) ----
  function coCreateWithTutor() {
    const course = state.courses.find(function (c) { return c.courseId === state.selectedCourseId; }) || {};
    const title = course.title || "当前课程";
    const version = Number.isInteger(state.content && state.content.version) ? state.content.version : "无";
    const instruction = [
      "请作为教研助手与我共创课程《" + title + "》。",
      "(course_id: " + state.selectedCourseId + ", workspace_id: " + scopeOf() + ", 当前草稿版本: " + version + ")",
      "请先 get_course_content 与 get_prep_status 读取现状,然后向我确认本次共创的目标",
      "(从课程定位/goals 开始渐进推进);每次修改经 save_course_content 保存并汇报变更摘要。",
      "教研侧边栏会实时显示草稿,我会在对话里给你方向与反馈。"
    ].join("\n");
    coCreateWithTutorInstruction(instruction);
  }

  function coCreateWithTutorInstruction(instruction) {
    fetch("/api/sessions", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name: "教研共创", agent_profile: "cgc-tutor", source: "manual" })
    })
      .then(function (res) { return res.json().catch(function () { return {}; }); })
      .then(function (payload) {
        const session = payload.session;
        if (!session || !session.id) throw new Error("没有创建可用的教研会话");
        if (Clacky.Sessions && typeof Clacky.Sessions.add === "function") {
          Clacky.Sessions.add(session);
          if (typeof Clacky.Sessions.renderList === "function") Clacky.Sessions.renderList();
          Clacky.Sessions.select(session.id);
        } else if (Clacky.Router && typeof Clacky.Router.navigate === "function") {
          Clacky.Router.navigate("session", { id: session.id });
        }
        setTimeout(function () { injectIntoComposer(instruction); }, 1500);
      })
      .catch(function (e) {
        window.alert("打开教研会话失败：" + String(e.message || e));
      });
  }

  function injectIntoComposer(text) {
    const input = document.getElementById("user-input");
    const send = document.getElementById("btn-send");
    if (!input || !send) {
      window.prompt("复制以下指令到教研会话开始共创:", text);
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

  // ---- prep 流程条(P1:状态展示 + 推进动作走会话注入;面板=状态,会话=执行) ----
  const PREP_STATES = ["draft", "authoring", "quality_check", "review", "published"];
  const PREP_LABELS = { draft: "草稿", authoring: "编写中", quality_check: "质检", review: "审核", published: "已发布" };
  const PREP_ACTIONS = {
    draft: {
      label: "开始编写(认领教研)",
      hint: "教研流程刚启动——点右侧按钮,和教研助手共创内容;或用「编辑内容」手动编写",
      instruction: "请 claim_prep_authoring 认领本课程教研,然后与我确认课程定位并开始共创内容。"
    },
    authoring: {
      label: "提交质量检查",
      hint: "内容编写中——完成后点右侧按钮提交质检;质检会检查结构完整性(缺 rubric 等会被拦下)",
      instruction: "内容已就绪,请检查结构门禁后 submit_prep_for_check 提交质量检查。"
    },
    quality_check: {
      label: "提交质量报告",
      hint: "等待质量自评——教研助手会诚实评分;达标进审核,不达标自动回编写",
      instruction: "请按结构完整度如实自评,submit_prep_quality_report 提交质量报告(诚实评分,不美化)。"
    },
    review: {
      label: "审核发布 / 驳回",
      hint: "质量达标——审阅内容后点右侧按钮发布;不满意可驳回回编",
      instruction: "我已审阅草稿。等待我的明确指示后 approve_prep 通过发布,或 request_changes_prep 驳回;在此之前不要执行发布。"
    },
    published: {
      label: null,
      hint: "已发布——学员可报名学习;如需修改内容,教研流程会自动开启新一轮",
      instruction: null
    }
  };

  // 课程状态徽标(区别于教研周期状态):发布后新一轮 prep 从 draft 重新计,
  // 只看 stepper 会误以为课程未发布——open=学员已可报名
  function courseStatusBadge(status) {
    const map = {
      open: { label: "已发布 · 报名中", cls: "is-open" },
      draft: { label: "未发布", cls: "is-draft" },
      closed: { label: "已关闭报名", cls: "is-draft" },
      cancelled: { label: "已取消", cls: "is-cancelled" }
    };
    const m = map[String(status || "")];
    if (!m) return "";
    return '<span class="cgt-course-status ' + m.cls + '" data-testid="course-status">' + m.label + '</span>';
  }

  function prepStepper() {
    const current = (state.prep || {}).prep_state || "draft";
    const idx = PREP_STATES.indexOf(current);
    const dots = PREP_STATES.map(function (s, i) {
      const cls = i < idx ? " cgt-st-done" : (i === idx ? " cgt-st-current" : "");
      return '<span class="cgt-st' + cls + '">' + escapeHtml(PREP_LABELS[s] || s) + '</span>';
    }).join('<span class="cgt-st-sep"></span>');
    const action = PREP_ACTIONS[current];
    const hint = action && action.hint
      ? '<div class="cgt-stepper-hint">' + escapeHtml(action.hint) + '</div>'
      : "";
    const btn = (action && action.label && canEditCourse(state.selectedCourseId))
      ? ' <button id="cgt-prep-action" class="cgch-btn cgch-btn-ghost cgch-btn-sm" type="button"' +
            ' data-testid="prep-action">' + escapeHtml(action.label) + '</button>'
      : "";
    return '<div class="cgt-stepper" data-testid="prep-stepper">' + dots + btn + hint + '</div>';
  }

  function bindPrepAction() {
    const btn = currentContainer && currentContainer.querySelector("#cgt-prep-action");
    if (!btn) return;
    btn.addEventListener("click", function () {
      const current = (state.prep || {}).prep_state || "draft";
      const action = PREP_ACTIONS[current];
      if (!action) return;
      const course = state.courses.find(function (c) { return c.courseId === state.selectedCourseId; }) || {};
      const instruction = "课程《" + (course.title || "") + "》(course_id: " + state.selectedCourseId +
        ", workspace_id: " + scopeOf() + ")。" + action.instruction;
      coCreateWithTutorInstruction(instruction);
    });
  }

  // 课程发现:list_workspace_courses(本台全部课程,含 draft——#366),
  // 不再依赖 get_my_enrollments(tutor 有权编辑却不必然报名)
  async function loadCourses() {
    state.loading = true;
    state.error = null;
    render();
    try {
      // 对每个有 tutor 角色的工作台拉全部课程
      const tutorWsIds = state.workspaces
        .filter(function (w) {
          return (Array.isArray(w.roles) ? w.roles : []).indexOf("tutor") >= 0;
        })
        .map(function (w) { return String(w.workspace_id); });
      const allCourses = [];
      for (const wsId of tutorWsIds) {
        try {
          const payload = await rawGet("/workspace/courses?workspace_id=" + encodeURIComponent(wsId));
          const courses = (payload.result && payload.result.courses) || [];
          courses.forEach(function (c) {
            allCourses.push({
              courseId: String(c.course_id || ""),
              title: String(c.title || ""),
              status: String(c.status || ""),
              workspaceId: wsId
            });
          });
        } catch (e) { /* 单台失败不阻断 */ }
      }
      state.courses = allCourses.filter(function (c) { return c.courseId !== ""; });
      const stored = localStorage.getItem("cgc2046.curriculum.courseId") || "";
      const found = state.courses.find(function (c) { return c.courseId === stored; });
      state.selectedCourseId = (found || state.courses[0] || {}).courseId || "";
      if (state.selectedCourseId) localStorage.setItem("cgc2046.curriculum.courseId", state.selectedCourseId);
      state.loading = false;
      if (state.selectedCourseId) await loadTeachData(); else render();
    } catch (e) {
      state.error = e;
      state.loading = false;
      render();
    }
  }

  async function loadTeachData() {
    state.loading = true;
    state.error = null;
    state.prep = null;
    render();
    try {
      const [contentRes] = await Promise.all([
        apiGet("/courses/" + encodeURIComponent(state.selectedCourseId) + "/content"),
        apiGet("/courses/" + encodeURIComponent(state.selectedCourseId) + "/prep").then(function (r) {
          state.prep = r.result || null;
          // Promise.all 对新课会在 content reject 时提前渲染(loading=false),
          // prep 落地晚于那次渲染——补一次,否则 stepper 永远卡在默认 draft
          if (!state.loading) render();
        }).catch(function () { state.prep = null; })
      ]);
      state.content = contentRes.result || {};
      state.error = null;
    } catch (e) {
      if (/no course content saved/.test(String(e.message || e))) {
        // 新课从未保存过草稿(curriculum pending)——教研初始态,不是错误:
        // 空 goals/issues + version 0(首存 base_version)
        state.content = { goals: [], issues: [], version: 0 };
        state.error = null;
      } else {
        state.error = e;
        state.content = null;
      }
    } finally {
      state.loading = false;
      render();
    }
  }

  // ---- 渲染 ----
  function render() {
    if (!currentContainer) return;
    if (!state.loadingBoot && state.workspaces.length > 0 && !hasAnyEditRole()) {
      currentContainer.innerHTML =
        '<div class="cgt-page"><div class="cgt-main"><div class="cgc-card" data-testid="prep-no-permission">' +
        '<b>教研工作台仅对 tutor 开放。</b><br>' +
        '<span class="cgch-empty">当前 Workspace 角色不包含教研权限。_RBAC 提示:网站为唯一权限权威。</span></div></div></div>';
      return;
    }
    let html =
      '<div class="cgt-page">' +
        '<aside class="cgt-side">' +
          '<div class="cgt-side-title">教研工作台</div>' +
          '<select id="cgt-course" class="cgt-select" data-testid="prep-course-select">' +
            state.courses.map(function (c) {
              const sel = c.courseId === state.selectedCourseId ? " selected" : "";
              return '<option value="' + escapeHtml(c.courseId) + '"' + sel + '>' + escapeHtml(c.title || c.courseId) + '</option>';
            }).join("") +
          '</select>' +
          '<div class="cgch-empty">选择课程后可编辑草稿并查看教研流程。</div>' +
        '</aside>' +
        '<main class="cgt-main" id="cgt-main"></main>' +
      '</div>';
    currentContainer.innerHTML = html;
    const sel = currentContainer.querySelector("#cgt-course");
    if (sel) sel.addEventListener("change", function () {
      state.selectedCourseId = sel.value;
      localStorage.setItem("cgc2046.curriculum.courseId", sel.value);
      state.editing = false;
      loadTeachData();
    });
    renderMain();
  }

  function renderMain() {
    const main = currentContainer.querySelector("#cgt-main");
    if (!main) return;
    if (state.loadingBoot || state.loading) { main.innerHTML = '<div class="cgc-card cgch-empty">加载中…</div>'; return; }
    if (state.editing) { main.innerHTML = renderEditor(); bindEditor(); return; }
    if (state.error) {
      main.innerHTML = '<div class="cgc-card cgc-ev-err" data-testid="prep-error">加载失败:' + escapeHtml(state.error.message || "") +
        ' <button id="cgt-retry" class="cgch-btn cgch-btn-ghost cgch-btn-sm" type="button">重试</button></div>';
      const retry = main.querySelector("#cgt-retry");
      if (retry) retry.addEventListener("click", loadTeachData);
      return;
    }
    if (!state.content) { main.innerHTML = '<div class="cgc-card cgch-empty">暂无课程。</div>'; return; }

    const isNewDraft = state.content.version === 0 && !(state.content.goals || []).length && !(state.content.issues || []).length;
    const selCourse = state.courses.find(function (c) { return c.courseId === state.selectedCourseId; }) || {};
    let html =
      '<div class="cgt-head">' +
        '<div class="cgt-title-row">' +
          '<h3 class="cgt-title">' + escapeHtml(state.content.course_title || selCourse.title || "") + '</h3>' +
          courseStatusBadge(selCourse.status) +
          '<button id="cgt-cocreate" class="cgt-cocreate" type="button" data-testid="prep-cocreate">✦ 和教研助手共创</button>' +
          (isNewDraft
            ? '<span class="cgch-chip">新课程 · 未保存草稿</span>'
            : (Number.isInteger(state.content.version)
              ? '<span class="cgch-chip" data-testid="prep-draft-version">草稿 v' + escapeHtml(state.content.version) + '</span>' : "")) +
        '</div>' +
        (canEditCourse(state.selectedCourseId)
          ? '<button id="cgt-edit-toggle" class="cgch-btn cgch-btn-ghost" type="button" data-testid="prep-edit-toggle">编辑内容</button>'
          : '<span class="cgch-empty">当前课程归属工作台无教研角色,只读</span>') +
      '</div>';

    html += prepStepper();

    if (state.conflict) {
      html += '<div class="cgc-banner" data-testid="prep-conflict">' + escapeHtml(state.conflict) + '</div>';
    }
    if (state.saveError) {
      html += '<div class="cgc-card cgc-ev-err">保存失败:' + escapeHtml(state.saveError.message || "") + '</div>';
    }

    html += prepSection();

    if (isNewDraft) {
      html += '<div class="cgc-card"><b>这门课还没有任何内容。</b><br>' +
        '<span class="cgch-empty">点右上「编辑内容」开始编写课程目标与学习单元。注意:保存要求 goals 与至少一张完整单元卡(含故事、清单、学习目标 objectives)一起提交,不能只存目标、也不能缺 objectives——保存时即校验。首次保存创建草稿(v0)。</span></div>';
    }
    const goals = Array.isArray(state.content.goals) ? state.content.goals : [];
    const issues = Array.isArray(state.content.issues) ? state.content.issues : [];
    html += '<div class="cgc-card"><div class="cgt-section-title">课程目标 (' + goals.length + ')</div>' +
      (goals.length ? '<ul class="cgt-plain-list">' + goals.map(function (g) { return '<li>' + escapeHtml(g) + '</li>'; }).join("") + '</ul>' : '<div class="cgch-empty">无</div>') +
      '</div>';
    html += '<div class="cgc-card"><div class="cgt-section-title">学习单元 (' + issues.length + ')</div>' +
      (issues.length
        ? '<div class="cgch-row-list">' + issues.map(function (i) {
            return '<div class="cgch-row"><span class="cgch-chip">' + escapeHtml(i.kind || "") + '</span>' +
              '<span class="cgch-row-copy">' + escapeHtml(i.title || i.id) + '</span></div>';
          }).join("") + '</div>'
        : '<div class="cgch-empty">无</div>') +
      '</div>';

    main.innerHTML = html;
    const toggle = main.querySelector("#cgt-edit-toggle");
    if (toggle) toggle.addEventListener("click", enterEdit);
    const cocreate = main.querySelector("#cgt-cocreate");
    if (cocreate) cocreate.addEventListener("click", coCreateWithTutor);
    bindPrepAction();
  }

  function previewText(kind, raw) {
    if (kind === "goals") {
      const items = raw.split("\n").map(trim).filter(Boolean);
      return items.length ? "解析出 " + items.length + " 条目标,首条: " + items[0] : "空";
    }
    const items = kind === "materials" ? parseMaterials(raw) : parseChecklist(raw);
    return items.length ? "解析出 " + items.length + " 条,首条: " + JSON.stringify(items[0]) : "空";
  }

  function trim(s) { return String(s == null ? "" : s).trim(); }

  function parseMaterials(text) {
    return text.split("\n").map(trim).filter(Boolean).map(function (line) {
      const i = line.indexOf("|");
      return i < 0
        ? { title: line, ref: "" }
        : { title: trim(line.slice(0, i)), ref: trim(line.slice(i + 1)) };
    });
  }

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
        '<div class="cgc-card cgt-issue-edit" data-edit-issue="' + idx + '" data-testid="prep-issue-edit">' +
          '<div class="cgt-edit-row cgt-edit-head">' +
            '<span class="cgc-issue-key">id:' + escapeHtml(issue.id) + '</span>' +
            '<button class="cgc-btn cgc-btn-secondary cgc-btn-mini" type="button" data-remove-issue="' + idx + '">删除</button>' +
          '</div>' +
          '<div class="cgt-edit-row"><label>kind</label>' +
            '<select data-f="kind">' +
              '<option value="handwork"' + (issue.kind === "handwork" ? " selected" : "") + '>handwork(动手型)</option>' +
              '<option value="thoughtwork"' + (issue.kind === "thoughtwork" ? " selected" : "") + '>thoughtwork(知识型)</option>' +
            '</select></div>' +
          '<div class="cgt-edit-row"><label>标题</label>' +
            '<input data-f="title" type="text" value="' + escapeHtml(issue.title || "") + '"></div>' +
          '<div class="cgt-edit-row"><label>as_a(目标学员画像)</label>' +
            '<input data-f="as_a" type="text" value="' + escapeHtml(story.as_a || "") + '"></div>' +
          '<div class="cgt-edit-row"><label>given(先修状态,/ 分隔)</label>' +
            '<input data-f="given" type="text" value="' + escapeHtml((Array.isArray(story.given) ? story.given : []).join(" / ")) + '"></div>' +
          '<div class="cgt-edit-row"><label>goal(完成后能独立做到什么)</label>' +
            '<input data-f="goal" type="text" value="' + escapeHtml(story.goal || "") + '"></div>' +
          '<div class="cgt-edit-row"><label>materials(每行一条,格式:标题 | 链接)</label>' +
            '<textarea data-f="materials" rows="2">' + escapeHtml(mats) + '</textarea>' +
            '<div class="cgt-parse-preview" data-preview="materials"></div></div>' +
          '<div class="cgt-edit-row"><label>checklist(每行一条,格式:id | 文本)</label>' +
            '<textarea data-f="checklist" rows="3">' + escapeHtml(checks) + '</textarea>' +
            '<div class="cgt-parse-preview" data-preview="checklist"></div></div>' +
        '</div>'
      );
    }).join("");

    return (
      '<div class="cgc-actions">' +
        '<span class="cgc-badge" data-testid="prep-draft-version">草稿 v' + draftVersion() + '</span>' +
        '<span class="cgc-panel-sub">编辑课程草稿(保存经 save_course_content,base_version 乐观并发)</span>' +
      '</div>' +
      '<div class="cgc-card" data-testid="curriculum-editor">' +
        '<div class="cgt-edit-row"><label>课程目标 goals(每行一条)</label>' +
          '<textarea id="cgc-edit-goals" rows="3">' + escapeHtml(goalRows) + '</textarea>' +
          '<div class="cgt-parse-preview" id="cgt-preview-goals" data-testid="prep-parse-preview"></div></div>' +
        issueCards +
        '<div class="cgt-edit-row">' +
          '<button id="cgc-add-issue" class="cgc-btn cgc-btn-secondary" type="button" data-testid="prep-add-issue">+ 添加 issue</button>' +
        '</div>' +
        (state.saveError
          ? '<div class="cgc-ev-err">保存失败:' + escapeHtml(state.saveError.message || "") + '</div>'
          : "") +
        '<div class="cgc-actions">' +
          '<button id="cgc-save" class="cgc-btn cgc-btn-primary" type="button" data-testid="prep-save"' +
            (state.saving ? " disabled" : "") + '>' + (state.saving ? "保存中…" : "保存草稿") + '</button>' +
          '<button id="cgc-cancel-edit" class="cgc-btn cgc-btn-secondary" type="button">取消</button>' +
        '</div>' +
      '</div>'
    );
  }

  function bindEditor() {
    currentContainer.querySelectorAll("[data-f='materials'], [data-f='checklist']").forEach(function (el) {
      const box = el.parentElement.querySelector(".cgt-parse-preview");
      if (!box) return;
      const kind = el.getAttribute("data-f");
      const update = function () { box.textContent = previewText(kind, el.value); };
      el.addEventListener("input", update);
      update();
    });
    const goalsEl = currentContainer.querySelector("#cgc-edit-goals");
    const goalsBox = currentContainer.querySelector("#cgt-preview-goals");
    if (goalsEl && goalsBox) {
      const ug = function () { goalsBox.textContent = previewText("goals", goalsEl.value); };
      goalsEl.addEventListener("input", ug);
      ug();
    }
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

  async function saveDraft() {
    if (!state.selectedCourseId || !state.draft || state.saving) return;
    const courseId = state.selectedCourseId;
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
      await loadTeachData();
    } catch (e) {
      if (e && e.status === 409) {
        // AE2:版本冲突——丢弃本地编辑(不做 diff),回只读视图 + 红色横幅
        state.editing = false;
        state.draft = null;
        state.draftContent = null;
        state.conflict = "内容已被他人更新到更新版本,本地编辑已丢弃;请重新进入编辑,基于最新草稿修改";
        await loadTeachData();
      } else {
        state.saveError = e;
      }
    } finally {
      state.saving = false;
      render();
    }
  }

  async function enterEdit() {
    if (!state.selectedCourseId || state.loading) return;
    if (!canEditCourse(state.selectedCourseId)) return;
    const courseId = state.selectedCourseId;
    state.loading = true;
    state.saveError = null;
    render();
    try {
      let content;
      try {
        const res = await apiGet("/courses/" + encodeURIComponent(courseId) + "/content");
        content = res.result || {};
      } catch (inner) {
        if (!/no course content saved/.test(String(inner.message || inner))) throw inner;
        content = { goals: [], issues: [], version: 0 };  // 新课空草稿
      }
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
    if (!window.confirm("放弃未保存的编辑内容?")) return;
    state.draft = null;
    state.draftContent = null;
    state.saveError = null;
    render();
  }

  function prepSection() {
    const prep = state.prep;
    if (!state.canEdit || !prep) return "";

    const policy = prep.policy || {};
    const violations = Array.isArray(prep.gate_violations) ? prep.gate_violations : [];
    const report = prep.latest_quality_report || null;
    const tutor = prep.tutor || null;

    let html =
      '<div class="cgc-card cgc-prep" data-testid="prep-section">' +
        '<div class="cgc-prep-head">' +
          '<b>教研流程</b>' +
          '<span class="cgc-badge" data-testid="prep-state">' + escapeHtml(prep.prep_state || "") + '</span>' +
          (tutor
            ? '<span class="cgc-panel-sub">tutor:' + escapeHtml(tutor.display_name || tutor.user_id || "") + '</span>'
            : "") +
          '<span class="cgc-panel-sub">阈值 ' + escapeHtml(policy.quality_threshold) +
            (policy.review_required ? ' · 需人工审核' : ' · 达标自动发布') + '</span>' +
        '</div>';

    if (violations.length > 0) {
      html +=
        '<ul class="cgc-prep-violations" data-testid="prep-violations">' +
          violations.map(function (v) { return '<li>' + escapeHtml(v) + '</li>'; }).join("") +
        '</ul>';
    }

    if (report) {
      html +=
        '<div class="cgc-prep-quality" data-testid="prep-quality">' +
          '质量报告 ' + escapeHtml(report.score) + '/100 · ' + escapeHtml(report.outcome || "") +
          (report.summary ? '<div class="cgc-panel-sub">' + escapeHtml(report.summary) + '</div>' : "") +
        '</div>';
    }

    return html + '</div>';
  }


  // ---- 未保存保护:退出编辑前确认 ----
  function confirmDiscard() {
    return window.confirm("放弃未保存的编辑内容?");
  }

  // ---- 样式 ----
  function injectStyles() {
    if (document.getElementById("cgt-styles")) return;
    const css = document.createElement("style");
    css.id = "cgt-styles";
    css.textContent = [
      ".cgt-page{display:grid;grid-template-columns:250px 1fr;gap:16px;min-height:100%;box-sizing:border-box;padding:24px clamp(16px,3vw,40px) 48px;color:var(--color-text-primary);background:radial-gradient(circle at 94% 4%,var(--color-accent-soft),transparent 24rem),var(--color-bg-secondary)}",
      ".cgt-side{display:flex;flex-direction:column;gap:8px}",
      ".cgt-side-title{font-size:0.9375rem;font-weight:700;margin-bottom:2px}",
      ".cgt-select{padding:6px 10px;border:1px solid var(--color-border-primary);border-radius:var(--radius-md,8px);background:var(--color-bg-card);color:inherit;font-size:0.8125rem}",
      ".cgt-main{min-width:0}",
      ".cgt-head{display:flex;align-items:center;justify-content:space-between;gap:16px;margin-bottom:16px;flex-wrap:wrap}",
      ".cgt-title-row{display:flex;align-items:center;flex-wrap:wrap;gap:10px}",
      ".cgt-course-status{font-size:0.6875rem;font-weight:600;padding:2px 8px;border-radius:999px;border:1px solid}",
      ".cgt-course-status.is-open{color:var(--color-success,#16a34a);border-color:var(--color-success,#16a34a);background:color-mix(in srgb,var(--color-success,#16a34a) 10%,transparent)}",
      ".cgt-course-status.is-draft{color:var(--color-text-tertiary,#888);border-color:var(--color-border-primary,#888);background:transparent}",
      ".cgt-course-status.is-cancelled{color:var(--color-danger,#dc2626);border-color:var(--color-danger,#dc2626);background:transparent}",
      ".cgt-title{margin:0;font-size:1.125rem;font-weight:700}",
      ".cgt-section-title{font-weight:680;font-size:0.8125rem;margin-bottom:8px}",
      ".cgt-plain-list{margin:0;padding-left:18px;font-size:0.8125rem;line-height:1.8}",
      ".cgc-card{box-sizing:border-box;padding:14px 16px;background:var(--color-bg-card);border:1px solid var(--color-border-primary);border-radius:var(--radius-lg,10px);box-shadow:var(--shadow-xs);font-size:0.8125rem;line-height:1.7;margin-bottom:14px}",
      ".cgc-banner{border:1px solid color-mix(in srgb,var(--color-error,#c0392b) 40%,var(--color-border-primary));background:color-mix(in srgb,var(--color-error,#c0392b) 7%,var(--color-bg-card));border-radius:var(--radius-md,8px);padding:10px 12px;margin-bottom:10px;color:var(--color-error,#c0392b);font-size:0.8125rem}",
      ".cgch-empty{color:var(--color-text-tertiary);font-size:0.8125rem;padding:4px 0}",
      ".cgch-err{color:var(--color-error,#c0392b);font-size:0.8125rem}",
      ".cgch-chip{display:inline-flex;align-items:center;padding:0 8px;min-height:20px;color:var(--color-text-secondary);background:var(--color-bg-subtle);border:1px solid var(--color-border-secondary);border-radius:999px;font-size:0.6875rem;font-weight:650;line-height:1}",
      ".cgch-btn{display:inline-block;padding:7px 14px;border-radius:var(--radius-md,8px);font-size:0.75rem;font-weight:650;text-decoration:none;cursor:pointer;border:1px solid var(--color-border-primary);background:var(--color-bg-card);color:var(--color-text-primary);transition:border-color var(--transition-fast),box-shadow var(--transition-fast)}",
      ".cgch-btn:hover{border-color:var(--color-border-strong);box-shadow:var(--shadow-sm)}",
      ".cgch-btn-ghost{background:transparent}",
      ".cgch-btn-sm{padding:4px 10px;font-size:0.6875rem}",
      ".cgch-row-list{display:flex;flex-direction:column}",
      ".cgch-row{display:flex;gap:10px;align-items:baseline;padding:8px 6px;border-bottom:1px solid var(--color-border-secondary);font-size:0.8125rem}",
      ".cgch-row:last-child{border-bottom:0}",
      ".cgch-row-copy{flex:1;min-width:0;word-break:break-all;text-align:left}",
      ".cgt-edit-row{display:flex;flex-direction:column;gap:4px;margin-bottom:8px;font-size:12px}",
      ".cgt-edit-row{display:flex;flex-direction:column;gap:4px;margin-bottom:8px;font-size:0.75rem}",
      ".cgt-edit-row label{opacity:.65}",
      ".cgt-edit-row input,.cgt-edit-row textarea,.cgt-edit-row select{padding:6px 10px;border:1px solid var(--color-border-primary);border-radius:8px;background:var(--color-bg-card);color:inherit;font-size:0.8125rem;font-family:inherit}",
      ".cgt-edit-head{flex-direction:row;justify-content:space-between;align-items:center}",
      ".cgcc-issue-edit{margin-top:10px}",
      ".cgcc-card-grid{display:grid;grid-template-columns:1fr;gap:10px}",
      ".cgt-issue-card{margin-top:10px;padding:12px;background:var(--color-bg-card);border:1px solid var(--color-border-primary);border-radius:var(--radius-lg,10px)}",
      ".cgt-issue-key{font-family:ui-monospace,monospace;font-size:0.6875rem;color:var(--color-text-tertiary)}",
      ".cgt-stepper{display:flex;align-items:center;gap:4px;flex-wrap:wrap;margin-bottom:14px;padding:10px 12px;background:var(--color-bg-card);border:1px solid var(--color-border-primary);border-radius:var(--radius-md,8px)}" +
      ".cgt-stepper-hint{width:100%;font-size:0.6875rem;color:var(--color-text-tertiary);margin-top:6px;line-height:1.5}",
      ".cgt-st{font-size:0.6875rem;font-weight:650;padding:2px 8px;border-radius:999px;border:1px solid var(--color-border-secondary);color:var(--color-text-tertiary)}",
      ".cgt-st-done{color:var(--color-success,#34d399);border-color:var(--color-success,#34d399)}",
      ".cgt-st-current{color:var(--color-accent-primary);border-color:var(--color-accent-primary);background:var(--color-accent-soft)}",
      ".cgt-st-sep{width:10px;height:1px;background:var(--color-border-secondary)}",
      ".cgt-cocreate{padding:7px 14px;border:0;border-radius:var(--radius-md,8px);background:var(--color-accent-primary);color:var(--color-bg-primary,#fff);font-size:0.75rem;font-weight:700;cursor:pointer}",
      ".cgt-cocreate:hover{filter:brightness(1.1)}",
      ".cgt-parse-preview{margin-top:4px;padding:4px 8px;border-radius:6px;font-size:11px;color:var(--color-text-tertiary);background:var(--color-bg-subtle,rgba(127,127,127,.08))}",
      ".cgch-row-dot{flex:none;align-self:center;width:7px;height:7px;border-radius:999px;background:var(--color-border-secondary)}"
    ].join("\n");
    document.head.appendChild(css);
  }

  injectStyles();

  function renderShell(container) {
    currentContainer = container;
    if (!state.bootStarted) {
      state.bootStarted = true;
      container.innerHTML = '<div class="cgt-page"><div class="cgt-main"><div class="cgc-card cgch-empty">加载中…</div></div></div>';
      boot();
      return;
    }
    render();
  }

  document.addEventListener("visibilitychange", function () {
    if (document.hidden || !currentContainer) return;
    reloadWorkspaces();
  });

  Clacky.ext.ui.registerWorkspace(WS_ID, { title: "CGC 教研工作台", render: renderShell });
})();
