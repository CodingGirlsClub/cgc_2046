// advisor F1 行为级 harness：零成员身份 + confirmed 公开课报名 →
// /me/enrollments 无条件拉取 → 列表渲染该课程（DOM 断言，非字符串扫描）。
// 用法：node test/panel_behavior_harness.js <panel:view.js 路径> <场景>
// 场景 zero_member_confirmed（本测试用）/ 输出 JSON 到 stdout，非零退出 = 断言失败。
"use strict";

const viewPath = process.argv[2];
const scenario = process.argv[3] || "zero_member_confirmed";

// ---- DOM/宿主 stub（最小面，覆盖 view.js 触达面） ----
function el(tag) {
  return {
    tagName: tag, innerHTML: "", textContent: "", style: {},
    dataset: {}, className: "", listeners: {},
    addEventListener() {}, setAttribute() {}, getAttribute() { return null; },
    appendChild() {}, querySelector() { return null; }, querySelectorAll() { return []; },
    contains() { return true; },
  };
}

const calls = { fetches: [] };
const RESPONDERS = {
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

  const html = container.innerHTML;
  const enrollmentsFetched = calls.fetches.includes("/api/ext/cgc-2046/me/enrollments");
  const workspacesFetched = calls.fetches.includes("/api/ext/cgc-2046/me/workspaces");

  const checks = {
    enrollments_fetched_without_membership: enrollmentsFetched && workspacesFetched,
    confirmed_course_visible: html.includes('data-testid="panel-course"') && html.includes("零成员公开课"),
    row_carries_enrollment_workspace_scope: html.includes('data-ws="ws-uuid-9"'),
    in_flight_section_rendered: html.includes('data-testid="panel-inflight"') && html.includes("待审批课"),
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
