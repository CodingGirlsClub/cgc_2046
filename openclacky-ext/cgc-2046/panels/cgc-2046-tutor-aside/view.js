// CGC 教研侧边栏(P1 AI 辅助教研;session.aside,attach cgc-tutor)。
//
// 定位:教研会话(cgc-tutor)右侧的**实时产出视图**——会话是创作过程,本侧栏是
// 产出物状态:当前课程草稿树(goals/issues/objectives 摘要)+ version 徽章 +
// prep 流程状态点。编辑留在教研工作台主面板(窄栏适合看,不适合改)。
//
// 同步机制(推拉结合 + 轮询兜底):
//   - 订阅 ext.cgc-2046.draft_saved(hook 在 agent 保存草稿后推的纯信号)→
//     防抖后拉最新草稿;订阅 tool_used(invoke_skill 完成信号)同样触发;
//   - 10s 低频轮询 version 签名兜底(事件丢失时最终一致);
//   - version 变化才重渲染(不打断 tutor 阅读)。
//
// 课程选择与教研工作台共享 localStorage key(cgc2046.curriculum.courseId):
// 面板选哪门课,侧边栏跟随;作用域按课程归属工作台(与学习中心同款语义)。

(() => {
  "use strict";
  if (!window.Clacky || !Clacky.ext || Clacky.ext.pure) return;

  const API = "/api/ext/cgc-2046";
  const AGENT = "cgc-tutor";
  const POLL_MS = 10000;
  let root = null;
  let refreshTimer = null;
  let pollTimer = null;

  const state = {
    courses: [],          // [{ courseId, title, workspaceId }]
    selectedCourseId: "",
    content: null,
    prep: null,
    loading: true,
    error: null,
    lastRefresh: "",
    signed: ""            // version+结构签名(变化才重渲染)
  };

  function escapeHtml(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  async function rawGet(path) {
    const res = await fetch(API + path, { headers: { Accept: "application/json" } });
    const body = await res.json().catch(function () { return {}; });
    if (!res.ok) throw Object.assign(new Error(body.error || ("HTTP " + res.status)), { status: res.status });
    return body;
  }

  function scopeOf(courseId) {
    const course = state.courses.find(function (c) { return c.courseId === (courseId || state.selectedCourseId); });
    return (course && course.workspaceId) || "";
  }

  function signature() {
    const c = state.content || {};
    return "v" + (Number.isInteger(c.version) ? c.version : 0) + ";" +
      (c.goals || []).length + ";" + (c.issues || []).length + ";" +
      ((state.prep || {}).prep_state || "");
  }

  // ---- 数据 ----
  async function loadCourses() {
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
            workspaceId: String(ws.id || e.workspace_id || "")
          };
        })
        .filter(function (c) { return c.courseId !== ""; });
      const stored = localStorage.getItem("cgc2046.curriculum.courseId") || "";
      const found = state.courses.find(function (c) { return c.courseId === stored; });
      state.selectedCourseId = (found || state.courses[0] || {}).courseId || "";
    } catch (e) {
      state.error = e;
      state.loading = false;
      renderPanel();
      return;
    }
    await refreshDraft();
  }

  async function refreshDraft() {
    if (!state.selectedCourseId) {
      state.loading = false;
      renderPanel();
      return;
    }
    try {
      const ws = scopeOf();
      const [contentRes, prepRes] = await Promise.all([
        rawGet("/courses/" + encodeURIComponent(state.selectedCourseId) + "/content?workspace_id=" + encodeURIComponent(ws))
          .catch(function () { return { result: null }; }),
        rawGet("/courses/" + encodeURIComponent(state.selectedCourseId) + "/prep?workspace_id=" + encodeURIComponent(ws))
          .catch(function () { return { result: null }; })
      ]);
      state.content = contentRes.result || null;
      state.prep = (prepRes.result || null);
      state.lastRefresh = new Date().toLocaleTimeString();
      state.error = null;
    } catch (e) {
      state.error = e;
    } finally {
      state.loading = false;
      renderPanel();
    }
  }

  // 事件驱动的防抖刷新(draft_saved / tool_used 信号 → 拉最新)
  function scheduleRefresh() {
    if (refreshTimer) clearTimeout(refreshTimer);
    refreshTimer = setTimeout(async function () {
      refreshTimer = null;
      if (!root || !document.contains(root)) return;
      const before = signature();
      await refreshDraft();
      if (signature() !== before && root) flashVersion();
    }, 800);
  }

  function flashVersion() {
    if (!root) return;
    const badge = root.querySelector("[data-version-badge]");
    if (badge) {
      badge.classList.add("is-flash");
      setTimeout(function () { badge.classList.remove("is-flash"); }, 1600);
    }
  }

  // ---- 渲染 ----
  const PREP_STATES = ["draft", "authoring", "quality_check", "review", "published"];
  const PREP_LABELS = { draft: "草稿", authoring: "编写中", quality_check: "质检", review: "审核", published: "已发布" };

  function prepDots() {
    const current = (state.prep || {}).prep_state || "draft";
    const idx = PREP_STATES.indexOf(current);
    return PREP_STATES.map(function (s, i) {
      const cls = i < idx ? " is-done" : (i === idx ? " is-current" : "");
      return '<span class="cgta-dot' + cls + '" title="' + escapeHtml(PREP_LABELS[s] || s) + '">' +
        escapeHtml(PREP_LABELS[s] || s) + '</span>';
    }).join('<span class="cgta-sep"></span>');
  }

  function draftTree() {
    const c = state.content;
    if (!c) return '<div class="cgta-empty">暂无草稿(新课程,等待助手生成或手动创建)</div>';
    const goals = c.goals || [];
    const issues = c.issues || [];
    let html = "";
    if (goals.length) {
      html += '<div class="cgta-goals">' + goals.map(function (g) {
        return '<div class="cgta-goal">· ' + escapeHtml(g) + '</div>';
      }).join("") + '</div>';
    }
    html += issues.map(function (issue) {
      const objs = (issue.objectives || []);
      return (
        '<div class="cgta-issue">' +
          '<div class="cgta-issue-name">' + escapeHtml(issue.title || issue.id) +
            '<span class="cgta-count">' + objs.length + ' 目标</span></div>' +
          objs.map(function (o) {
            return '<div class="cgta-obj">· ' + escapeHtml(o.title || o.id) + '</div>';
          }).join("") +
        '</div>'
      );
    }).join("");
    if (!goals.length && !issues.length) {
      html += '<div class="cgta-empty">空草稿</div>';
    }
    return html;
  }

  function renderPanel() {
    if (!root) return;
    const _prep = (state.prep || {}).prep_state;
    const goalsLen = ((state.content || {}).goals || []).length;
    const issuesLen = ((state.content || {}).issues || []).length;

    let html =
      '<div class="cgt2-header">' +
        '<div class="cgt2-header-copy">' +
          '<div class="cgt2-title">教研产出</div>' +
          '<div class="cgt2-progress-text">' +
            (_prep ? escapeHtml(PREP_LABELS[_prep] || _prep) : "草稿") +
            ' · ' + goalsLen + ' 目标 · ' + issuesLen + ' 单元' +
          '</div>' +
        '</div>' +
        '<button id="cgta-refresh" class="cgt2-sync" type="button">刷新</button>' +
      '</div>' +
      '<div class="cgt2-source">' +
        '<span class="cgt2-source-dot"></span><span>草稿树</span>' +
        (state.lastRefresh ? '<span class="cgt2-source-date">' + escapeHtml(state.lastRefresh) + '</span>' : "") +
      '</div>' +
      '<div class="cgt2-content">';

    if (state.loading) {
      root.innerHTML = html + '<div class="cgt2-empty">加载中…</div></div>';
      bindHead();
      return;
    }
    if (state.error) {
      root.innerHTML = html + '<div class="cgt2-empty cgt2-error">加载失败:' + escapeHtml(state.error.message || "") + '</div></div>';
      bindHead();
      return;
    }
    if (!state.courses.length) {
      root.innerHTML = html + '<div class="cgt2-empty">暂无 confirmed 课程报名。</div></div>';
      bindHead();
      return;
    }

    // 课程折叠卡(details):选中默认展开+「当前」pill;点非选中卡=切课
    html += state.courses.map(function (c) {
      const isSel = c.courseId === state.selectedCourseId;
      return (
        '<details class="cgt2-course"' + (isSel ? " open" : "") + ' data-course="' + escapeHtml(c.courseId) + '">' +
          '<summary class="cgt2-course-summary">' +
            '<span class="cgt2-course-copy">' +
              '<span class="cgt2-course-title">' + escapeHtml(c.title) + '</span>' +
              (isSel ? '<span class="cgt2-course-now">当前</span>' : "") +
            '</span>' +
            '<span class="cgt2-course-chevron">⌄</span>' +
          '</summary>' +
          '<div class="cgt2-course-body" data-body="' + escapeHtml(c.courseId) + '"></div>' +
        '</details>'
      );
    }).join("");
    html += '</div>';

    // 选中课程内容块(渲染后搬进卡 body)
    let inner = "";
    const c = state.content;
    const v = c && Number.isInteger(c.version) ? c.version : null;
    const isNew = v === 0 && goalsLen === 0 && issuesLen === 0;
    inner += '<div class="cgt2-status">' +
      (v !== null
        ? '<span class="cgt2-version" data-version-badge>' + (isNew ? "新课程" : "草稿 v" + escapeHtml(v)) + '</span>'
        : '<span class="cgt2-version">无草稿</span>') +
      '<span class="cgt2-prepbar">' + prepDots() + '</span>' +
    '</div>';

    if (isNew) {
      inner += '<div class="cgt2-continue">' +
        '<div class="cgt2-eyebrow">开始共创</div>' +
        '<div class="cgt2-continue-title">这门课还没有任何内容</div>' +
        '<div class="cgt2-continue-subtitle">点下面的按钮,让教研助手从零生成初稿</div>' +
        '<button class="cgt2-continue-button" type="button" data-cocreate>✦ 让助手开始生成</button>' +
      '</div>';
    } else if (c) {
      if (goalsLen) {
        inner += '<div class="cgt2-goals">' + (c.goals || []).map(function (g) {
          return '<div class="cgt2-goal">· ' + escapeHtml(g) + '</div>';
        }).join("") + '</div>';
      }
      inner += (c.issues || []).map(function (issue) {
        const objs = (issue.objectives || []);
        return (
          '<details class="cgt2-issue"' + ' open>' +
            '<summary class="cgt2-issue-summary">' +
              '<span class="cgt2-issue-name">' + escapeHtml(issue.title || issue.id) + '</span>' +
              '<span class="cgt2-issue-count">' + objs.length + ' 目标</span>' +
              '<span class="cgt2-course-chevron">⌄</span>' +
            '</summary>' +
            '<div class="cgt2-issue-body">' + objs.map(function (o) {
              return '<div class="cgt2-obj">· ' + escapeHtml(o.title || o.id) + '</div>';
            }).join("") + '</div>' +
          '</details>'
        );
      }).join("");
    } else {
      inner += '<div class="cgt2-empty">暂无草稿(新课程,等待助手生成或手动创建)</div>';
    }
    inner += '<button id="cgta-open-workbench" class="cgt2-open" type="button">在教研工作台打开 →</button>';

    root.innerHTML = html;
    const selBody = root.querySelector("[data-body='" + state.selectedCourseId + "']");
    if (selBody) selBody.innerHTML = inner;

    bindHead();
    const sel2 = root.querySelector(".cgt2-course");
    // 绑定非选中卡 = 切课;选中卡 = 折叠
    root.querySelectorAll(".cgt2-course").forEach(function (d) {
      const cid = d.getAttribute("data-course");
      d.querySelector(".cgt2-course-summary").addEventListener("click", function (e) {
        if (cid === state.selectedCourseId) return;
        e.preventDefault();
        state.selectedCourseId = cid;
        localStorage.setItem("cgc2046.curriculum.courseId", cid);
        refreshDraft();
      });
    });
    const cocreate = root.querySelector("[data-cocreate]");
    if (cocreate) cocreate.addEventListener("click", function () {
      Clacky.ext.ui.openWorkspace("cgc-2046-curriculum");
      // 打开工作台后自动触发共创按钮(面板 boot 后)
      setTimeout(function () {
        var btn = document.getElementById("cgt-cocreate");
        if (btn) btn.click();
      }, 2000);
    });
    const open = root.querySelector("#cgta-open-workbench");
    if (open) open.addEventListener("click", function () {
      Clacky.ext.ui.openWorkspace("cgc-2046-curriculum");
    });
  }

  function bindHead() {
    const btn = root.querySelector("#cgta-refresh");
    if (btn) btn.addEventListener("click", refreshDraft);
  }

  // ---- 样式(窄侧栏,紧凑) ----
  function injectStyles() {
    if (document.getElementById("cgta-styles")) return;
    const css = document.createElement("style");
    css.id = "cgta-styles";
    css.textContent =
      ".cgt2-root{min-height:100%;color:var(--color-text-primary);background:var(--color-bg-primary);font-size:0.75rem}" +
      ".cgt2-header{display:flex;align-items:center;gap:12px;padding:16px 16px 10px}" +
      ".cgt2-header-copy{flex:1;min-width:0}" +
      ".cgt2-title{font-size:0.9375rem;font-weight:680}" +
      ".cgt2-progress-text{margin-top:3px;color:var(--color-text-tertiary);font-size:0.6875rem}" +
      ".cgt2-sync{flex:none;margin:0;padding:6px 10px;font-size:0.6875rem;font-weight:600;border:1px solid var(--color-border-primary);border-radius:var(--radius-sm,6px);background:transparent;color:var(--color-text-secondary);cursor:pointer;transition:color var(--transition-fast),border-color var(--transition-fast)}" +
      ".cgt2-sync:hover{color:var(--color-text-primary);border-color:var(--color-border-strong)}" +
      ".cgt2-source{display:flex;align-items:center;gap:6px;padding:0 16px 12px;color:var(--color-text-tertiary);font-size:0.625rem}" +
      ".cgt2-source-dot{width:6px;height:6px;background:var(--color-accent-primary);border-radius:50%;flex:none}" +
      ".cgt2-source-date{margin-left:auto}" +
      ".cgt2-content{display:flex;flex-direction:column;gap:10px;padding:0 12px 16px}" +
      ".cgt2-empty{padding:12px 14px;color:var(--color-text-secondary);background:var(--color-bg-subtle);border:1px solid var(--color-border-secondary);border-radius:var(--radius-md,8px);font-size:0.6875rem;line-height:1.5}" +
      ".cgt2-error{color:var(--color-error,#c0392b)}" +
      ".cgt2-course{overflow:hidden;background:var(--color-bg-card);border:1px solid var(--color-border-primary);border-radius:var(--radius-lg,10px)}" +
      ".cgt2-course-summary{display:flex;align-items:center;gap:10px;min-height:44px;padding:0 13px;cursor:pointer;list-style:none;user-select:none}" +
      ".cgt2-course-summary::-webkit-details-marker{display:none}" +
      ".cgt2-course-copy{display:flex;flex:1;align-items:center;gap:8px;min-width:0}" +
      ".cgt2-course-title{overflow:hidden;flex:1;font-size:0.75rem;font-weight:650;text-overflow:ellipsis;white-space:nowrap}" +
      ".cgt2-course-now{flex:none;font-size:0.5625rem;font-weight:700;color:var(--color-accent-primary);background:var(--color-accent-soft);border:1px solid color-mix(in srgb,var(--color-accent-primary) 24%,var(--color-border-primary));border-radius:999px;padding:0 6px;min-height:13px;display:inline-flex;align-items:center}" +
      ".cgt2-course-chevron{color:var(--color-text-tertiary);font-size:0.875rem;transition:transform var(--transition-fast)}" +
      ".cgt2-course[open] .cgt2-course-chevron,.cgt2-issue[open] .cgt2-course-chevron{transform:rotate(180deg)}" +
      ".cgt2-course-body{border-top:1px solid var(--color-border-secondary);padding:10px;display:flex;flex-direction:column;gap:8px}" +
      ".cgt2-status{display:flex;align-items:center;gap:8px;flex-wrap:wrap}" +
      ".cgt2-version{display:inline-flex;padding:0 8px;min-height:18px;align-items:center;border-radius:999px;font-size:0.625rem;font-weight:700;color:var(--color-accent-primary);background:var(--color-accent-soft);border:1px solid color-mix(in srgb,var(--color-accent-primary) 24%,var(--color-border-primary));transition:box-shadow .3s}" +
      ".cgt2-version.is-flash{box-shadow:0 0 0 3px color-mix(in srgb,var(--color-accent-primary) 35%,transparent)}" +
      ".cgt2-prepbar{display:flex;align-items:center;gap:3px;flex-wrap:wrap}" +
      ".cgta-dot{font-size:0.5625rem;padding:1px 5px;border-radius:999px;border:1px solid var(--color-border-secondary);color:var(--color-text-tertiary)}" +
      ".cgta-dot.is-done{color:var(--color-success,#34d399);border-color:var(--color-success,#34d399)}" +
      ".cgta-dot.is-current{color:var(--color-accent-primary);border-color:var(--color-accent-primary);font-weight:700}" +
      ".cgta-sep{width:8px;height:1px;background:var(--color-border-secondary)}" +
      ".cgt2-goals{margin:0;padding:8px 10px;border-radius:var(--radius-md,8px);background:var(--color-bg-subtle);border:1px solid var(--color-border-secondary)}" +
      ".cgt2-goal{font-size:0.6875rem;line-height:1.6;color:var(--color-text-secondary)}" +
      ".cgt2-issue{overflow:hidden;background:var(--color-bg-card);border:1px solid var(--color-border-primary);border-radius:var(--radius-md,8px)}" +
      ".cgt2-issue-summary{display:flex;align-items:center;gap:8px;min-height:36px;padding:0 10px;cursor:pointer;list-style:none;user-select:none}" +
      ".cgt2-issue-summary::-webkit-details-marker{display:none}" +
      ".cgt2-issue-name{flex:1;min-width:0;font-weight:650;font-size:0.71875rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}" +
      ".cgt2-issue-count{flex:none;font-size:0.59375rem;color:var(--color-text-tertiary)}" +
      ".cgt2-issue-body{border-top:1px solid var(--color-border-secondary);padding:6px 10px}" +
      ".cgt2-obj{font-size:0.6875rem;color:var(--color-text-secondary);padding:3px 0}" +
      ".cgt2-continue{padding:14px;background:linear-gradient(135deg,color-mix(in srgb,var(--color-accent-primary) 12%,var(--color-bg-card)),var(--color-bg-card));border:1px solid color-mix(in srgb,var(--color-accent-primary) 20%,var(--color-border-primary));border-radius:var(--radius-lg,10px)}" +
      ".cgt2-eyebrow{color:var(--color-accent-primary);font-size:0.625rem;font-weight:700;letter-spacing:0.08em;text-transform:uppercase}" +
      ".cgt2-continue-title{margin-top:6px;font-size:0.875rem;font-weight:650;line-height:1.4}" +
      ".cgt2-continue-subtitle{margin-top:4px;color:var(--color-text-secondary);font-size:0.6875rem;line-height:1.45}" +
      ".cgt2-continue-button{margin:12px 0 0;padding:7px 12px;font-size:0.6875rem;font-weight:700;color:var(--color-bg-primary,#fff);background:var(--color-accent-primary);border:0;border-radius:var(--radius-sm,6px);cursor:pointer;transition:filter var(--transition-fast)}" +
      ".cgt2-continue-button:hover{filter:brightness(1.12)}" +
      ".cgt2-open{display:block;width:100%;margin-top:4px;padding:8px;border:1px dashed var(--color-border-primary);border-radius:var(--radius-sm,6px);background:transparent;color:var(--color-text-secondary);cursor:pointer;font-size:0.625rem;transition:color var(--transition-fast),border-color var(--transition-fast)}" +
      ".cgt2-open:hover{color:var(--color-text-primary);border-color:var(--color-border-strong)}" +
      "@media (max-width:720px){.cgt2-header{padding-inline:12px}.cgt2-source{padding-inline:12px}.cgt2-content{padding-inline:8px}}";
document.head.appendChild(css);
  }

  injectStyles();

  Clacky.ext.ui.mount("session.aside", function (container, ctx) {
    if (!ctx || ctx.agentProfile !== AGENT || !ctx.sessionId) return;

    root = document.createElement("div");
    root.className = "cgt2-root";
    container.appendChild(root);
    loadCourses();
    pollTimer = setInterval(async function () {
      if (!root || !document.contains(root) || document.hidden) return;
      const before = signature();
      await refreshDraft();
      if (signature() !== before) flashVersion();
    }, POLL_MS);
  }, {
    agents: [AGENT],
    order: 17,
    tab: {
      id: "cgc-2046-tutor-aside",
      label: function () { return "教研产出"; }
    }
  });

  // 信号订阅:草稿保存/工具完成 → 防抖拉最新(推拉结合)
  Clacky.ext.subscribe("ext.cgc-2046.draft_saved", scheduleRefresh);
  Clacky.ext.subscribe("ext.cgc-2046.tool_used", scheduleRefresh);
})();
