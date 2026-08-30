// CGC-2046 课程学习中心(U9 重构:S1 学习中心版)。
//
// 定位收敛:本面板 = **导航与规划**(选课程 → 看大纲/进度 → 发起学习);
// 学习的执行在 CGC 助手会话(侧栏「学这一节」面板承接);教研编辑拆出至
// cgc-2046-curriculum 面板(canEdit 门控,本面板左栏底部提供入口)。
//
// 布局(业界课程学习页标准形态:侧边栏大纲树 + 主区内容,极客时间/Coursera
// course-home 同构):
//   左栏  课程切换 + 大纲树(issue 分组 → objective 节点,掌握三态标注:
//         ✓ 掌握 / ● 学习中 / ○ 未学 / 🔒 先修锁;复习到期节点加角标)
//         + [教研工作台] 入口(canEdit)
//   右主区 两态:
//         overview  总进度条 + Resume 卡(next_action,最显眼动作 = 继续上次)
//                   + 待复习队列 + stale 横幅
//         objective 单目标详情(掌握态/尝试/先修/材料/rubric) + [去会话学 ▶]
//
// 学习动作统一出口:[去会话学 ▶] / [继续学习] → 创建/复用助手会话并注入指令
// (contenteditable 管道,token 不出现;objective 粒度,复习条目自动切复习口吻)。
// 本面板不再有任何直接写学习状态的通道(学习记录写回只发生在会话工具调用)。
//
// 安全红线:只渲染 loopback 透传数据,服务端字符串一律 escapeHtml。

(() => {
  "use strict";
  if (!window.Clacky || !Clacky.ext || Clacky.ext.pure) return;

  const API = "/api/ext/cgc-2046";
  const WS_ID = "cgc-2046-course";
  const TEACH_ID = "cgc-2046-curriculum";
  const STORE_KEY = "cgc2046.coursePanel.workspaceId";
  let csrfToken = "";                 // 预留(本面板现无写端点,保持与其它面板一致)
  const POLL_MS = 10000;
  let currentContainer = null;
  let pollTimer = null;

  // ---- 面板状态 ----
  const state = {
    bootStarted: false,
    loadingBoot: false,
    bootError: null,
    workspaces: [],
    workspaceId: "",
    canEdit: false,
    courses: [],        // confirmed 课程报名 → { courseId, title, workspaceId, workspaceName }
    selectedCourseId: "",  // 学习中心选中的课程
    learning: null,     // /learning_state result
    content: null,      // /content result(材料/rubric 详情用)
    revision: null,     // /revision result(issue 标题分组用)
    view: "overview",   // overview | objective
    currentObjectiveId: "",
    progresses: {},     // courseId → 概览摘要(未选中课程的卡片信息)
    loading: false,
    error: null,
    signed: false       // learningSignature(轮询变更检测)
  };

  function escapeHtml(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  const EDIT_ROLES = ["tutor", "owner", "admin"];

  function computeCanEdit() {
    const ws = state.workspaces.find(function (w) { return w.workspace_id === state.workspaceId; });
    const roles = (ws && ws.roles) || [];
    state.canEdit = roles.some(function (r) { return EDIT_ROLES.indexOf(r) >= 0; });
  }

  // ---- 数据加载 ----
  async function rawGet(path) {
    const res = await fetch(API + path, { headers: { Accept: "application/json" } });
    const body = await res.json().catch(function () { return {}; });
    if (!res.ok) throw Object.assign(new Error(body.error || ("HTTP " + res.status)), { body, status: res.status });
    return body;
  }

  async function apiGet(path) {
    const sep = path.indexOf("?") >= 0 ? "&" : "?";
    return rawGet(path + sep + "workspace_id=" + encodeURIComponent(state.workspaceId));
  }

  // ---- 轮询(R11 收敛:只探 learning_state 签名;编辑无此面板不再挂起) ----
  function stopPolling() {
    if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
  }

  function startPolling() {
    stopPolling();
    pollTimer = setInterval(pollTick, POLL_MS);
  }

  let pollInFlight = false;

  async function pollTick() {
    if (!currentContainer || !document.contains(currentContainer)) { stopPolling(); return; }
    if (document.hidden || pollInFlight) return;
    if (state.loading || state.loadingBoot || !state.selectedCourseId) return;
    if (state.error) return;
    pollInFlight = true;
    try {
      const res = await apiGet("/learning_state?workspace_id=" + encodeURIComponent(scopeOf(state.selectedCourseId)) +
        "&course_id=" + encodeURIComponent(state.selectedCourseId));
      const sig = learningSignature(res.result || {});
      if (sig !== state.signed) {
        state.signed = sig;
        await loadCourseData(state.selectedCourseId, true);
      }
    } catch (e) { /* 轮询失败静默 */ } finally { pollInFlight = false; }
  }

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

  // ---- boot ----
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
    loadCourses();
  }

  async function loadCourses() {
    state.loading = true;
    state.error = null;
    render();
    try {
      const payload = await rawGet("/me/enrollments");
      const enrollments = (payload.result && payload.result.enrollments) || [];
      state.courses = enrollments
        .filter(function (e) { return e.kind === "course" && e.status === "confirmed"; })
        .map(function (e) {
          const offering = e.offering || {};
          const ws = e.workspace || {};
          return {
            courseId: String(offering.id || ""),
            title: String(offering.title || ""),
            workspaceId: String(ws.id || e.workspace_id || ""),
            workspaceName: String(ws.name || ws.slug || "")
          };
        })
        .filter(function (c) { return c.courseId !== ""; });
      const storedCourse = localStorage.getItem("cgc2046.learnCenter.courseId") || "";
      const found = state.courses.find(function (c) { return c.courseId === storedCourse; });
      state.selectedCourseId = (found || state.courses[0] || {}).courseId || "";
      if (state.selectedCourseId) localStorage.setItem("cgc2046.learnCenter.courseId", state.selectedCourseId);
      state.loading = false;
      if (state.selectedCourseId) {
        await loadCourseData(state.selectedCourseId);
      } else {
        render();
      }
    } catch (e) {
      state.error = e;
      state.loading = false;
      render();
    }
  }

  // 作用域解析:课程的 MCP 作用域 = 其报名所在的 workspace(enrollment 自带),
  // 与 hub 的 Workspace 选择器无关(那是管理工作台语义)。跨台报名选课时
  // 自动切到课程归属台——否则上游按作用域校验直接报错(S7 语义,重写找回)。
  function scopeOf(courseId) {
    const course = state.courses.find(function (c) { return c.courseId === courseId; });
    return (course && course.workspaceId) || state.workspaceId;
  }

  // 选中课程的三源并行(learning_state 主 / content 材料与 rubric / revision 大纲分组)
  async function loadCourseData(courseId, silent) {
    if (!silent) { state.loading = true; state.error = null; render(); }
    try {
      const ws = scopeOf(courseId);
      const [learningRes, contentRes, revRes] = await Promise.all([
        apiGet("/learning_state?workspace_id=" + encodeURIComponent(ws) +
          "&course_id=" + encodeURIComponent(courseId)),
        apiGet("/courses/" + encodeURIComponent(courseId) + "/content").catch(function () { return { result: {} }; }),
        apiGet("/courses/" + encodeURIComponent(courseId) + "/revision").catch(function () { return { result: null }; })
      ]);
      state.learning = learningRes.result || {};
      state.content = contentRes.result || {};
      state.revision = revRes.result || null;
      state.signed = learningSignature(state.learning);
      state.error = null;
    } catch (e) {
      if (!silent) { state.error = e; state.learning = null; }
    } finally {
      state.loading = false;
      render();
    }
  }

  function selectCourse(courseId) {
    state.selectedCourseId = courseId;
    localStorage.setItem("cgc2046.learnCenter.courseId", courseId);
    state.view = "overview";
    state.currentObjectiveId = "";
    loadCourseData(courseId);
  }

  // ---- 大纲树数据:objectives 按 issue 分组(标题取 revision/content,缺省用 id) ----
  function outlineGroups() {
    const learning = state.learning || {};
    const objectives = learning.objectives || [];
    const issues = (state.revision && state.revision.issues) ||
      (state.content && state.content.issues) || [];
    const issueTitle = {};
    issues.forEach(function (i) {
      if (i && i.id != null) issueTitle[String(i.id)] = i.title || i.key || String(i.id);
    });
    const reviewById = {};
    (learning.review_queue || []).forEach(function (e) {
      if (e && e.objective_id != null) reviewById[String(e.objective_id)] = e;
    });
    const groups = [];
    const byIssue = {};
    objectives.forEach(function (o) {
      const key = String(o.issue_id || "default");
      if (!byIssue[key]) {
        byIssue[key] = { issueId: key, title: issueTitle[key] || ("章节 " + key.slice(0, 8)), objectives: [] };
        groups.push(byIssue[key]);
      }
      byIssue[key].objectives.push(o);
    });
    return { groups: groups, reviewById: reviewById };
  }

  // ---- 注入会话管道(hub/cgc-learn 真机实证同款) ----
  function injectIntoComposer(text) {
    const input = document.getElementById("user-input");
    const send = document.getElementById("btn-send");
    if (!input || !send) {
      window.prompt("复制以下指令到会话开始学习:", text);
      return;
    }
    // 宿主 #user-input 是 contenteditable DIV:textContent 注入(value 是 expando)
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

  function goLearnObjective(objectiveId) {
    // 学习动作 = 创建/进入助手会话后注入指令(hub 同款通道;面板视图内没有
    // 会话输入框,必须先切会话,否则注入落空——真机实证)
    const learning = state.learning || {};
    const obj = (learning.objectives || []).find(function (o) { return o.id === objectiveId; }) || {};
    const title = (state.courses.find(function (c) { return c.courseId === state.selectedCourseId; }) || {}).title || "本课程";
    const review = (learning.review_queue || []).find(function (e) {
      return e && String(e.objective_id) === String(objectiveId);
    });
    const objTitle = obj.title || objectiveId;
    const lines = review
      ? [
          "请带我复习课程《" + title + "》的学习目标「" + objTitle + "」。",
          "(objective_id: " + objectiveId + ")",
          "这是一次到期复习——先诊断我的保留度,再针对性讲解;",
          "复习后正式评价:调用 submit_learning_attempt,evidence 写一句证据摘要,",
          "rubric_results 精确覆盖该目标 rubric 全部 criterion id。"
        ]
      : [
          "请和我一起学习课程《" + title + "》的学习目标「" + objTitle + "」。",
          "(objective_id: " + objectiveId + ")",
          "请按 learner playbook 的七步学习循环:先 get_learning_state 读取课程地图与当前进度,",
          "按 next_action 的 reason 从该目标开始教学;正式评价时调用 submit_learning_attempt,",
          "evidence 写一句证据摘要,rubric_results 精确覆盖该目标 rubric 全部 criterion id。"
        ];
    const course = state.courses.find(function (c) { return c.courseId === state.selectedCourseId; }) || {};
    const wsId = (course.workspaceId) || state.workspaceId;
    const instruction = lines.join("\n").replace("(objective_id: " + objectiveId + ")",
      "(objective_id: " + objectiveId + ", workspace_id: " + wsId + ")");

    fetch("/api/sessions", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        name: "CGC-2046 助手",
        agent_profile: "cgc-assistant",
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
        // 会话就绪(订阅确认前 btn-send 禁用,注入管道已处理补发)
        setTimeout(function () { injectIntoComposer(instruction); }, 1500);
      })
      .catch(function (e) {
        window.alert("打开会话失败：" + String(e.message || e));
      });
  }

  function resumeLearning() {
    const next = (state.learning || {}).next_action || {};
    if (next.objective_id) {
      goLearnObjective(next.objective_id);
    } else {
      goLearnObjective((state.learning && state.learning.objectives || [])[0]);
    }
  }

  // ---- 渲染 ----
  function masteryGlyph(m) {
    if (m === "mastered") return '<span class="cglc-glyph cglc-g-mastered">✓</span>';
    if (m === "developing") return '<span class="cglc-glyph cglc-g-developing">●</span>';
    if (m === "needs_review") return '<span class="cglc-glyph cglc-g-review">!</span>';
    return '<span class="cglc-glyph cglc-g-todo">○</span>';
  }

  function masteryLabel(m) {
    if (m === "mastered") return "已掌握";
    if (m === "developing") return "学习中";
    if (m === "needs_review") return "待复习";
    return "未学";
  }

  function objectiveTitle(objectiveId) {
    const o = ((state.learning || {}).objectives || []).find(function (x) { return x.id === objectiveId; });
    return o ? (o.title || o.id) : String(objectiveId);
  }

  function render() {
    currentContainer = currentContainer || null;
    if (!currentContainer) return;
    if (state.error && state.error.status === 503) { stopPolling(); renderNotConnected(); return; }
    if (state.error && state.error.status !== 503) {
      stopPolling();
      currentContainer.innerHTML =
        '<div class="cglc-page"><div class="cglc-main"><div class="cgc-card cgc-ev-err" data-testid="panel-error">' +
        '加载失败:' + escapeHtml(state.error.message || "") +
        ' <button id="cgc-retry" class="cgc-btn cgc-btn-secondary cgc-btn-sm" type="button">重试</button></div></div></div>';
      const retry = currentContainer.querySelector("#cgc-retry");
      if (retry) retry.addEventListener("click", boot);
      return;
    }
    if (state.bootError) {
      currentContainer.innerHTML =
        '<div class="cglc-page"><div class="cglc-main"><div class="cgc-card cgc-ev-err" data-testid="panel-ws-boot-error">' +
        'Workspace 列表加载失败:' + escapeHtml(state.bootError.message || "") +
        ' <button id="cgc-boot-retry" class="cgc-btn cgc-btn-secondary cgc-btn-sm" type="button">重试</button></div></div></div>';
      const retry = currentContainer.querySelector("#cgc-boot-retry");
      if (retry) retry.addEventListener("click", boot);
      return;
    }

    currentContainer.innerHTML =
      '<div class="cglc-page">' +
        '<aside class="cglc-side">' +
          '<div class="cglc-side-title">课程学习中心</div>' +
          '<select id="cglc-course" class="cglc-select" data-testid="panel-course-select"></select>' +
          '<div class="cglc-tree" id="cglc-tree" data-testid="panel-outline-tree">加载中…</div>' +
          (state.canEdit
            ? '<button id="cgc-teach-entry" class="cglc-teach-entry" type="button" data-testid="panel-teach-entry">教研工作台</button>'
            : "") +
        '</aside>' +
        '<main class="cglc-main" id="cglc-main"></main>' +
      '</div>';

    const courseSel = currentContainer.querySelector("#cglc-course");
    // 按所属 workspace 分组(跨台报名时每门课的归属一目了然)
    const groups = {};
    state.courses.forEach(function (c) {
      const key = c.workspaceName || "其它工作台";
      (groups[key] = groups[key] || []).push(c);
    });
    courseSel.innerHTML = Object.keys(groups).sort().map(function (name) {
      return '<optgroup label="' + escapeHtml(name) + '">' +
        groups[name].map(function (c) {
          const sel = c.courseId === state.selectedCourseId ? " selected" : "";
          return '<option value="' + escapeHtml(c.courseId) + '"' + sel + '>' +
                 escapeHtml(c.title || c.courseId) + '</option>';
        }).join("") + '</optgroup>';
    }).join("");
    courseSel.addEventListener("change", function () { selectCourse(courseSel.value); });

    renderTree();
    renderMain();

    const teach = currentContainer.querySelector("#cgc-teach-entry");
    if (teach) teach.addEventListener("click", function () { Clacky.ext.ui.openWorkspace(TEACH_ID); });
    startPolling();
  }

  function renderTree() {
    const tree = currentContainer.querySelector("#cglc-tree");

    if (!tree) return;
    if (state.loading || !state.learning) {
      tree.innerHTML = '<div class="cgch-empty">' + (state.loading ? "加载中…" : "暂无数据") + '</div>';
      return;
    }
    const _ref = outlineGroups();
    const groups = _ref.groups;
    const reviewById = _ref.reviewById;
    if (!groups.length) {
      tree.innerHTML = '<div class="cgch-empty">该课程暂无学习目标(教研未完成或未发布)。</div>';
      return;
    }
    const reviewCount = ((state.learning || {}).review_queue || []).length;
    const overviewActive = state.view === "overview" ? " is-active" : "";
    let html =
      '<div class="cglc-node cglc-node-overview' + overviewActive + '" data-node="__overview__"' +
        ' data-testid="panel-outline-overview">' +
        '<span class="cglc-glyph cglc-g-mastered">⌂</span>' +
        '<span class="cglc-node-title">课程概览</span>' +
        (reviewCount > 0 ? '<span class="cglc-node-review">' + reviewCount + '</span>' : "") +
      '</div>';
    html += groups.map(function (g) {
      const rows = g.objectives.map(function (o) {
        const locked = !!o.locked;
        const review = reviewById[String(o.id)];
        const active = state.view === "objective" && state.currentObjectiveId === o.id;
        return (
          '<div class="cglc-node' + (locked ? " is-locked" : "") + (active ? " is-active" : "") + '"' +
            (locked ? "" : ' data-node="' + escapeHtml(o.id) + '"') +
            ' data-testid="panel-outline-node" data-objective="' + escapeHtml(o.id) + '">' +
            masteryGlyph(locked ? "todo" : o.mastery) +
            '<span class="cglc-node-title">' + escapeHtml(o.title || o.id) + '</span>' +
            (review ? '<span class="cglc-node-review" data-testid="panel-outline-review">' +
              (review.needs_review === true ? "恢复" : "复习") + '</span>' : "") +
            (locked ? '<span class="cglc-lock">🔒</span>' : "") +
          '</div>'
        );
      }).join("");
      return '<div class="cglc-group"><div class="cglc-group-name">' + escapeHtml(g.title) + '</div>' + rows + '</div>';
    }).join("");
    tree.innerHTML = html;
    tree.querySelectorAll("[data-node]").forEach(function (el) {
      el.addEventListener("click", function () {
        const id = el.getAttribute("data-node");
        if (id === "__overview__") {
          state.view = "overview";
          state.currentObjectiveId = "";
        } else {
          state.view = "objective";
          state.currentObjectiveId = id;
        }
        renderTree();
        renderMain();
      });
    });
  }

  function renderMain() {
    const main = currentContainer.querySelector("#cglc-main");
    if (!main) return;
    if (state.loading) {
      main.innerHTML = '<div class="cgc-card cgch-empty">加载中…</div>';
      return;
    }
    if (!state.learning) {
      main.innerHTML = '<div class="cgc-card cgch-empty">暂无在学课程。在「CGC 发现」报名课程后,这里会显示学习中心。</div>';
      return;
    }
    if (state.view === "objective" && state.currentObjectiveId) {
      renderObjectiveDetail(main);
    } else {
      renderOverview(main);
    }
  }

  // ---- 概览态 ----
  function renderOverview(main) {
    const learning = state.learning || {};
    const progress = learning.progress || {};
    const next = learning.next_action || null;
    const total = Number(progress.total_required) || 0;
    const done = Number(progress.mastered_required) || 0;
    const pct = total > 0 ? Math.round((done * 100) / total) : 0;
    const review = learning.review_queue || [];

    let html =
      '<div class="cglc-head">' +
        '<div class="cglc-title-row">' +
          '<h3 class="cglc-title">' + escapeHtml((state.courses.find(function (c) { return c.courseId === state.selectedCourseId; }) || {}).title || "") + '</h3>' +
          (Number.isInteger(state.content && state.content.version)
            ? '<span class="cgch-chip">草稿 v' + escapeHtml(state.content.version) + '</span>' : "") +
          (progress.complete ? '<span class="cgch-chip cgch-chip-admin">已结业</span>' : "") +
        '</div>' +
        '<div class="cglc-progress" data-testid="panel-progress">' +
          '<div class="cglc-progress-bar" style="width:' + pct + '%"></div>' +
        '</div>' +
        '<div class="cglc-progress-text">必修掌握 ' + done + '/' + total +
          ' · 目标 ' + ((learning.objectives || []).length) + ' 个</div>' +
      '</div>';

    if (learning.stale_revision) {
      html +=
        '<div class="cgc-banner" data-testid="panel-stale">课程已发布新版本,你正在学旧版(进度保留)。' +
          '点「继续学习」将开新版 run。</div>';
    }

    // Resume 卡:最显眼动作 = 继续上次
    if (next && next.objective_id) {
      html +=
        '<div class="cglc-resume" data-testid="panel-resume">' +
          '<div class="cglc-resume-copy">' +
            '<span class="cglc-badge cglc-badge-next">继续学习</span>' +
            '<span class="cglc-resume-text">' + escapeHtml(objectiveTitle(next.objective_id)) +
              (next.reason ? ' — ' + escapeHtml(next.reason) : "") + '</span>' +
          '</div>' +
          '<button class="cglc-resume-btn" type="button" data-testid="panel-resume-btn">▶ 继续学习</button>' +
        '</div>';
    }

    // 待复习队列
    if (review.length > 0) {
      const rows = review.map(function (entry) {
        const urgent = entry.needs_review === true;
        const id = String(entry.objective_id || "");
        return (
          '<button class="cglc-row" type="button" data-review="' + escapeHtml(id) + '"' +
            ' data-testid="panel-review-row">' +
            '<span class="' + (urgent ? "cgch-err" : "cglc-review-due") + '" data-testid="panel-review-due">' +
              (urgent ? "待复习恢复" : "第 " + escapeHtml(entry.milestone_days) + " 天复习到期") + '</span>' +
            '<span class="cglc-row-copy">' + escapeHtml(objectiveTitle(id)) + '</span>' +
            '<span class="cgch-btn cgch-btn-ghost cgch-btn-sm">去学 ▶</span>' +
          '</button>'
        );
      }).join("");
      html += '<div class="cgc-card"><div class="cglc-section-title">待复习</div>' +
        '<div class="cgch-row-list">' + rows + '</div></div>';
    }

    main.innerHTML = html;
    const resumeBtn = main.querySelector("[data-testid='panel-resume-btn']");
    if (resumeBtn) resumeBtn.addEventListener("click", resumeLearning);
    main.querySelectorAll("[data-review]").forEach(function (row) {
      row.addEventListener("click", function () { goLearnObjective(row.getAttribute("data-review")); });
    });
  }

  // ---- 目标详情态 ----
  function renderObjectiveDetail(main) {
    const learning = state.learning || {};
    const o = (learning.objectives || []).find(function (x) { return x.id === state.currentObjectiveId; });
    if (!o) { state.view = "overview"; renderMain(); return; }
    const locked = !!o.locked;
    const missing = o.missing_prereq_ids || [];
    const review = (learning.review_queue || []).find(function (e) {
      return e && String(e.objective_id) === String(o.id);
    });

    // 材料/rubric 取自 content(按 objective id 对齐;S8 后 learner 材料可见性在此恢复)
    let materials = [];
    let rubric = [];
    let activity = "";
    let assessment = "";
    ((state.content && state.content.issues) || []).forEach(function (issue) {
      ((issue && issue.objectives) || []).forEach(function (co) {
        if (co && String(co.id) === String(o.id)) {
          materials = Array.isArray(co.materials) ? co.materials : [];
          rubric = Array.isArray(co.rubric) ? co.rubric : [];
          activity = co.activity || "";
          assessment = co.assessment || "";
        }
      });
    });

    let html =
      '<div class="cglc-head">' +
        '<div class="cglc-title-row">' +
          '<h3 class="cglc-title">' + escapeHtml(o.title || o.id) + '</h3>' +
          '<span class="cgch-chip" data-testid="panel-obj-badge">' + escapeHtml(masteryLabel(o.mastery)) + '</span>' +
          (o.required ? "" : '<span class="cgch-chip">选修</span>') +
        '</div>' +
        '<div class="cglc-progress-text">' +
          '尝试 ' + escapeHtml(o.attempt_count || 0) + ' 次' +
          (o.last_attempt_at ? ' · 上次 ' + escapeHtml(new Date(o.last_attempt_at).toLocaleString()) : "") +
        '</div>' +
      '</div>';

    if (locked) {
      html += '<div class="cgc-banner">🔒 该目标未解锁,需先修:' +
        escapeHtml(missing.map(function (m) { return m.title || m.id; }).join("、")) + '</div>';
    }

    html += '<div class="cglc-obj-grid">';

    html += '<div class="cgc-card">' +
      '<div class="cglc-section-title">学习活动</div>' +
      (activity ? '<div class="cglc-kv"><label>活动</label><span>' + escapeHtml(activity) + '</span></div>' : "") +
      (assessment ? '<div class="cglc-kv"><label>评估</label><span>' + escapeHtml(assessment) + '</span></div>' : "") +
      (materials.length
        ? '<div class="cglc-kv"><label>材料</label><span>' + materials.map(function (m) {
            const ref = m.ref ? ' <a href="' + escapeHtml(m.ref) + '" target="_blank" rel="noopener noreferrer">' + escapeHtml(m.ref) + '</a>' : "";
            return escapeHtml(m.title || "") + ref;
          }).join('<br>') + '</span></div>'
        : '<div class="cglc-kv"><label>材料</label><span class="cgch-empty">无</span></div>') +
      '</div>';

    html += '<div class="cgc-card">' +
      '<div class="cglc-section-title">评价标准 (rubric)</div>' +
      (rubric.length
        ? '<ul class="cglc-rubric">' + rubric.map(function (r) {
            return '<li>' + escapeHtml(r.text || r.id) + '</li>';
          }).join("") + '</ul>'
        : '<div class="cgch-empty">无</div>') +
      '</div>';

    html += '</div>';

    const ctaDisabled = locked ? " disabled" : "";
    html +=
      '<div class="cglc-resume" data-testid="panel-obj-cta">' +
        '<div class="cglc-resume-copy">' +
          (review
            ? '<span class="cglc-resume-text">' + (review.needs_review === true ? "该目标待复习恢复" : "复习到期") + '——学习时将先诊断保留度</span>'
            : '<span class="cglc-resume-text">准备好就出发,助手按七步学习循环带你掌握它</span>') +
        '</div>' +
        '<button class="cglc-resume-btn" type="button" data-testid="panel-obj-learn"' + ctaDisabled + '>▶ 去会话学</button>' +
      '</div>';

    main.innerHTML = html;
    const learnBtn = main.querySelector("[data-testid='panel-obj-learn']");
    if (learnBtn && !locked) {
      learnBtn.addEventListener("click", function () { goLearnObjective(o.id); });
    }
  }

  function renderNotConnected() {
    currentContainer.innerHTML =
      '<div class="cglc-page"><div class="cglc-main">' +
        '<div class="cgc-banner" data-testid="panel-not-connected">' +
          '<b>CGC-2046 未连接。</b>' + escapeHtml(state.error.message || "") +
          '<div class="cgc-banner-hint">请先在 CGC-2046 连接面板完成连接(生成 token 并连接),再使用课程学习面板。</div>' +
        '</div>' +
        '<div class="cgch-actions"><button id="cgc-retry" class="cgc-btn cgc-btn-secondary cgc-btn-sm" type="button" data-testid="panel-retry">重试</button></div>' +
      '</div></div>';
    currentContainer.querySelector("#cgc-retry").addEventListener("click", boot);
  }

  // ---- 样式(宿主变量;左栏大纲树 + 主区两态) ----
  function injectStyles() {
    if (document.getElementById("cglc-styles")) return;
    const css = document.createElement("style");
    css.id = "cglc-styles";
    css.textContent = [
      ".cglc-page{display:grid;grid-template-columns:250px 1fr;gap:16px;min-height:100%;box-sizing:border-box;padding:24px clamp(16px,3vw,40px) 48px;color:var(--color-text-primary);background:radial-gradient(circle at 94% 4%,var(--color-accent-soft),transparent 24rem),var(--color-bg-secondary)}",
      ".cglc-side{display:flex;flex-direction:column;gap:8px}",
      ".cglc-side-title{font-size:0.9375rem;font-weight:700;margin-bottom:2px}",
      ".cglc-select{padding:6px 10px;border:1px solid var(--color-border-primary);border-radius:var(--radius-md,8px);background:var(--color-bg-card);color:inherit;font-size:0.8125rem}",
      ".cglc-tree{background:var(--color-bg-card);border:1px solid var(--color-border-primary);border-radius:var(--radius-lg,10px);box-shadow:var(--shadow-xs);padding:8px;flex:1;overflow-y:auto}",
      ".cglc-group-name{font-size:0.6875rem;font-weight:650;color:var(--color-text-tertiary);padding:8px 6px 4px;text-transform:uppercase;letter-spacing:0.04em}",
      ".cglc-node{display:flex;gap:7px;align-items:center;padding:6px 8px;border-radius:var(--radius-md,8px);cursor:pointer;font-size:0.8125rem}",
      ".cglc-node:hover{background:var(--color-bg-hover)}",
      ".cglc-node.is-active{background:var(--color-accent-soft)}",
      ".cglc-node.is-locked{opacity:0.55;cursor:default}",
      ".cglc-glyph{flex:none;width:16px;height:16px;display:inline-flex;align-items:center;justify-content:center;border-radius:999px;font-size:10px;font-weight:700}",
      ".cglc-g-mastered{color:var(--color-success,#34d399);border:1px solid currentColor}",
      ".cglc-g-developing{color:var(--color-warning,#fbbf24);border:1px solid currentColor}",
      ".cglc-g-review{color:var(--color-error,#f87171);border:1px solid currentColor}",
      ".cglc-g-todo{color:var(--color-text-muted);border:1px solid currentColor}",
      ".cglc-node-title{flex:1;min-width:0;word-break:break-all}",
      ".cglc-node-review{flex:none;font-size:10px;font-weight:700;color:var(--color-warning,#fbbf24)}",
      ".cglc-lock{flex:none;font-size:11px}",
      ".cglc-teach-entry{margin-top:4px;padding:8px 10px;border:1px dashed var(--color-border-primary);border-radius:var(--radius-md,8px);background:transparent;color:var(--color-text-secondary);cursor:pointer;font-size:0.75rem;text-align:left}",
      ".cglc-teach-entry:hover{color:var(--color-text-primary);border-color:var(--color-border-strong)}",
      ".cglc-main{min-width:0}",
      ".cglc-head{margin-bottom:16px}",
      ".cglc-title-row{display:flex;align-items:center;flex-wrap:wrap;gap:10px}",
      ".cglc-title{margin:0;font-size:1.125rem;font-weight:700;letter-spacing:-0.01em}",
      ".cglc-progress{height:8px;border-radius:4px;background:var(--color-bg-hover);overflow:hidden;margin:10px 0 6px;max-width:420px}",
      ".cglc-progress-bar{height:100%;background:var(--color-accent-primary)}",
      ".cglc-progress-text{font-size:0.75rem;color:var(--color-text-tertiary)}",
      ".cglc-resume{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:16px;padding:16px 18px;background:var(--color-bg-card);border:1px solid color-mix(in srgb,var(--color-accent-primary) 30%,var(--color-border-primary));border-radius:var(--radius-lg,10px);box-shadow:var(--shadow-sm)}",
      ".cglc-resume-copy{flex:1;min-width:200px;display:flex;align-items:center;gap:10px;flex-wrap:wrap}",
      ".cglc-resume-text{font-size:0.875rem}",
      ".cglc-resume-btn{flex:none;padding:9px 18px;border:0;border-radius:var(--radius-md,8px);background:var(--color-accent-primary);color:var(--color-bg-primary,#fff);font-size:0.8125rem;font-weight:700;cursor:pointer;transition:filter var(--transition-fast)}",
      ".cglc-resume-btn:hover{filter:brightness(1.1)}",
      ".cglc-badge-next{display:inline-flex;align-items:center;padding:0 8px;min-height:20px;border-radius:999px;font-size:0.6875rem;font-weight:700;color:var(--color-accent-primary);background:var(--color-accent-soft);border:1px solid color-mix(in srgb,var(--color-accent-primary) 24%,var(--color-border-primary))}",
      ".cglc-section-title{font-weight:680;font-size:0.8125rem;margin-bottom:8px}",
      ".cglc-kv{display:flex;gap:8px;margin-bottom:6px;font-size:0.8125rem}",
      ".cglc-kv label{flex:none;min-width:44px;color:var(--color-text-tertiary)}",
      ".cglc-rubric{margin:0;padding-left:18px;font-size:0.8125rem;line-height:1.8}",
      ".cglc-obj-grid{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:16px}",
      ".cglc-review-due{font-size:0.6875rem;color:var(--color-warning,#fbbf24);white-space:nowrap}",
      "@media (max-width:900px){.cglc-page{grid-template-columns:1fr}.cglc-obj-grid{grid-template-columns:1fr}}",
      ".cgc-card{box-sizing:border-box;padding:14px 16px;background:var(--color-bg-card);border:1px solid var(--color-border-primary);border-radius:var(--radius-lg,10px);box-shadow:var(--shadow-xs);font-size:0.8125rem;line-height:1.7;margin-bottom:14px}",
      ".cgc-banner{border:1px solid color-mix(in srgb,var(--color-error,#c0392b) 40%,var(--color-border-primary));background:color-mix(in srgb,var(--color-error,#c0392b) 7%,var(--color-bg-card));border-radius:var(--radius-md,8px);padding:10px 12px;margin-bottom:10px;color:var(--color-error,#c0392b);font-size:0.8125rem}",
      ".cgc-banner-hint{margin-top:4px;opacity:0.85}",
      ".cgch-empty{color:var(--color-text-tertiary);font-size:0.8125rem;padding:4px 0}",
      ".cgch-err{color:var(--color-error,#c0392b);font-size:0.8125rem}",
      ".cgch-chip{display:inline-flex;align-items:center;padding:0 8px;min-height:20px;color:var(--color-text-secondary);background:var(--color-bg-subtle);border:1px solid var(--color-border-secondary);border-radius:999px;font-size:0.6875rem;font-weight:650;line-height:1}",
      ".cgch-chip-admin{color:var(--color-accent-primary);background:var(--color-accent-soft);border-color:color-mix(in srgb,var(--color-accent-primary) 24%,var(--color-border-primary))}",
      ".cgch-actions{display:flex;gap:8px;flex-wrap:wrap}",
      ".cgch-btn{display:inline-block;padding:7px 14px;border-radius:var(--radius-md,8px);font-size:0.75rem;font-weight:650;text-decoration:none;cursor:pointer;border:1px solid var(--color-border-primary);background:var(--color-bg-card);color:var(--color-text-primary);transition:border-color var(--transition-fast),box-shadow var(--transition-fast)}",
      ".cgch-btn:hover{border-color:var(--color-border-strong);box-shadow:var(--shadow-sm)}",
      ".cgch-btn-ghost{background:transparent}",
      ".cgch-btn-sm{padding:4px 10px;font-size:0.6875rem}",
      ".cgch-row-list{display:flex;flex-direction:column}",
      ".cgch-row{display:flex;gap:10px;align-items:baseline;padding:8px 6px;border-bottom:1px solid var(--color-border-secondary);font-size:0.8125rem}",
      ".cgch-row:last-child{border-bottom:0}",
      ".cgch-row:hover{background:var(--color-bg-hover)}",
      ".cgch-row-copy{flex:1;min-width:0;word-break:break-all;text-align:left}"
    ].join("\n");
    document.head.appendChild(css);
  }

  // ---- 生命周期 ----
  function renderShell(container) {
    currentContainer = container;
    if (!state.bootStarted) {
      state.bootStarted = true;
      container.innerHTML = '<div class="cglc-page"><div class="cglc-main"><div class="cgc-card cgch-empty">加载中…</div></div></div>';
      boot();
      return;
    }
    render();
  }

  injectStyles();
  Clacky.ext.ui.registerWorkspace(WS_ID, { title: "CGC 课程学习中心", render: renderShell });
})();
