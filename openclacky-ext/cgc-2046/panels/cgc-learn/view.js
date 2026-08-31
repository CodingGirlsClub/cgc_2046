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
    learning: null,   // /learning_state result
    content: null,    // /content result(材料数据源)
    lastRefresh: ""
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
      const [learningRes, contentRes] = await Promise.all([
        apiGet("/learning_state?workspace_id=" +
          encodeURIComponent(state.selected.workspaceId) +
          "&course_id=" + encodeURIComponent(state.selected.courseId)),
        apiGet("/courses/" + encodeURIComponent(state.selected.courseId) + "/content?workspace_id=" + encodeURIComponent(state.selected.workspaceId))
          .catch(function () { return { result: null }; })
      ]);
      state.learning = learningRes.result || null;
      state.content = contentRes.result || null;
      state.lastRefresh = new Date().toLocaleTimeString();
      state.error = null;
      state.lastRefresh = new Date().toLocaleTimeString();
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
  function objectiveTitle(objectiveId) {
    const o = ((state.learning || {}).objectives || []).find(function (x) { return x.id === objectiveId; });
    return o ? (o.title || o.id) : String(objectiveId);
  }

  // 从 content 中取指定 objective 的 materials(id → issue.objectives 匹配)
  function materialsOf(objectiveId) {
    const issues = (state.content && state.content.issues) || [];
    for (var i = 0; i < issues.length; i++) {
      var objs = issues[i].objectives || [];
      for (var j = 0; j < objs.length; j++) {
        if (String(objs[j].id) === String(objectiveId)) {
          return Array.isArray(objs[j].materials) ? objs[j].materials : [];
        }
      }
    }
    return [];
  }

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
    // _sendMessage 会因内容为空直接 return(真机实证)。
    // 注入保草稿(qingclaw 精髓 3):输入框已有内容追加为「我的补充问题」,
    // 不覆盖用户打到一半的话
    const draft = (input.textContent || "").trim();
    const finalText = draft && draft !== text
      ? text + "\n\n我的补充问题:\n" + draft
      : text;
    input.textContent = finalText;
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
    const _p = ((state.learning || {}).progress || {});
    const progressText = state.loading ? "" :
      "必修 " + (Number(_p.mastered_required) || 0) + "/" + (Number(_p.total_required) || 0) +
      ((_p.complete) ? " · 已结业" : "");

    let html =
      '<div class="cgla-header">' +
        '<div class="cgla-header-copy">' +
          '<div class="cgla-title">学习地图</div>' +
          '<div class="cgla-progress-text">' + escapeHtml(progressText) + '</div>' +
        '</div>' +
        '<button id="cgc-learn-refresh" class="cgla-sync" type="button">刷新</button>' +
      '</div>' +
      '<div class="cgla-source">' +
        '<span class="cgla-source-dot"></span><span>目标地图</span>' +
        (state.lastRefresh ? '<span class="cgla-source-date">' + escapeHtml(state.lastRefresh) + '</span>' : "") +
      '</div>' +
      '<div class="cgla-content">';

    if (state.loading) {
      root.innerHTML = html + '<div class="cgla-empty">加载中…</div></div>';
      bind();
      return;
    }
    if (state.error) {
      root.innerHTML = html + '<div class="cgla-empty cgla-error" data-testid="learn-error">加载失败:' +
        escapeHtml(String(state.error.message || state.error)) + '</div></div>';
      bind();
      return;
    }
    if (state.courses.length === 0) {
      root.innerHTML = html + '<div class="cgla-empty" data-testid="learn-empty">暂无在学课程。先在「CGC 发现」报名课程。</div></div>';
      bind();
      return;
    }

    // 课程折叠卡(details):多课程信息密度 > select;选中课程默认展开+标记
    html += state.courses.map(function (c) {
      const isSel = state.selected && c.courseId === state.selected.courseId;
      return (
        '<details class="cgla-course"' + (isSel ? " open" : "") + ' data-course="' + escapeHtml(c.courseId) + '">' +
          '<summary class="cgla-course-summary">' +
            '<span class="cgla-course-copy">' +
              '<span class="cgla-course-title">' + escapeHtml(c.title) + '</span>' +
              (isSel ? '<span class="cgla-course-now">当前</span>' : "") +
            '</span>' +
            '<span class="cgla-course-chevron">⌄</span>' +
          '</summary>' +
          '<div class="cgla-course-body" data-body="' + escapeHtml(c.courseId) + '"></div>' +
        '</details>'
      );
    }).join("");

    html += '</div>';

    // 选中课程的内容块(渲染后搬进对应卡 body)
    const learning = state.learning || {};
    const objectives = learning.objectives || [];
    const progress = learning.progress || {};
    const next = learning.next_action || null;

    let inner = "";
    const total = Number(progress.total_required) || 0;
    const done = Number(progress.mastered_required) || 0;
    const pct = total > 0 ? Math.round((done * 100) / total) : 0;
    inner += '<div class="cgla-progress"><div class="cgla-progress-bar"><div style="width:' + pct + '%"></div></div></div>';

    // Resume 置顶大卡(渐变+eyebrow;到期复习优先)
    const dueReview = (learning.review_queue || [])[0];
    const resume = (dueReview && dueReview.objective_id)
      ? { objectiveId: dueReview.objectiveId2 || dueReview.objective_id, label: "继续复习", reason: (dueReview.needs_review === true ? "待复习恢复" : "复习到期") }
      : (next && next.objective_id
          ? { objectiveId: next.objective_id, label: "继续学习", reason: next.reason || "" }
          : null);
    if (resume) {
      const objTitle = objectiveTitle(resume.objectiveId);
      let reason = resume.reason || "";
      reason = reason.replace(new RegExp("「" + objTitle.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "」", "g"), "").replace(/^[,，。:：\s]+|[,，。\s]+$/g, "").slice(0, 40);
      inner +=
        '<div class="cgla-continue" data-testid="learn-next">' +
          '<div class="cgla-eyebrow">' + escapeHtml(resume.label) + '</div>' +
          '<div class="cgla-continue-title">' + escapeHtml(objTitle) + '</div>' +
          (reason ? '<div class="cgla-continue-subtitle">' + escapeHtml(reason) + '</div>' : "") +
          '<button class="cgla-continue-button" type="button" data-inject="' +
            escapeHtml(resume.objectiveId) + '" data-testid="learn-next-cta">▶ 开始学习</button>' +
        '</div>';
    }

    // 复习队列
    (learning.review_queue || []).forEach(function (entry) {
      if (!entry || entry.objective_id == null) return;
      const urgent = entry.needs_review === true;
      const obj = (learning.objectives || []).find(function (o) { return o.id === entry.objective_id; }) || {};
      inner +=
        '<button class="cgla-review' + (urgent ? " cgla-urgent" : "") + '" type="button"' +
          ' data-inject="' + escapeHtml(entry.objective_id) + '" data-review="1" data-testid="learn-review">' +
          '<span class="review-tag">' + (urgent ? "待恢复" : "复习") + '</span>' +
          '<span class="review-title">' + escapeHtml(obj.title || entry.objective_id) + '</span>' +
          '<span class="review-go">▶</span>' +
        '</button>';
    });

    // 目标地图(掌握行中划线;锁定行 badge=🔒+右侧需先修)
    if (objectives.length === 0) {
      inner += '<div class="cgla-empty">该课程暂无学习目标(教研未完成或未发布)。</div>';
    } else {
      inner += '<div class="cgla-obj-list">' + objectives.map(function (o) {
        const locked = !!o.locked;
        const missing = o.missing_prereq_ids || [];
        const mats = materialsOf(o.id);
        const hasMats = mats.length > 0;
        return (
          '<div class="cgla-obj-wrap">' +
          '<div class="cgla-obj' + (locked ? " is-locked" : "") + (o.mastery === "mastered" ? " is-done" : "") + '"' +
            (locked ? "" : ' data-inject="' + escapeHtml(o.id) + '"') +
            ' data-testid="learn-obj" data-objective="' + escapeHtml(o.id) + '">' +
            '<span class="obj-badge ' + (locked ? "" : "obj-" + escapeHtml(o.mastery)) + '">' +
              escapeHtml(locked ? "🔒" : masteryLabel(o.mastery)) + '</span>' +
            '<span class="cgla-obj-title">' + escapeHtml(o.title || o.id) + '</span>' +
            (!locked && o.attempt_count > 0
              ? '<span class="cgla-attempts">' + escapeHtml(o.attempt_count) + '次</span>' : "") +
            (locked && missing.length > 0
              ? '<span class="cgla-prereq" title="' +
                  escapeHtml(missing.map(function (m) { return m.title || m.id; }).join("、")) + '">需先修</span>' : "") +
            (hasMats
              ? '<button class="cgla-obj-mats" type="button" data-mats="' + escapeHtml(o.id) + '"' +
                  ' data-testid="learn-obj-mats" title="查看学习材料(' + mats.length + '条)">📎</button>' : "") +
          '</div>' +
          '</div>'
        );
      }).join("") + '</div>';
    }

    root.innerHTML = html;

    // 搬运:内容块填入选中课程卡 body;课程卡渲染在 content 内
    const selBody = root.querySelector("[data-body='" + (state.selected ? state.selected.courseId : "") + "']");
    if (selBody) selBody.innerHTML = inner;

    bind();
  }

  function bind() {
    const refresh = root.querySelector("#cgc-learn-refresh");
    if (refresh) refresh.addEventListener("click", boot);
    root.querySelectorAll("[data-mats]").forEach(function (btn) {
      btn.addEventListener("click", function (e) {
        e.stopPropagation();
        const objId = btn.getAttribute("data-mats");
        const wrap = btn.closest(".cgla-obj-wrap");
        const existing = wrap.querySelector(".cgla-mats-panel");
        if (existing) { existing.remove(); return; }
        const mats = materialsOf(objId);
        const panel = document.createElement("div");
        panel.className = "cgla-mats-panel";
        panel.innerHTML = mats.map(function (m) {
          const ref = m.ref || "";
          return (
            '<div class="cgla-mat-item">' +
              '<span class="cgla-mat-title">' + escapeHtml(m.title || m.ref || "材料") + '</span>' +
              (ref ? ' <a href="' + escapeHtml(ref) + '" target="_blank" rel="noopener noreferrer" class="cgla-mat-ref">' +
                escapeHtml(ref.length > 30 ? ref.slice(0, 30) + "…" : ref) + '</a>' : "") +
            '</div>'
          );
        }).join("");
        wrap.appendChild(panel);
      });
    });
    root.querySelectorAll("[data-inject]").forEach(function (el) {
      el.addEventListener("click", function () {
        const id = el.getAttribute("data-inject");
        const review = el.getAttribute("data-review") === "1";
        injectPrompt(id, review ? reviewByIdFor(id) : null);
      });
    });
    // 点非选中课程卡 = 切课;选中卡 = 折叠/展开
    root.querySelectorAll(".cgla-course").forEach(function (d) {
      const cid = d.getAttribute("data-course");
      d.querySelector(".cgla-course-summary").addEventListener("click", function (e) {
        if (state.selected && cid === state.selected.courseId) return;
        e.preventDefault();
        const c = state.courses.find(function (x) { return x.courseId === cid; });
        if (c) { state.selected = c; loadLearning(); }
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
      ".cgla-root{min-height:100%;color:var(--color-text-primary);background:var(--color-bg-primary);font-size:0.75rem}" +
      ".cgla-header{display:flex;align-items:center;gap:12px;padding:16px 16px 10px}" +
      ".cgla-header-copy{flex:1;min-width:0}" +
      ".cgla-title{font-size:0.9375rem;font-weight:680}" +
      ".cgla-progress-text{margin-top:3px;color:var(--color-text-tertiary);font-size:0.6875rem}" +
      ".cgla-sync{flex:none;margin:0;padding:6px 10px;font-size:0.6875rem;font-weight:600;border:1px solid var(--color-border-primary);border-radius:var(--radius-sm,6px);background:transparent;color:var(--color-text-secondary);cursor:pointer;transition:color var(--transition-fast),border-color var(--transition-fast)}" +
      ".cgla-sync:hover{color:var(--color-text-primary);border-color:var(--color-border-strong)}" +
      ".cgla-source{display:flex;align-items:center;gap:6px;padding:0 16px 12px;color:var(--color-text-tertiary);font-size:0.625rem}" +
      ".cgla-source-dot{width:6px;height:6px;background:var(--color-accent-primary);border-radius:50%;flex:none}" +
      ".cgla-source-date{margin-left:auto}" +
      ".cgla-content{display:flex;flex-direction:column;gap:10px;padding:0 12px 16px}" +
      ".cgla-empty{padding:12px 14px;color:var(--color-text-secondary);background:var(--color-bg-subtle);border:1px solid var(--color-border-secondary);border-radius:var(--radius-md,8px);font-size:0.6875rem;line-height:1.5}" +
      ".cgla-error{color:var(--color-error,#c0392b)}" +
      ".cgla-course{overflow:hidden;background:var(--color-bg-card);border:1px solid var(--color-border-primary);border-radius:var(--radius-lg,10px)}" +
      ".cgla-course-summary{display:flex;align-items:center;gap:10px;min-height:44px;padding:0 13px;cursor:pointer;list-style:none;user-select:none}" +
      ".cgla-course-summary::-webkit-details-marker{display:none}" +
      ".cgla-course-copy{display:flex;flex:1;align-items:center;gap:8px;min-width:0}" +
      ".cgla-course-title{overflow:hidden;flex:1;font-size:0.75rem;font-weight:650;text-overflow:ellipsis;white-space:nowrap}" +
      ".cgla-course-now{flex:none;font-size:0.5625rem;font-weight:700;color:var(--color-accent-primary);background:var(--color-accent-soft);border:1px solid color-mix(in srgb,var(--color-accent-primary) 24%,var(--color-border-primary));border-radius:999px;padding:0 6px;min-height:13px;display:inline-flex;align-items:center}" +
      ".cgla-course-chevron{color:var(--color-text-tertiary);font-size:0.875rem;transition:transform var(--transition-fast)}" +
      ".cgla-course[open] .cgla-course-chevron{transform:rotate(180deg)}" +
      ".cgla-course-body{border-top:1px solid var(--color-border-secondary);padding:10px;display:flex;flex-direction:column;gap:8px}" +
      ".cgla-progress{height:4px;border-radius:2px;background:var(--color-bg-hover);overflow:hidden}" +
      ".cgla-progress-bar div{height:100%;background:var(--color-accent-primary);transition:width .4s ease}" +
      ".cgla-continue{padding:14px;background:linear-gradient(135deg,color-mix(in srgb,var(--color-accent-primary) 12%,var(--color-bg-card)),var(--color-bg-card));border:1px solid color-mix(in srgb,var(--color-accent-primary) 20%,var(--color-border-primary));border-radius:var(--radius-lg,10px)}" +
      ".cgla-eyebrow{color:var(--color-accent-primary);font-size:0.625rem;font-weight:700;letter-spacing:0.08em;text-transform:uppercase}" +
      ".cgla-continue-title{margin-top:6px;font-size:0.875rem;font-weight:650;line-height:1.4}" +
      ".cgla-continue-subtitle{margin-top:4px;color:var(--color-text-secondary);font-size:0.6875rem;line-height:1.45}" +
      ".cgla-continue-button{margin:12px 0 0;padding:7px 12px;font-size:0.6875rem;font-weight:700;color:var(--color-bg-primary,#fff);background:var(--color-accent-primary);border:0;border-radius:var(--radius-sm,6px);cursor:pointer;transition:filter var(--transition-fast)}" +
      ".cgla-continue-button:hover{filter:brightness(1.12)}" +
      ".cgla-review{display:flex;align-items:center;gap:8px;padding:6px 10px;font-size:0.6875rem;color:var(--color-warning,#fbbf24);border:1px dashed color-mix(in srgb,var(--color-warning,#fbbf24) 40%,var(--color-border-primary));border-radius:var(--radius-sm,6px);cursor:pointer;text-align:left;width:100%;font-family:inherit;background:transparent;transition:background var(--transition-fast)}" +
      ".cgla-review:hover{background:color-mix(in srgb,var(--color-warning,#fbbf24) 6%,transparent)}" +
      ".cgla-urgent{color:var(--color-error,#f87171);border-color:color-mix(in srgb,var(--color-error,#f87171) 40%,var(--color-border-primary))}" +
      ".review-tag{flex:none;font-size:0.59375rem;font-weight:700}" +
      ".review-title{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}" +
      ".review-go{flex:none;font-size:0.59375rem;opacity:.5}" +
      ".cgla-obj-list{display:flex;flex-direction:column}" +
      ".cgla-obj{display:flex;gap:8px;align-items:center;padding:8px 6px;border-bottom:1px solid var(--color-border-secondary);cursor:pointer;transition:background var(--transition-fast)}" +
      ".cgla-obj:last-child{border-bottom:0}" +
      ".cgla-obj:hover{background:var(--color-bg-hover)}" +
      ".cgla-obj.is-done .cgla-obj-title{text-decoration:line-through;color:var(--color-text-tertiary)}" +
      ".cgla-obj.is-locked{cursor:default;opacity:.5}" +
      ".cgla-obj.is-locked:hover{background:transparent}" +
      ".obj-badge{flex:none;font-size:0.5625rem;font-weight:700;padding:0 5px;min-height:14px;display:inline-flex;align-items:center;border-radius:999px;border:1px solid var(--color-border-secondary);color:var(--color-text-tertiary)}" +
      ".obj-mastered{color:var(--color-success,#34d399)!important;border-color:var(--color-success,#34d399)!important}" +
      ".obj-developing{color:var(--color-warning,#fbbf24)!important;border-color:var(--color-warning,#fbbf24)!important}" +
      ".obj-needs_review{color:var(--color-error,#f97316)!important;border-color:var(--color-error,#f97316)!important}" +
      ".cgla-obj-title{flex:1;min-width:0;word-break:break-all;line-height:1.4;font-size:0.71875rem;font-weight:580}" +
      ".cgla-attempts{flex:none;font-size:0.5625rem;color:var(--color-text-tertiary)}" +
      ".cgla-obj-wrap{position:relative}" +
      ".cgla-obj-mats{flex:none;width:18px;height:18px;display:inline-flex;align-items:center;justify-content:center;border:0;border-radius:4px;background:transparent;color:var(--color-text-muted);font-size:0.625rem;cursor:pointer;opacity:0;transition:opacity var(--transition-fast),color var(--transition-fast)}" +
      ".cgla-obj:hover .cgla-obj-mats{opacity:1}" +
      ".cgla-obj-mats:hover{color:var(--color-accent-primary);background:var(--color-accent-soft)}" +
      ".cgla-mats-panel{padding:6px 10px 6px 28px;border-top:1px dashed var(--color-border-secondary);background:var(--color-bg-subtle)}" +
      ".cgla-mat-item{display:flex;gap:6px;align-items:baseline;padding:2px 0;font-size:0.625rem}" +
      ".cgla-mat-title{color:var(--color-text-primary);flex:none}" +
      ".cgla-mat-ref{color:var(--color-accent-primary);text-decoration:none;word-break:break-all}" +
      ".cgla-mat-ref:hover{text-decoration:underline}" +
      ".cgla-prereq{flex:none;font-size:0.5625rem;color:var(--color-warning,#f97316)}" +
      "@media (max-width:720px){.cgla-header{padding-inline:12px}.cgla-source{padding-inline:12px}.cgla-content{padding-inline:8px}}";
document.head.appendChild(css);
  }

  injectStyles();

  // 仅在 CGC 助手会话挂载(agents 过滤 + ctx 双保险,qingclaw 同款)
  Clacky.ext.ui.mount("session.aside", function (container, ctx) {
    if (!ctx || ctx.agentProfile !== AGENT || !ctx.sessionId) return;

    root = document.createElement("div");
    root.className = "cgla-root";
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
