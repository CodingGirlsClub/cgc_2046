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

  async function refreshDraft(force) {
    if (!state.selectedCourseId) {
      state.loading = false;
      renderPanel();
      return;
    }
    const before = signature();
    // 菜单打开时跳过非强制刷新(重渲染会清掉行内菜单的 DOM)
    if (!force && root && root.querySelector(".cgta-rewrite-menu")) return;
    try {
      const ws = scopeOf();
      const [contentRes, prepRes] = await Promise.all([
        rawGet("/courses/" + encodeURIComponent(state.selectedCourseId) + "/content?workspace_id=" + encodeURIComponent(ws))
          .catch(function () { return { result: null }; }),
        rawGet("/courses/" + encodeURIComponent(state.selectedCourseId) + "/prep?workspace_id=" + encodeURIComponent(ws))
          .catch(function () { return { result: null }; })
      ]);
      state.prevContent = state.content;  // 旧 content 存下来供 issue 改动 diff
      state.content = contentRes.result || null;
      state.prep = (prepRes.result || null);
      state.lastRefresh = new Date().toLocaleTimeString();
      state.error = null;
      // 数据没变不重渲染(轮询/事件刷新不闪、不打断交互)
      if (!force && signature() === before) { state.loading = false; return; }
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

  // ---- 质量报告摘要卡(#5):quality_check/review 态显示 score/阈值/违规 ----
  function qualityReportCard() {
    const prep = state.prep || {};
    const st = prep.prep_state;
    if (st !== "quality_check" && st !== "review") return "";

    const report = prep.latest_quality_report;
    const violations = Array.isArray(prep.gate_violations) ? prep.gate_violations : [];
    const policy = prep.policy || {};
    const threshold = policy.quality_threshold;

    let html =
      '<div class="cgta-quality" data-testid="cgta-quality">' +
        '<div class="cgta-quality-head">';
    if (report) {
      const score = report.score;
      const passed = threshold != null ? score >= threshold : (report.outcome === "passed" || report.outcome === "pass");
      html +=
        '<span class="cgta-quality-score-group">' +
          '<span class="cgta-quality-score-label">质量评分</span>' +
          '<span class="cgta-quality-score ' + (passed ? "is-pass" : "is-fail") + '">' +
            escapeHtml(String(score)) + '</span>' +
          '<span class="cgta-quality-sep">/ 100</span>' +
        '</span>' +
        '<span class="cgta-quality-threshold">及格线 ' + escapeHtml(String(threshold != null ? threshold : 80)) + '</span>' +
        '<span class="cgta-quality-badge ' + (passed ? "is-pass" : "is-fail") + '">' +
          (passed ? "达标 ✓" : "未达标 ✗") + '</span>';
    } else {
      html += '<span class="cgta-quality-pending">等待质量报告…</span>';
    }
    html += '</div>';

    if (violations.length > 0) {
      html +=
        '<div class="cgta-quality-violations">' +
          '<span class="cgta-quality-violations-label">违规 ' + violations.length + ' 项:</span>' +
          violations.slice(0, 3).map(function (v) {
            return '<div class="cgta-quality-violation">· ' + escapeHtml(String(v)) + '</div>';
          }).join("") +
          (violations.length > 3
            ? '<div class="cgta-quality-violation">…共 ' + violations.length + ' 项</div>' : "") +
        '</div>';
    }

    if (report && report.summary) {
      html += '<div class="cgta-quality-summary">' + escapeHtml(report.summary.slice(0, 120)) + '</div>';
    }

    if (st === "review") {
      html +=
        '<button class="cgta-quality-cta" type="button" data-goto-review>→ 去工作台审核发布</button>';
    }
    html += '</div>';
    return html;
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
      '<div class="cgta-header">' +
        '<div class="cgta-header-copy">' +
          '<div class="cgta-title">教研产出</div>' +
          '<div class="cgta-progress-text">' +
            (_prep ? escapeHtml(PREP_LABELS[_prep] || _prep) : "草稿") +
            ' · ' + goalsLen + ' 目标 · ' + issuesLen + ' 单元' +
          '</div>' +
        '</div>' +
        '<button id="cgta-refresh" class="cgta-sync" type="button">刷新</button>' +
      '</div>' +
      '<div class="cgta-source">' +
        '<span class="cgta-source-dot"></span><span>草稿树</span>' +
        (state.lastRefresh ? '<span class="cgta-source-date">' + escapeHtml(state.lastRefresh) + '</span>' : "") +
      '</div>' +
      '<div class="cgta-content">';

    if (state.loading) {
      root.innerHTML = html + '<div class="cgta-empty">加载中…</div></div>';
      bindHead();
      return;
    }
    if (state.error) {
      root.innerHTML = html + '<div class="cgta-empty cgta-error">加载失败:' + escapeHtml(state.error.message || "") + '</div></div>';
      bindHead();
      return;
    }
    if (!state.courses.length) {
      root.innerHTML = html + '<div class="cgta-empty">暂无 confirmed 课程报名。</div></div>';
      bindHead();
      return;
    }

    // 课程折叠卡(details):选中默认展开+「当前」pill;点非选中卡=切课
    html += state.courses.map(function (c) {
      const isSel = c.courseId === state.selectedCourseId;
      return (
        '<details class="cgta-course"' + (isSel ? " open" : "") + ' data-course="' + escapeHtml(c.courseId) + '">' +
          '<summary class="cgta-course-summary">' +
            '<span class="cgta-course-copy">' +
              '<span class="cgta-course-title">' + escapeHtml(c.title) + '</span>' +
              (isSel ? '<span class="cgta-course-now">当前</span>' : "") +
            '</span>' +
            '<span class="cgta-course-chevron">⌄</span>' +
          '</summary>' +
          '<div class="cgta-course-body" data-body="' + escapeHtml(c.courseId) + '"></div>' +
        '</details>'
      );
    }).join("");
    html += '</div>';

    // 选中课程内容块(渲染后搬进卡 body)
    let inner = "";
    const c = state.content;
    const v = c && Number.isInteger(c.version) ? c.version : null;
    const isNew = v === 0 && goalsLen === 0 && issuesLen === 0;
    inner += '<div class="cgta-status">' +
      (v !== null
        ? '<span class="cgta-version" data-version-badge>' + (isNew ? "新课程" : "草稿 v" + escapeHtml(v)) + '</span>'
        : '<span class="cgta-version">无草稿</span>') +
      '<span class="cgta-prepbar">' + prepDots() + '</span>' +
    '</div>';

    inner += qualityReportCard();

    if (isNew) {
      inner += '<div class="cgta-continue">' +
        '<div class="cgta-eyebrow">开始共创</div>' +
        '<div class="cgta-continue-title">这门课还没有任何内容</div>' +
        '<div class="cgta-continue-subtitle">点下面的按钮,让教研助手从零生成初稿</div>' +
        '<button class="cgta-continue-button" type="button" data-cocreate>✦ 让助手开始生成</button>' +
      '</div>';
    } else if (c) {
      if (goalsLen) {
        inner += '<div class="cgta-goals">' + (c.goals || []).map(function (g) {
          return '<div class="cgta-goal">· ' + escapeHtml(g) + '</div>';
        }).join("") + '</div>';
      }
      // 展开态:localStorage 记忆(用户手动展开过的 issue id);agent 改动的
      // issue 自动展开+高亮(对比新旧 content 的 issue 内容 hash)
      const openIssues = {};
      try {
        JSON.parse(localStorage.getItem("cgc2046.tutorAside.openIssues") || "{}")
          .forEach(function (id) { openIssues[id] = true; });
      } catch (_e) {}
      // agent 改动检测:比较新旧 issues 的 objectives 数量/materials 数量/rubric 数量
      const changedIssues = {};
      if (state.prevContent && state.prevContent.issues && c.issues) {
        const prevMap = {};
        (state.prevContent.issues || []).forEach(function (i) { prevMap[i.id] = i; });
        (c.issues || []).forEach(function (cur) {
          const prev = prevMap[cur.id];
          if (!prev) { changedIssues[cur.id] = true; return; } // 新增
          const cnt = function (iss) {
            return ((iss.objectives || []).map(function (o) {
              return ((o.materials || []).length) + ":" + ((o.rubric || []).length);
            }).join(","));
          };
          if (cnt(prev) !== cnt(cur)) changedIssues[cur.id] = true;
        });
      }

      inner += (c.issues || []).map(function (issue) {
        const objs = (issue.objectives || []);
        const isOpen = openIssues[issue.id] || changedIssues[issue.id];
        return (
          '<details class="cgta-issue' + (changedIssues[issue.id] ? " is-changed" : "") + '"' +
            ' data-issue="' + escapeHtml(issue.id || "") + '"' +
            (isOpen ? " open" : "") + '>' +
            '<summary class="cgta-issue-summary">' +
              '<span class="cgta-issue-name">' + escapeHtml(issue.title || issue.id) + '</span>' +
              '<span class="cgta-issue-count">' + objs.length + ' 目标</span>' +
              '<span class="cgta-course-chevron">⌄</span>' +
            '</summary>' +
            '<div class="cgta-issue-body">' + objs.map(function (o) {
              return (
                '<div class="cgta-obj">' +
                  '<span class="cgta-obj-title">· ' + escapeHtml(o.title || o.id) + '</span>' +
                  '<button class="cgta-obj-edit" type="button" data-rewrite="' + escapeHtml(o.id) +
                    '" data-issue="' + escapeHtml(issue.id || "") +
                    '" data-title="' + escapeHtml(o.title || o.id) + '" title="定向重写这个目标">✎</button>' +
                '</div>'
              );
            }).join("") + '</div>' +
          '</details>'
        );
      }).join("");
    } else {
      inner += '<div class="cgta-empty">暂无草稿(新课程,等待助手生成或手动创建)</div>';
    }
    inner += '<button id="cgta-open-workbench" class="cgta-open" type="button">在教研工作台打开 →</button>';

    root.innerHTML = html;
    const selBody = root.querySelector("[data-body='" + state.selectedCourseId + "']");
    if (selBody) selBody.innerHTML = inner;

    bindHead();
    const sel2 = root.querySelector(".cgta-course");
    // 绑定非选中卡 = 切课;选中卡 = 折叠
    root.querySelectorAll(".cgta-course").forEach(function (d) {
      const cid = d.getAttribute("data-course");
      d.querySelector(".cgta-course-summary").addEventListener("click", function (e) {
        if (cid === state.selectedCourseId) return;
        e.preventDefault();
        state.selectedCourseId = cid;
        localStorage.setItem("cgc2046.curriculum.courseId", cid);
        refreshDraft();
      });
    });
    const gotoReview = root.querySelector("[data-goto-review]");
    if (gotoReview) gotoReview.addEventListener("click", function () {
      Clacky.ext.ui.openWorkspace("cgc-2046-curriculum");
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
    // 用户手动展开/收起 issue → localStorage 记忆(跨刷新保持)
    root.querySelectorAll(".cgta-issue").forEach(function (d) {
      d.addEventListener("toggle", function () {
        const ids = Array.from(root.querySelectorAll(".cgta-issue[open]"))
          .map(function (d2) { return d2.getAttribute("data-issue"); })
          .filter(Boolean);
        try { localStorage.setItem("cgc2046.tutorAside.openIssues", JSON.stringify(ids)); } catch (_e) {}
      });
    });

    // 局部 AI 动作:✎ 定向重写(位置自动携带,tutor 只说改成什么)
    root.querySelectorAll("[data-rewrite]").forEach(function (btn) {
      btn.addEventListener("click", function (e) {
        e.stopPropagation();
        const row = btn.closest(".cgta-obj");
        const objId = btn.getAttribute("data-rewrite");
        const issueId = btn.getAttribute("data-issue");
        const objTitle = btn.getAttribute("data-title");

        // 行内菜单:展开/收起 toggle(同一时间只展开一个)
        const existing = root.querySelector(".cgta-rewrite-menu");
        if (existing) existing.remove();
        if (row.dataset.menuOpen === "1") { delete row.dataset.menuOpen; return; }
        root.querySelectorAll(".cgta-obj").forEach(function (r2) { delete r2.dataset.menuOpen; });
        row.dataset.menuOpen = "1";
        row.classList.add("is-target");

        const menu = document.createElement("div");
        menu.className = "cgta-rewrite-menu";
        menu.innerHTML =
          '<button type="button" data-verb="rewrite">↻ 重写<span>替换全部内容</span></button>' +
          '<button type="button" data-verb="extend">＋ 扩展<span>在现有基础上补充</span></button>' +
          '<button type="button" data-verb="cancel">× 放弃</button>';
        row.parentElement.insertBefore(menu, row.nextSibling);

        menu.addEventListener("click", function (e2) {
          const v = e2.target.closest("[data-verb]");
          if (!v) return;
          menu.remove();
          row.classList.remove("is-target");
          delete row.dataset.menuOpen;
          const verb = v.getAttribute("data-verb");
          if (verb === "cancel") return;
          injectRewrite(objId, issueId, objTitle,
            verb === "rewrite" ? "重写(替换该目标全部内容)" : "扩展(在现有基础上补充)");
        });
      });
    });
  }

  // 定向重写指令:位置(objective_id + issue)自动携带,tutor 只补「改成什么」
  function injectRewrite(objId, issueId, objTitle, verb) {
    const course = state.courses.find(function (c) { return c.courseId === state.selectedCourseId; }) || {};
    const title = course.title || "当前课程";
    const instruction = [
      "请" + verb + "课程《" + title + "》学习单元中的目标「" + objTitle + "」。",
      "(course_id: " + state.selectedCourseId + ", workspace_id: " + scopeOf() +
        (issueId ? ", issue_id: " + issueId : "") + ", objective_id: " + objId + ")",
      "要求:",
      "- 先 get_course_content 确认该目标的当前内容;",
      "- 只修改这一个目标(" + (true ? "保持 objective_id 不变" : "") + "),其它目标/单元一律不动;",
      "- " + (verb.indexOf("重写") >= 0
          ? "整体重写该目标的 activity/assessment/materials/rubric;"
          : "在现有内容基础上补充,不删除已有内容;") + "- 保存后汇报变更摘要。",
      "我的修改意图是:(请等我描述)"
    ].join("\n");
    createTutorSession(instruction);
  }

  function createTutorSession(instruction) {
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
      window.prompt("复制以下指令到教研会话:", text);
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
      ".cgta-root{min-height:100%;color:var(--color-text-primary);background:var(--color-bg-primary);font-size:0.75rem}" +
      ".cgta-header{display:flex;align-items:center;gap:12px;padding:16px 16px 10px}" +
      ".cgta-header-copy{flex:1;min-width:0}" +
      ".cgta-title{font-size:0.9375rem;font-weight:680}" +
      ".cgta-progress-text{margin-top:3px;color:var(--color-text-tertiary);font-size:0.6875rem}" +
      ".cgta-sync{flex:none;margin:0;padding:6px 10px;font-size:0.6875rem;font-weight:600;border:1px solid var(--color-border-primary);border-radius:var(--radius-sm,6px);background:transparent;color:var(--color-text-secondary);cursor:pointer;transition:color var(--transition-fast),border-color var(--transition-fast)}" +
      ".cgta-sync:hover{color:var(--color-text-primary);border-color:var(--color-border-strong)}" +
      ".cgta-source{display:flex;align-items:center;gap:6px;padding:0 16px 12px;color:var(--color-text-tertiary);font-size:0.625rem}" +
      ".cgta-source-dot{width:6px;height:6px;background:var(--color-accent-primary);border-radius:50%;flex:none}" +
      ".cgta-source-date{margin-left:auto}" +
      ".cgta-content{display:flex;flex-direction:column;gap:10px;padding:0 12px 16px}" +
      ".cgta-empty{padding:12px 14px;color:var(--color-text-secondary);background:var(--color-bg-subtle);border:1px solid var(--color-border-secondary);border-radius:var(--radius-md,8px);font-size:0.6875rem;line-height:1.5}" +
      ".cgta-error{color:var(--color-error,#c0392b)}" +
      ".cgta-course{overflow:hidden;background:var(--color-bg-card);border:1px solid var(--color-border-primary);border-radius:var(--radius-lg,10px)}" +
      ".cgta-course-summary{display:flex;align-items:center;gap:10px;min-height:44px;padding:0 13px;cursor:pointer;list-style:none;user-select:none}" +
      ".cgta-course-summary::-webkit-details-marker{display:none}" +
      ".cgta-course-copy{display:flex;flex:1;align-items:center;gap:8px;min-width:0}" +
      ".cgta-course-title{overflow:hidden;flex:1;font-size:0.75rem;font-weight:650;text-overflow:ellipsis;white-space:nowrap}" +
      ".cgta-course-now{flex:none;font-size:0.5625rem;font-weight:700;color:var(--color-accent-primary);background:var(--color-accent-soft);border:1px solid color-mix(in srgb,var(--color-accent-primary) 24%,var(--color-border-primary));border-radius:999px;padding:0 6px;min-height:13px;display:inline-flex;align-items:center}" +
      ".cgta-course-chevron{color:var(--color-text-tertiary);font-size:0.875rem;transition:transform var(--transition-fast)}" +
      ".cgta-course[open] .cgta-course-chevron,.cgta-issue[open] .cgta-course-chevron{transform:rotate(180deg)}" +
      ".cgta-course-body{border-top:1px solid var(--color-border-secondary);padding:10px;display:flex;flex-direction:column;gap:8px}" +
      ".cgta-status{display:flex;align-items:center;gap:8px;flex-wrap:wrap}" +
      ".cgta-version{display:inline-flex;padding:0 8px;min-height:18px;align-items:center;border-radius:999px;font-size:0.625rem;font-weight:700;color:var(--color-accent-primary);background:var(--color-accent-soft);border:1px solid color-mix(in srgb,var(--color-accent-primary) 24%,var(--color-border-primary));transition:box-shadow .3s}" +
      ".cgta-version.is-flash{box-shadow:0 0 0 3px color-mix(in srgb,var(--color-accent-primary) 35%,transparent)}" +
      ".cgta-prepbar{display:flex;align-items:center;gap:3px;flex-wrap:wrap}" +
      ".cgta-dot{font-size:0.5625rem;padding:1px 5px;border-radius:999px;border:1px solid var(--color-border-secondary);color:var(--color-text-tertiary)}" +
      ".cgta-dot.is-done{color:var(--color-success,#34d399);border-color:var(--color-success,#34d399)}" +
      ".cgta-dot.is-current{color:var(--color-accent-primary);border-color:var(--color-accent-primary);font-weight:700}" +
      ".cgta-sep{width:8px;height:1px;background:var(--color-border-secondary)}" +
      ".cgta-goals{margin:0;padding:8px 10px;border-radius:var(--radius-md,8px);background:var(--color-bg-subtle);border:1px solid var(--color-border-secondary)}" +
      ".cgta-goal{font-size:0.6875rem;line-height:1.6;color:var(--color-text-secondary)}" +
      ".cgta-issue{overflow:hidden;background:var(--color-bg-card);border:1px solid var(--color-border-primary);border-radius:var(--radius-md,8px)}" +
      ".cgta-issue.is-changed{border-color:color-mix(in srgb,var(--color-accent-primary) 35%,var(--color-border-primary));box-shadow:inset 2px 0 0 var(--color-accent-primary)}" +
      ".cgta-issue-summary{display:flex;align-items:center;gap:8px;min-height:36px;padding:0 10px;cursor:pointer;list-style:none;user-select:none}" +
      ".cgta-issue-summary::-webkit-details-marker{display:none}" +
      ".cgta-issue-name{flex:1;min-width:0;font-weight:650;font-size:0.71875rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}" +
      ".cgta-issue-count{flex:none;font-size:0.59375rem;color:var(--color-text-tertiary)}" +
      ".cgta-issue-body{border-top:1px solid var(--color-border-secondary);padding:6px 10px}" +
      ".cgta-obj{display:flex;align-items:center;gap:6px;font-size:0.6875rem;color:var(--color-text-secondary);padding:3px 0}" +
      ".cgta-obj-title{flex:1;min-width:0}" +
      ".cgta-obj-edit{flex:none;width:20px;height:20px;display:inline-flex;align-items:center;justify-content:center;border:0;border-radius:4px;background:transparent;color:var(--color-text-muted);font-size:0.6875rem;cursor:pointer;opacity:0;transition:opacity var(--transition-fast),color var(--transition-fast)}" +
      ".cgta-obj:hover .cgta-obj-edit{opacity:1}" +
      ".cgta-obj-edit:hover{color:var(--color-accent-primary);background:var(--color-accent-soft)}" +
      ".cgta-obj.is-target{background:color-mix(in srgb,var(--color-accent-primary) 8%,transparent);border-radius:4px}" +
      ".cgta-rewrite-menu{display:flex;gap:6px;padding:6px 8px;border-radius:6px;background:var(--color-bg-card);border:1px solid color-mix(in srgb,var(--color-accent-primary) 30%,var(--color-border-primary));margin:2px 0 6px}" +
      ".cgta-rewrite-menu button{flex:1;display:flex;flex-direction:column;align-items:center;gap:2px;padding:6px 8px;border:1px solid var(--color-border-secondary);border-radius:6px;background:var(--color-bg-subtle);color:var(--color-text-primary);font-size:0.625rem;font-weight:650;cursor:pointer;font-family:inherit;transition:border-color var(--transition-fast),background var(--transition-fast)}" +
      ".cgta-rewrite-menu button:hover{border-color:var(--color-accent-primary);background:var(--color-accent-soft)}" +
      ".cgta-rewrite-menu button span{font-size:0.53125rem;font-weight:400;color:var(--color-text-tertiary)}" +
      ".cgta-rewrite-menu button[data-verb=cancel]{flex:none;color:var(--color-text-tertiary);border-style:dashed}" + +
      ".cgta-continue{padding:14px;background:linear-gradient(135deg,color-mix(in srgb,var(--color-accent-primary) 12%,var(--color-bg-card)),var(--color-bg-card));border:1px solid color-mix(in srgb,var(--color-accent-primary) 20%,var(--color-border-primary));border-radius:var(--radius-lg,10px)}" +
      ".cgta-eyebrow{color:var(--color-accent-primary);font-size:0.625rem;font-weight:700;letter-spacing:0.08em;text-transform:uppercase}" +
      ".cgta-continue-title{margin-top:6px;font-size:0.875rem;font-weight:650;line-height:1.4}" +
      ".cgta-continue-subtitle{margin-top:4px;color:var(--color-text-secondary);font-size:0.6875rem;line-height:1.45}" +
      ".cgta-continue-button{margin:12px 0 0;padding:7px 12px;font-size:0.6875rem;font-weight:700;color:var(--color-bg-primary,#fff);background:var(--color-accent-primary);border:0;border-radius:var(--radius-sm,6px);cursor:pointer;transition:filter var(--transition-fast)}" +
      ".cgta-continue-button:hover{filter:brightness(1.12)}" +
      ".cgta-open{display:block;width:100%;margin-top:4px;padding:8px;border:1px dashed var(--color-border-primary);border-radius:var(--radius-sm,6px);background:transparent;color:var(--color-text-secondary);cursor:pointer;font-size:0.625rem;transition:color var(--transition-fast),border-color var(--transition-fast)}" +
      ".cgta-open:hover{color:var(--color-text-primary);border-color:var(--color-border-strong)}" +
      ".cgta-quality{padding:12px;background:var(--color-bg-card);border:1px solid color-mix(in srgb,var(--color-warning,#fbbf24) 35%,var(--color-border-primary));border-radius:var(--radius-lg,10px)}" +
      ".cgta-quality-head{display:flex;align-items:baseline;gap:6px;flex-wrap:wrap}" +
      ".cgta-quality-score-group{display:flex;align-items:baseline;gap:3px}" +
      ".cgta-quality-score-label{font-size:0.59375rem;font-weight:650;color:var(--color-text-tertiary);margin-right:3px}" +
      ".cgta-quality-score{font-size:1.375rem;font-weight:720;letter-spacing:-0.03em;line-height:1}" +
      ".cgta-quality-threshold{font-size:0.59375rem;color:var(--color-text-tertiary);margin-left:auto;white-space:nowrap}" +
      ".cgta-quality-score.is-pass{color:var(--color-success,#34d399)}" +
      ".cgta-quality-score.is-fail{color:var(--color-error,#f87171)}" +
      ".cgta-quality-sep{font-size:0.6875rem;color:var(--color-text-tertiary)}" +
      ".cgta-quality-badge{display:inline-flex;padding:1px 8px;min-height:16px;align-items:center;border-radius:999px;font-size:0.59375rem;font-weight:700}" +
      ".cgta-quality-badge.is-pass{color:var(--color-success,#34d399);border:1px solid currentColor}" +
      ".cgta-quality-badge.is-fail{color:var(--color-error,#f87171);border:1px solid currentColor}" +
      ".cgta-quality-pending{font-size:0.6875rem;color:var(--color-text-tertiary)}" +
      ".cgta-quality-violations{margin-top:8px;font-size:0.625rem;line-height:1.5}" +
      ".cgta-quality-violations-label{font-weight:650;color:var(--color-warning,#fbbf24)}" +
      ".cgta-quality-violation{color:var(--color-text-secondary);padding-left:8px}" +
      ".cgta-quality-summary{margin-top:6px;font-size:0.59375rem;color:var(--color-text-tertiary);line-height:1.45}" +
      ".cgta-quality-cta{display:block;width:100%;margin-top:8px;padding:6px;border:0;border-radius:var(--radius-sm,6px);background:var(--color-accent-primary);color:var(--color-bg-primary,#fff);font-size:0.625rem;font-weight:700;cursor:pointer;font-family:inherit;transition:filter var(--transition-fast)}" +
      ".cgta-quality-cta:hover{filter:brightness(1.12)}" +
      "@media (max-width:720px){.cgta-header{padding-inline:12px}.cgta-source{padding-inline:12px}.cgta-content{padding-inline:8px}}";
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
