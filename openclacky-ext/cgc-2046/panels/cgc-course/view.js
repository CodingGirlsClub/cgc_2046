// CGC-2046 课程学习面板(U9,plan 001 / #180 R15)。
//
// 结构:我的课程 → issue 列表(三态)→ 当前 issue 卡(goal/given/materials/
// checklist 打勾态)→「和导师学这一节」唤起学习会话(Rsk3 降级:复制任务
// 指令文本,粘贴到会话;记录写回发生在 session 工具调用)。
//
// 数据通道:面板 fetch 扩展 loopback 路由(/api/ext/cgc-2046/courses*)→
// 扩展 core 作为 MCP 客户端透传 get_learning_records / get_course_content
// (dsh-cgc-core 已验证模式)。面板纯视图零写操作。
//
// 未连接态(loopback 503 或 status 未配置)→ 引导视图(去连接面板)。

(() => {
  "use strict";
  if (!window.Clacky || !Clacky.ext || Clacky.ext.pure) return;

  const API = "/api/ext/cgc-2046";
  const WS_ID = "cgc-2046-course";
  const STORE_KEY = "cgc2046.coursePanel.workspaceId";
  let currentContainer = null;

  // ---- 面板状态 ----
  const state = {
    workspaceId: "",
    courses: [],       // [{ courseId, records }]
    selected: null,    // { courseId, content, records }
    currentIssue: null,
    loading: false,
    error: null,
    copied: false
  };

  function escapeHtml(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function statusIcon(status) {
    if (status === "done") return '<span class="cgc-st cgc-st-done" data-testid="panel-issue-done">✓</span>';
    if (status === "in_progress") return '<span class="cgc-st cgc-st-progress" data-testid="panel-issue-progress">◔</span>';
    return '<span class="cgc-st cgc-st-todo" data-testid="panel-issue-todo">○</span>';
  }

  // 记录 → (issue_id, item_id) done 集
  function doneIndex(records) {
    const map = {};
    (records || []).forEach(function (r) {
      if (r.done) map[r.issue_id + "\u0000" + r.item_id] = r;
    });
    return map;
  }

  function issueStatus(issue, index) {
    const items = (((issue.story || {}).checklist) || []);
    if (items.length === 0) return "todo";
    const done = items.filter(function (c) {
      return index[(issue.id || "") + "\u0000" + (c.id || "")];
    }).length;
    if (done === items.length) return "done";
    return done > 0 ? "in_progress" : "todo";
  }

  // ---- 数据加载 ----
  async function apiGet(path) {
    const sep = path.indexOf("?") >= 0 ? "&" : "?";
    const res = await fetch(API + path + sep + "workspace_id=" + encodeURIComponent(state.workspaceId), {
      headers: { Accept: "application/json" }
    });
    const body = await res.json().catch(function () { return {}; });
    if (!res.ok) throw Object.assign(new Error(body.error || "HTTP " + res.status), { body, status: res.status });
    return body;
  }

  async function loadCourses() {
    state.loading = true;
    state.error = null;
    render();
    try {
      const payload = await apiGet("/courses");
      const records = (payload.result && payload.result.records) || [];
      const byCourse = {};
      records.forEach(function (r) {
        (byCourse[r.course_id] = byCourse[r.course_id] || []).push(r);
      });
      state.courses = Object.keys(byCourse).map(function (cid) {
        return { courseId: cid, records: byCourse[cid] };
      });
      state.selected = null;
      state.currentIssue = null;
    } catch (e) {
      state.error = e;
      state.courses = [];
    } finally {
      state.loading = false;
      render();
    }
  }

  async function openCourse(courseId) {
    state.loading = true;
    state.error = null;
    render();
    try {
      const [contentRes, recordsRes] = await Promise.all([
        apiGet("/courses/" + encodeURIComponent(courseId) + "/content"),
        apiGet("/courses/" + encodeURIComponent(courseId) + "/records")
      ]);
      const content = contentRes.result || {};
      const records = (recordsRes.result && recordsRes.result.records) || [];
      state.selected = { courseId: courseId, content: content, records: records };
      state.currentIssue = null;
    } catch (e) {
      state.error = e;
      state.selected = null;
    } finally {
      state.loading = false;
      render();
    }
  }

  // H2/H3:课程名走 course_title、issue 走展示层 key(后端 get_course_content
  // 已注入,不再用内部 id 原文/goals 拼接)
  function learningPrompt(issue) {
    const content = (state.selected && state.selected.content) || {};
    const title = content.course_title || "本课程";
    const issueLabel = issue.key ? issue.key + "「" + (issue.title || "") + "」" : (issue.title || issue.id || "");
    return [
      "请和我一起学习课程《" + title + "》的 " + issueLabel + "。",
      "学习目标:" + (((issue.story || {}).goal) || "(见课程内容)"),
      "请按学习 Agent 指令的八步循环开始:先读取我的学习记录与课程内容,从当前进度接续教学。"
    ].join("\n");
  }

  async function copySessionPrompt(issue) {
    const text = learningPrompt(issue);
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
    if (!state.workspaceId) {
      renderWorkspaceConfig();
      return;
    }
    if (state.error && state.error.status === 503) {
      renderNotConnected();
      return;
    }
    if (!state.selected) {
      renderCourseList();
      return;
    }
    renderCourseDetail();
  }

  function shell(inner) {
    currentContainer.innerHTML =
      '<div class="cgc-panel cgc-course-panel">' +
        '<h3 class="cgc-panel-title">CGC 课程学习</h3>' +
        inner +
      '</div>';
  }

  function renderWorkspaceConfig() {
    shell(
      '<p class="cgc-panel-sub">填入平台的 workspace_id(D12 无状态作用域),用于拉取课程数据。</p>' +
      '<div class="cgc-card">' +
        '<input id="cgc-ws-input" class="cgc-input" placeholder="workspace_id(UUID)" />' +
        '<button id="cgc-ws-save" class="cgc-btn" type="button">保存</button>' +
      '</div>' +
      '<p class="cgc-empty">workspace_id 可在网站工作台设置页查看。</p>'
    );
    const input = currentContainer.querySelector("#cgc-ws-input");
    input.value = localStorage.getItem(STORE_KEY) || "";
    currentContainer.querySelector("#cgc-ws-save").addEventListener("click", function () {
      const v = input.value.trim();
      localStorage.setItem(STORE_KEY, v);
      state.workspaceId = v;
      if (v) loadCourses(); else render();
    });
  }

  function renderNotConnected() {
    shell(
      '<div class="cgc-banner" data-testid="panel-not-connected">' +
        '<b>CGC-2046 未连接。</b>' + escapeHtml(state.error.message || "") +
        '<div class="cgc-banner-hint">请先在 CGC-2046 连接面板完成连接(生成 token 并连接),再使用课程学习面板。</div>' +
      '</div>'
    );
  }

  function renderCourseList() {
    let inner =
      '<p class="cgc-panel-sub">我的课程(按学习记录推导)</p>' +
      '<div class="cgc-actions"><button id="cgc-refresh" class="cgc-btn cgc-btn-secondary" type="button">刷新</button></div>';

    if (state.loading) {
      shell(inner + '<div class="cgc-card">加载中…</div>');
      bindBack(null);
      return;
    }
    if (state.error) {
      shell(inner + '<div class="cgc-card cgc-ev-err">加载失败:' + escapeHtml(state.error.message || "") + '</div>');
      bindBack(null);
      return;
    }
    if (state.courses.length === 0) {
      shell(inner + '<div class="cgc-card cgc-empty">暂无在学课程。在网站报名课程并开始学习后,这里会显示课程列表。</div>');
      bindBack(null);
      return;
    }

    const rows = state.courses.map(function (c) {
      return (
        '<div class="cgc-course-row" data-testid="panel-course" data-course="' + escapeHtml(c.courseId) + '">' +
          '<span class="task-name">课程 ' + escapeHtml(c.courseId.slice(0, 8)) + '…</span>' +
          '<span class="cgc-ev">' + c.records.length + ' 条记录</span>' +
        '</div>'
      );
    }).join("");

    shell(inner + '<div class="cgc-card cgc-course-list">' + rows + '</div>');
    bindBack(null);
    currentContainer.querySelectorAll("[data-course]").forEach(function (el) {
      el.addEventListener("click", function () { openCourse(el.getAttribute("data-course")); });
    });
  }

  function renderCourseDetail() {
    const sel = state.selected;
    const issues = ((sel.content && sel.content.issues) || []);
    const index = doneIndex(sel.records);

    let inner =
      '<div class="cgc-actions">' +
        '<button id="cgc-back" class="cgc-btn cgc-btn-secondary" type="button">← 返回课程</button>' +
        '<span class="cgc-panel-sub">' + issues.length + ' 个学习单元</span>' +
      '</div>';

    if (issues.length === 0) {
      shell(inner + '<div class="cgc-card cgc-empty">该课程暂无教研产出(issue 卡未提交)。</div>');
      bindBack(sel.courseId);
      return;
    }

    const list = issues.map(function (issue) {
      const st = issueStatus(issue, index);
      return (
        '<div class="cgc-issue-row' + (state.currentIssue === issue.id ? " cgc-issue-active" : "") + '"' +
          ' data-testid="panel-issue-row" data-issue="' + escapeHtml(issue.id) + '">' +
          statusIcon(st) +
          (issue.key ? '<span class="cgc-issue-key">' + escapeHtml(issue.key) + '</span>' : "") +
          '<span class="task-name">' + escapeHtml(issue.title || issue.id) + '</span>' +
          '<span class="cgc-kind">' + escapeHtml(issue.kind || "") + '</span>' +
        '</div>'
      );
    }).join("");

    const card = state.currentIssue ? currentIssueCard(issues, index) : "";
    shell(inner + '<div class="cgc-card cgc-issue-list">' + list + '</div>' + card);

    bindBack(sel.courseId);
    currentContainer.querySelectorAll("[data-issue]").forEach(function (el) {
      el.addEventListener("click", function () {
        state.currentIssue = el.getAttribute("data-issue");
        render();
      });
    });

    const cta = currentContainer.querySelector("[data-testid='panel-cta']");
    if (cta) {
      cta.addEventListener("click", function () {
        const issue = issues.find(function (i) { return i.id === state.currentIssue; });
        if (issue) copySessionPrompt(issue);
      });
    }
  }

  function currentIssueCard(issues, index) {
    const issue = issues.find(function (i) { return i.id === state.currentIssue; });
    if (!issue) return "";
    const story = issue.story || {};
    const checklist = story.checklist || [];
    const materials = story.materials || [];

    const items = checklist.map(function (c) {
      const rec = index[(issue.id || "") + "\u0000" + (c.id || "")];
      return (
        '<li class="cgc-check' + (rec ? " cgc-check-done" : "") + '" data-testid="panel-check-item" data-done="' + (rec ? "true" : "false") + '">' +
          '<span class="cgc-st">' + (rec ? "✓" : "○") + '</span>' +
          '<span>' + escapeHtml(c.text) +
            (rec && rec.evidence ? '<div class="cgc-ev-hint">证据:' + escapeHtml(rec.evidence) + '</div>' : "") +
          '</span>' +
        '</li>'
      );
    }).join("");

    const given = (story.given || []).map(escapeHtml).join(" / ");

    return (
      '<div class="cgc-card cgc-issue-card" data-testid="panel-issue-card">' +
        '<h4 class="cgc-issue-title">' + escapeHtml(issue.title || "") +
          '<span class="cgc-kind">' + escapeHtml(issue.kind || "") + '</span></h4>' +
        (story.goal ? '<p class="cgc-goal"><b>目标:</b>' + escapeHtml(story.goal) + '</p>' : "") +
        (given ? '<p class="cgc-goal"><b>先修:</b>' + given + '</p>' : "") +
        (materials.length > 0
          ? '<p class="cgc-goal"><b>材料:</b>' + materials.map(function (m) { return escapeHtml(m.title || m.ref || ""); }).join(" / ") + '</p>'
          : "") +
        '<ul class="cgc-checklist">' + items + '</ul>' +
        '<button class="cgc-btn cgc-btn-primary" type="button" data-testid="panel-cta">' +
          (state.copied ? "已复制学习指令" : "和导师学这一节") +
        '</button>' +
        '<div class="cgc-ev-hint">复制指令后粘贴到会话开始学习;学习记录由会话中的工具调用写回。</div>' +
      '</div>'
    );
  }

  function bindBack(_courseId) {
    const refresh = currentContainer.querySelector("#cgc-refresh");
    if (refresh) refresh.addEventListener("click", loadCourses);
    const back = currentContainer.querySelector("#cgc-back");
    if (back) back.addEventListener("click", function () { state.selected = null; state.currentIssue = null; render(); });
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
      ".cgc-btn-primary{background:#6366f1;color:#fff;border:none}";
    document.head.appendChild(css);
  }

  injectStyles();
  state.workspaceId = localStorage.getItem(STORE_KEY) || "";
  Clacky.ext.ui.registerWorkspace(WS_ID, { title: "CGC 课程学习", render: render });
})();
