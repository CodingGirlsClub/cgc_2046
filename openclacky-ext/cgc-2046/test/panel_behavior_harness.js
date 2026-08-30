// advisor F1 行为级 harness：零成员身份 + confirmed 公开课报名 →
// /me/enrollments 无条件拉取 → 列表渲染该课程（DOM 断言，非字符串扫描）。
// 用法：node test/panel_behavior_harness.js <panel:view.js 路径> <场景>
// 场景 zero_member_confirmed（本测试用）/ 输出 JSON 到 stdout，非零退出 = 断言失败。
"use strict";

const viewPath = process.argv[2];
const scenario = process.argv[3] || "zero_member_confirmed";

// ---- DOM/宿主 stub（最小面，覆盖 view.js 触达面） ----
// 假元素支持 innerHTML 赋值 + 按 id 的 querySelector(学习中心按 id 挂子块)
function makeEl(tag) {
  const node = {
    tagName: tag, textContent: "", style: {},
    dataset: {}, className: "", listeners: {}, children: [], _html: "", _ids: {},
    addEventListener(type, fn) { (node.listeners[type] = node.listeners[type] || []).push(fn); },
    setAttribute(k, v) { node.dataset[k] = v; },
    getAttribute(k) { return node.dataset[k] || null; },
    appendChild(c) { node.children.push(c); return c; },
    contains() { return true; },
    scrollIntoView() {},
    classList: { add() {}, remove() {}, toggle() {} },
  };
  Object.defineProperty(node, "innerHTML", {
    // getter 聚合自身模板 + 子节点内容(view.js 按 id 挂数据后,断言在容器上取全文)
    get() {
      const kid = function (c) { return c.innerHTML; };
      return node._html + node.children.map(kid).join("") +
        Object.keys(node._ids).map(function (k) { return node._ids[k].innerHTML; }).join("");
    },
    set(v) {
      node._html = String(v); node.children = []; node._ids = {};
      // 提取 id="..." 生成可寻址子节点(view.js 渲染后按 id 挂数据)
      const re = /id="([^"]+)"/g; let m;
      while ((m = re.exec(node._html))) node._ids[m[1]] = makeEl("div");
    },
  });
  Object.defineProperty(node, "value", {
    get() { return node._value || ""; }, set(v) { node._value = String(v); },
  });
  node.querySelector = function (sel) {
    if (sel.startsWith("#")) {
      const id = sel.slice(1);
      node._ids[id] = node._ids[id] || makeEl("div");
      return node._ids[id];
    }
    return null;
  };
  node.querySelectorAll = function () { return []; };
  return node;
}
function el(tag) { return makeEl(tag); }

const calls = { fetches: [] };
const RESPONDERS = {
  "/api/ext/cgc-2046/learning_state?workspace_id=": null, // 占位说明:实际匹配按 path 前缀在 fetch stub 内处理
  "/api/ext/cgc-2046/me/workspaces": () => ({
    ok: true, status: 200, json: async () => ({ ok: true, result: { workspaces: [] } }),
  }),
  "/api/ext/cgc-2046/me/enrollments": () => ({
    ok: true, status: 200,
    json: async () => ({
      ok: true,
      result: {
        enrollments: [
          {
            id: "enr-1", kind: "course", status: "confirmed",
            offering: { id: "course-uuid-1", title: "零成员公开课", slug: "pub-101" },
            workspace: { id: "ws-uuid-9", name: "他台", slug: "other" },
          },
          { id: "enr-2", kind: "course", status: "pending",
            offering: { id: "course-uuid-2", title: "待审批课" }, workspace: { id: "ws-uuid-9", name: "他台" } },
        ],
      },
    }),
  }),
};

globalThis.window = globalThis;
globalThis.document = {
  hidden: false,
  createElement: el,
  getElementById() { return null; },
  querySelector() { return null; },
  querySelectorAll() { return []; },
  head: el("head"),
  body: el("body"),
  contains() { return true; },
};
const store = new Map();
globalThis.localStorage = {
  getItem: (k) => (store.has(k) ? store.get(k) : null),
  setItem: (k, v) => store.set(k, String(v)),
  removeItem: (k) => store.delete(k),
};
globalThis.fetch = async (url) => {
  const path = String(url).split("?")[0];
  calls.fetches.push(path);

  if (path.startsWith("/api/ext/cgc-2046/learning_state")) {
    return {
      ok: true, status: 200,
      json: async () => ({
        ok: true,
        result: {
          objectives: [
            { id: "obj-1", title: "零成员公开课", mastery: "developing", attempt_count: 0, required: true, locked: false, issue_id: "issue-1" }
          ],
          progress: { mastered_required: 0, total_required: 1, complete: false },
          next_action: { objective_id: "obj-1", reason: "从这里开始" },
          review_queue: []
        }
      })
    };
  }
  if (path.startsWith("/api/ext/cgc-2046/courses/") && path.endsWith("/content")) {
    return { ok: true, status: 200, json: async () => ({ ok: true, result: { version: 1, issues: [], course_title: "零成员公开课" } }) };
  }
  if (path.startsWith("/api/ext/cgc-2046/courses/") && path.endsWith("/revision")) {
    return { ok: true, status: 200, json: async () => ({ ok: true, result: null }) };
  }

  const r = RESPONDERS[path];
  if (!r) return { ok: false, status: 404, json: async () => ({}) };
  return r();
};
const timers = [];
globalThis.setInterval = (fn) => { timers.push(fn); return timers.length; };
globalThis.clearInterval = () => {};
globalThis.Clacky = {
  ext: {
    pure: false,
    ui: {
      registerWorkspace(id, spec) { globalThis.__registered = { id, spec }; },
      mount() {},
      openWorkspace() {},
    },
  },
};

require(require("path").resolve(viewPath));

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const { spec } = globalThis.__registered || {};
  if (!spec || typeof spec.render !== "function") {
    console.error("FAIL: registerWorkspace 未捕获 render");
    process.exit(1);
  }

  const container = el("div");
  spec.render(container);           // 首渲染 → boot() 异步启动
  await sleep(120);                  // 等 boot + loadCourses 完成（stub 网络即时）
  spec.render(container);           // boot 完成后的重渲染

  if (process.env.HARNESS_DEBUG) console.error("fetches: " + JSON.stringify(calls.fetches, null, 0));
  const html = container.innerHTML;
  const enrollmentsFetched = calls.fetches.includes("/api/ext/cgc-2046/me/enrollments");
  const workspacesFetched = calls.fetches.includes("/api/ext/cgc-2046/me/workspaces");

  const checks = {
    enrollments_fetched_without_membership: enrollmentsFetched && workspacesFetched,
    confirmed_course_visible: html.includes('data-testid="panel-course-select"') &&
      html.includes("零成员公开课"),
    learning_center_boot: html.includes('data-testid="panel-outline-tree"') &&
      html.includes('data-testid="panel-resume-btn"'),
    no_workspace_gate_blocking_list: !html.includes("没有可访问的 Workspace。请先在网站加入"),
  };

  const failed = Object.entries(checks).filter(([, v]) => !v);
  if (failed.length > 0) {
    console.error("FAIL: " + failed.map(([k]) => k).join(", "));
    console.error("html: " + html.slice(0, 800));
    process.exit(1);
  }
  console.log("OK " + scenario + " " + JSON.stringify(checks));
})().catch((e) => { console.error("FAIL harness: " + e.message); process.exit(1); });
