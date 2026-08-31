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
    let html =
      '<div class="cgta-head"><span class="cgta-title">教研产出</span>' +
        '<button id="cgta-refresh" class="cgta-mini" type="button">刷新</button></div>';

    if (state.loading) {
      root.innerHTML = html + '<div class="cgta-empty">加载中…</div>';
      bindHead();
      return;
    }
    if (state.error) {
      root.innerHTML = html + '<div class="cgta-err">加载失败:' + escapeHtml(state.error.message || "") + '</div>';
      bindHead();
      return;
    }
    if (!state.courses.length) {
      root.innerHTML = html + '<div class="cgta-empty">暂无 confirmed 课程报名。</div>';
      bindHead();
      return;
    }

    html += '<select id="cgta-course" class="cgta-select">' + state.courses.map(function (c) {
      const sel = c.courseId === state.selectedCourseId ? " selected" : "";
      return '<option value="' + escapeHtml(c.courseId) + '"' + sel + '>' + escapeHtml(c.title) + '</option>';
    }).join("") + '</select>';

    const v = state.content && Number.isInteger(state.content.version) ? state.content.version : null;
    html += '<div class="cgta-status">' +
      (v !== null ? '<span class="cgta-badge" data-version-badge>草稿 v' + escapeHtml(v) + '</span>' : '<span class="cgta-badge">无草稿</span>') +
      '<span class="cgta-prepbar">' + prepDots() + '</span></div>';

    html += draftTree();
    html += '<button id="cgta-open-workbench" class="cgta-open" type="button">在教研工作台打开 →</button>';

    root.innerHTML = html;
    bindHead();
    const sel = root.querySelector("#cgta-course");
    if (sel) sel.addEventListener("change", function () {
      state.selectedCourseId = sel.value;
      localStorage.setItem("cgc2046.curriculum.courseId", sel.value);
      refreshDraft();
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
    css.textContent = [
      ".cgta-root{padding:10px;font-size:12px;color:var(--color-text-primary)}",
      ".cgta-head{display:flex;justify-content:space-between;align-items:center;margin-bottom:8px}",
      ".cgta-title{font-weight:700;font-size:13px}",
      ".cgta-mini{padding:2px 8px;font-size:11px;border:1px solid var(--color-border-primary);border-radius:6px;background:transparent;color:inherit;cursor:pointer}",
      ".cgta-select{width:100%;padding:4px 8px;margin-bottom:8px;border:1px solid var(--color-border-primary);border-radius:6px;background:var(--color-bg-card);color:inherit;font-size:12px}",
      ".cgta-status{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:10px}",
      ".cgta-badge{display:inline-flex;padding:0 8px;min-height:18px;align-items:center;border-radius:999px;font-size:11px;font-weight:700;color:var(--color-accent-primary);background:var(--color-accent-soft);border:1px solid color-mix(in srgb,var(--color-accent-primary) 24%,var(--color-border-primary));transition:box-shadow .3s}",
      ".cgta-badge.is-flash{box-shadow:0 0 0 3px color-mix(in srgb,var(--color-accent-primary) 35%,transparent)}",
      ".cgta-prepbar{display:flex;align-items:center;gap:3px;flex-wrap:wrap}",
      ".cgta-dot{font-size:10px;padding:1px 5px;border-radius:999px;border:1px solid var(--color-border-secondary);color:var(--color-text-tertiary)}",
      ".cgta-dot.is-done{color:var(--color-success,#34d399);border-color:var(--color-success,#34d399)}",
      ".cgta-dot.is-current{color:var(--color-accent-primary);border-color:var(--color-accent-primary);font-weight:700}",
      ".cgta-sep{width:8px;height:1px;background:var(--color-border-secondary)}",
      ".cgta-goals{margin-bottom:8px;padding:6px 8px;border-radius:6px;background:var(--color-bg-subtle,rgba(127,127,127,.08))}",
      ".cgta-goal{font-size:11px;line-height:1.6;color:var(--color-text-secondary)}",
      ".cgta-issue{margin-bottom:8px}",
      ".cgta-issue-name{font-weight:650;font-size:12px;display:flex;justify-content:space-between;gap:6px}",
      ".cgta-count{font-size:10px;color:var(--color-text-tertiary);flex:none}",
      ".cgta-obj{font-size:11px;color:var(--color-text-secondary);padding:2px 0 2px 10px}",
      ".cgta-empty{color:var(--color-text-tertiary);font-size:12px;padding:6px 0}",
      ".cgta-err{color:var(--color-error,#c0392b);font-size:12px}",
      ".cgta-open{display:block;width:100%;margin-top:6px;padding:6px;border:1px dashed var(--color-border-primary);border-radius:6px;background:transparent;color:var(--color-text-secondary);cursor:pointer;font-size:11px}",
      ".cgta-open:hover{color:var(--color-text-primary);border-color:var(--color-border-strong)}"
    ].join("\n");
    document.head.appendChild(css);
  }

  injectStyles();

  Clacky.ext.ui.mount("session.aside", function (container, ctx) {
    if (!ctx || ctx.agentProfile !== AGENT || !ctx.sessionId) return;

    root = document.createElement("div");
    root.className = "cgta-root";
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
