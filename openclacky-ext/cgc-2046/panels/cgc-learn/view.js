// CGC 会话伴学侧栏(learning companion,session.aside)。
//
// 挂载形态对齐 qingclaw-learning 先例:ext.yml 声明 attach: [cgc-assistant],
// 本文件 mount("session.aside", ..., { agents: ["cgc-assistant"], tab })——
// 仅在 CGC 助手会话的右侧出现,其它会话零渲染。
//
// 能力(青狮课堂体验的 CGC 版):
//   - 我的课程(confirmed 课程报名,跨 workspace,下拉切换);
//   - 学习状态:当前任务卡(next_action)+ 进度 + 待复习队列 + 目标地图
//     (四态徽章/先修锁/尝试次数,同课程页口径);
//   - 点目标 → 学习指令直接注入会话(#user-input 填值 + dispatch input +
//     点 #btn-send,qingclaw sendLessonPrompt 同款管道),零复制粘贴;
//   - 注入失败(找不到输入框)兜底:复制到剪贴板并提示。
//
// 指令文案与 panels/cgc-course/view.js 的 learningPrompt 同口径
// (objective_id + learner playbook 七步学习循环 / 到期复习口吻,
// 正式评价调 submit_learning_attempt)——测试锚钉两处同步的关键句。
//
// 安全红线:只渲染 loopback 透传数据,服务端字符串一律 escapeHtml。

(() => {
  "use strict";
  if (!window.Clacky || !Clacky.ext || Clacky.ext.pure) return;

  const API = "/api/ext/cgc-2046";
  const AGENT = "cgc-assistant";

  // ---- 状态(每次会话挂载时初始化) ----
  let root = null;
  let rerender = null;
  const state = {
    loading: true,
    error: null,
    courses: [],      // [{ courseId, title, workspaceId, workspaceName }]
    selected: null,   // 选中的 course 对象
    learning: null    // /learning_state result
  };

  function escapeHtml(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function toast(message) {
    if (Clacky.Modal && typeof Clacky.Modal.toast === "function") {
      Clacky.Modal.toast(message, "info");
    } else {
      console.info("[cgc-learn] " + message);
    }
  }

  // ---- 数据加载 ----
  async function apiGet(path) {
    const res = await fetch(API + path, { headers: { Accept: "application/json" } });
    const body = await res.json().catch(function () { return {}; });
    if (!res.ok) throw Object.assign(new Error(body.error || ("HTTP " + res.status)), { status: res.status });
    return body;
  }

  async function boot() {
    state.loading = true;
    state.error = null;
    rerender();
    try {
      const payload = await apiGet("/me/enrollments");
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
      state.selected = state.courses[0] || null;
      await loadLearning();
    } catch (e) {
      state.error = e;
      state.loading = false;
      rerender();
      return;
    }
  }

  async function loadLearning() {
    if (!state.selected) {
      state.learning = null;
      state.loading = false;
      rerender();
      return;
    }
    state.loading = true;
    rerender();
    try {
      const payload = await apiGet("/learning_state?workspace_id=" +
        encodeURIComponent(state.selected.workspaceId) +
        "&course_id=" + encodeURIComponent(state.selected.courseId));
      state.learning = payload.result || null;
      state.error = null;
    } catch (e) {
      // 未连接(503)与其它错误都收敛为面板内提示,不打扰会话
      state.learning = null;
      state.error = e;
    } finally {
      state.loading = false;
      rerender();
    }
  }

  // ---- 指令构造(与 cgc-course learningPrompt 同口径) ----
  function learningPrompt(objectiveId, reviewEntry) {
    const learning = state.learning || {};
    const obj = (learning.objectives || []).find(function (o) { return o.id === objectiveId; }) || {};
    const title = (state.selected && state.selected.title) || "本课程";
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

  // ---- 注入管道(qingclaw sendLessonPrompt 同款;失败兜底剪贴板) ----
  function injectPrompt(objectiveId, reviewEntry) {
    const text = learningPrompt(objectiveId, reviewEntry);
    const input = document.getElementById("user-input");
    const send = document.getElementById("btn-send");
    if (!input || !send) {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function () { toast("指令已复制,请粘贴到会话发送"); });
      } else {
        window.prompt("复制以下指令到会话开始学习:", text);
      }
      return;
    }
    // 宿主 #user-input 是 contenteditable DIV(非 textarea):必须写
    // textContent——value 赋值只是 expando 属性,Composer.text 读不到,
    // _sendMessage 会因内容为空直接 return(真机实证)
    input.textContent = text;
    input.dispatchEvent(new Event("input", { bubbles: true }));
    send.click();
    // 宿主在会话订阅确认前禁用发送按钮(app.js:btn-send disabled until
    // subscribe confirmed)——此时 click 无效,待启用后补发(5s 上限)
    if (send.disabled) {
      var timer = setInterval(function () {
        if (!send.disabled) {
          clearInterval(timer);
          send.click();
        }
      }, 200);
      setTimeout(function () { clearInterval(timer); }, 5000);
    }
  }

  // ---- 渲染 ----
  function masteryLabel(m) {
    if (m === "mastered") return "已掌握";
    if (m === "developing") return "学习中";
    if (m === "needs_review") return "待复习";
    return "未学";
  }

  function renderPanel() {
    let html =
      '<div class="cgc-learn-head">' +
        '<span class="cgc-learn-title">学习地图</span>' +
        '<button id="cgc-learn-refresh" class="cgc-btn cgc-btn-secondary cgc-btn-mini" type="button">刷新</button>' +
      '</div>';

    if (state.loading) {
      root.innerHTML = html + '<div class="cgc-empty">加载中…</div>';
      bind();
      return;
    }
    if (state.error) {
      root.innerHTML = html +
        '<div class="cgc-ev-err" data-testid="learn-error">加载失败:' +
        escapeHtml(String(state.error.message || state.error)) + '</div>';
      bind();
      return;
    }
    if (state.courses.length === 0) {
      root.innerHTML = html +
        '<div class="cgc-empty" data-testid="learn-empty">暂无在学课程。先在「CGC 发现」报名课程。</div>';
      bind();
      return;
    }

    const opts = state.courses.map(function (c) {
      const sel = state.selected && c.courseId === state.selected.courseId ? " selected" : "";
      return '<option value="' + escapeHtml(c.courseId) + '"' + sel + '>' +
             escapeHtml(c.title) + '</option>';
    }).join("");
    html += '<select id="cgc-learn-course" class="cgc-select">' + opts + '</select>';

    const learning = state.learning || {};
    const objectives = learning.objectives || [];
    const progress = learning.progress || {};
    const next = learning.next_action || null;

    html += '<div class="cgc-learn-progress">必修 ' +
      escapeHtml(progress.mastered_required || 0) + '/' + escapeHtml(progress.total_required || 0) +
      (progress.complete ? ' · 已结业' : '') + '</div>';

    if (next && next.objective_id) {
      html +=
        '<div class="cgc-learn-next" data-testid="learn-next">' +
          '<span class="cgc-badge cgc-badge-next">当前任务</span>' +
          '<span class="cgc-learn-next-text">' + escapeHtml(next.reason || next.objective_id) + '</span>' +
          '<button class="cgc-btn cgc-btn-primary cgc-btn-mini" type="button" data-inject="' +
            escapeHtml(next.objective_id) + '" data-testid="learn-next-cta">开始学</button>' +
        '</div>';
    }

    const reviewById = {};
    (learning.review_queue || []).forEach(function (entry) {
      if (entry && entry.objective_id != null) reviewById[String(entry.objective_id)] = entry;
    });
    (learning.review_queue || []).forEach(function (entry) {
      if (!entry || entry.objective_id == null) return;
      const urgent = entry.needs_review === true;
      const obj = (learning.objectives || []).find(function (o) { return o.id === entry.objective_id; }) || {};
      html +=
        '<div class="cgc-learn-review' + (urgent ? " cgc-learn-urgent" : "") + '"' +
          ' data-inject="' + escapeHtml(entry.objective_id) + '" data-review="1" data-testid="learn-review">' +
          (urgent ? "待复习恢复 · " : "复习到期 · ") + escapeHtml(obj.title || entry.objective_id) +
        '</div>';
    });

    if (objectives.length === 0) {
      html += '<div class="cgc-empty">该课程暂无学习目标(教研未完成或未发布)。</div>';
    } else {
      const rows = objectives.map(function (o) {
        const locked = !!o.locked;
        const missing = o.missing_prereq_ids || [];
        return (
          '<div class="cgc-learn-obj' + (locked ? " cgc-learn-locked" : "") + '"' +
            (locked ? "" : ' data-inject="' + escapeHtml(o.id) + '"') +
            ' data-testid="learn-obj" data-objective="' + escapeHtml(o.id) + '">' +
            '<span class="cgc-badge cgc-obj-' + escapeHtml(o.mastery) + '">' +
              escapeHtml(masteryLabel(o.mastery)) + '</span>' +
            '<span class="cgc-learn-obj-title">' + escapeHtml(o.title || o.id) + '</span>' +
            (locked
              ? '<span class="cgc-learn-lock">🔒</span>'
              : (o.attempt_count > 0 ? '<span class="cgc-learn-attempts">' + escapeHtml(o.attempt_count) + '次</span>' : "")) +
            (locked && missing.length > 0
              ? '<div class="cgc-learn-prereq">需先修:' +
                  escapeHtml(missing.map(function (m) { return m.title || m.id; }).join("、")) + '</div>'
              : "") +
          '</div>'
        );
      }).join("");
      html += '<div class="cgc-learn-list">' + rows + '</div>';
    }

    root.innerHTML = html;
    bind();
  }

  function bind() {
    const refresh = root.querySelector("#cgc-learn-refresh");
    if (refresh) refresh.addEventListener("click", boot);
    const course = root.querySelector("#cgc-learn-course");
    if (course) {
      course.addEventListener("change", function () {
        state.selected = state.courses.find(function (c) { return c.courseId === course.value; }) || null;
        loadLearning();
      });
    }
    root.querySelectorAll("[data-inject]").forEach(function (el) {
      el.addEventListener("click", function () {
        const id = el.getAttribute("data-inject");
        const review = el.getAttribute("data-review") === "1";
        injectPrompt(id, review ? reviewByIdFor(id) : null);
      });
    });
  }

  function reviewByIdFor(objectiveId) {
    const learning = state.learning || {};
    return (learning.review_queue || []).find(function (e) { return e && String(e.objective_id) === String(objectiveId); }) || null;
  }

  // ---- 样式(session.aside 窄栏,紧凑自包含) ----
  function injectStyles() {
    if (document.getElementById("cgc-learn-styles")) return;
    const css = document.createElement("style");
    css.id = "cgc-learn-styles";
    css.textContent =
      ".cgc-learn-head{display:flex;justify-content:space-between;align-items:center;margin-bottom:8px}" +
      ".cgc-learn-title{font-weight:600;font-size:13px}" +
      ".cgc-learn-head + .cgc-select, .cgc-select{width:100%;padding:4px 8px;border:1px solid rgba(128,128,128,.4);border-radius:6px;background:transparent;color:inherit;font-size:12px;margin-bottom:8px}" +
      ".cgc-learn-progress{font-size:12px;opacity:.7;margin-bottom:8px}" +
      ".cgc-learn-next{display:flex;gap:6px;align-items:center;flex-wrap:wrap;border:1px solid rgba(99,102,241,.4);border-radius:8px;padding:8px;margin-bottom:8px;font-size:12px}" +
      ".cgc-learn-next-text{flex:1;min-width:0}" +
      ".cgc-badge{font-size:10px;border:1px solid rgba(128,128,128,.4);border-radius:999px;padding:0 6px;flex:none}" +
      ".cgc-badge-next{color:#6366f1;border-color:#6366f1}" +
      ".cgc-learn-review{font-size:12px;color:#fbbf24;border:1px dashed rgba(251,191,36,.5);border-radius:6px;padding:5px 8px;margin-bottom:4px;cursor:pointer;box-shadow:inset 2px 0 0 #fbbf24}" +
      ".cgc-learn-urgent{color:#f87171;border-color:rgba(248,113,113,.5);box-shadow:inset 2px 0 0 #f87171}" +
      ".cgc-learn-list{display:flex;flex-direction:column;gap:2px}" +
      ".cgc-learn-obj{display:flex;gap:6px;align-items:baseline;padding:5px 4px;border-radius:6px;cursor:pointer;font-size:12px;flex-wrap:wrap}" +
      ".cgc-learn-obj:hover{background:rgba(127,127,127,.12)}" +
      ".cgc-learn-obj-title{flex:1;min-width:0;word-break:break-all}" +
      ".cgc-learn-locked{cursor:default;opacity:.6}" +
      ".cgc-learn-attempts{font-size:10px;opacity:.6;flex:none}" +
      ".cgc-learn-prereq{width:100%;font-size:11px;color:#f97316}" +
      ".cgc-obj-mastered{color:#34d399;border-color:#34d399}" +
      ".cgc-obj-developing{color:#fbbf24;border-color:#fbbf24}" +
      ".cgc-obj-needs_review{color:#f97316;border-color:#f97316}" +
      ".cgc-btn{display:inline-block;padding:4px 10px;border-radius:6px;font-size:12px;text-decoration:none;cursor:pointer;border:1px solid transparent}" +
      ".cgc-btn-secondary{background:transparent;border-color:rgba(128,128,128,.4);color:inherit}" +
      ".cgc-btn-primary{background:#6366f1;color:#fff}" +
      ".cgc-btn-mini{padding:2px 8px;font-size:11px}" +
      ".cgc-empty{opacity:.55;font-size:12px}" +
      ".cgc-ev-err{color:#c0392b;font-size:12px}";
    document.head.appendChild(css);
  }

  injectStyles();

  // 仅在 CGC 助手会话挂载(agents 过滤 + ctx 双保险,qingclaw 同款)
  Clacky.ext.ui.mount("session.aside", function (container, ctx) {
    if (!ctx || ctx.agentProfile !== AGENT || !ctx.sessionId) return;

    root = document.createElement("div");
    root.className = "cgc-learn-root";
    container.appendChild(root);
    rerender = renderPanel;

    boot();
  }, {
    agents: [AGENT],
    order: 15,
    tab: {
      id: "cgc-2046-learn",
      label: function () { return "学习地图"; }
    }
  });
})();
