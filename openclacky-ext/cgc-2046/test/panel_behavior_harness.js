// advisor F1 行为级 harness：零成员身份 + confirmed 公开课报名 →
// /me/enrollments 无条件拉取 → 列表渲染该课程（DOM 断言，非字符串扫描）。
// 用法：node test/panel_behavior_harness.js <panel:view.js 路径> <场景>
// 场景 zero_member_confirmed（本测试用）/ 输出 JSON 到 stdout，非零退出 = 断言失败。
"use strict";

const viewPath = process.argv[2];
const scenario = process.argv[3] || "zero_member_confirmed";

// #347 回归场景 editor_delimiter_roundtrip：含 /、| 分隔符的课程草稿经
// 「打开编辑 → 原样保存」往返，POST body 必须与原文 deep-equal（结构化逐项
// 输入消除分隔符解析;旧行格式下 given 被 split("/") 拆开、materials 标题/链接
// 错位——本场景在旧代码上必败）。
const ROUNDTRIP_ORIGINAL = {
  version: 3,
  course_title: "分隔符 | 压力课",
  goals: ["掌握 C/C++ 基础", "能读 HTTP/2 文档"],
  issues: [{
    id: "issue-1", kind: "handwork", title: "环境 | 配置",
    story: {
      as_a: "有 HTTP/2 经验的学员",
      given: ["熟悉 C/C++ 基础", "完成 读写/入门"],
      goal: "独立配置 a/b 环境",
      materials: [
        { title: "HTTP/2 | 图解", ref: "https://example.com/http2" },
        { title: "纯标题无链接", ref: "" }
      ],
      checklist: [
        { id: "c1", text: "配置 a/b 环境" },
        { id: "c2", text: "验证 C/C++ 编译" }
      ]
    }
  }]
};
let roundtripPosted = null;

// advisor F1 回归场景 editor_remove_row_with_empty:存在空行时点后续行的
// 删除钮,必须精确删掉该行(修复前 collectEditor 先过滤空行 → 索引错位删错)
const REMOVE_ORIGINAL = {
  version: 1,
  goals: ["目标一"],
  issues: [{
    id: "issue-1", kind: "handwork", title: "删除定位",
    story: {
      as_a: "", given: ["AAA", "BBB", "CCC"], goal: "",
      materials: [], checklist: [{ id: "c1", text: "验收一" }]
    }
  }]
};

// ---- DOM/宿主 stub（最小面，覆盖 view.js 触达面） ----
// 假元素支持 innerHTML 赋值 + 按 id 的 querySelector(学习中心按 id 挂子块);
// #347 编辑器场景扩展:渲染标记中的 value 回填(querySelector 拿到的输入
// 自带渲染值,等价用户未改动)、id 递归查找(编辑器挂在 #cgt-main 子树)、
// [data-edit-issue] 卡片解析(collectEditor 的 querySelectorAll 直读面)。
function unesc(s) {
  return String(s).replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, "&");
}
function extractValue(html, id) {
  const ta = new RegExp('<textarea[^>]*id="' + id + '"[^>]*>([\\s\\S]*?)</textarea>').exec(html);
  if (ta) return unesc(ta[1]);
  const inp = new RegExp('<input[^>]*id="' + id + '"[^>]*value="([^"]*)"').exec(html);
  if (inp) return unesc(inp[1]);
  return "";
}
function valueNode(v) { const n = makeEl("div"); n._value = unesc(v); return n; }
// 卡片片段内某 data-f 字段的全部输入值(data-f="X" 带右引号,不吃 given-item 前缀;
// input 取 value 属性,textarea 取内容——旧行格式编辑器走 textarea)
function fieldNodes(segment, field) {
  const re = new RegExp('data-f="' + field + '"[^>]*value="([^"]*)"', "g");
  const out = []; let m;
  while ((m = re.exec(segment))) out.push(valueNode(m[1]));
  const ta = new RegExp('<textarea[^>]*data-f="' + field + '"[^>]*>([\\s\\S]*?)</textarea>').exec(segment);
  if (ta) out.push(valueNode(ta[1]));
  return out;
}
// materials/checklist 行:按行标记切分,行内 querySelector 取子字段输入
function rowNodes(segment, rowAttr, fields) {
  return segment.split(rowAttr).slice(1).map(function (part) {
    const row = makeEl("div");
    row.querySelector = function (sel) {
      const fm = /^\[data-f='([^']+)'\]$/.exec(sel);
      if (fm && fields.indexOf(fm[1]) >= 0) return fieldNodes(part, fm[1])[0] || null;
      return null;
    };
    return row;
  });
}
function parseIssueCards(html) {
  const re = /data-edit-issue="(\d+)"/g;
  const marks = []; let m;
  while ((m = re.exec(html))) marks.push({ idx: m[1], pos: m.index });
  return marks.map(function (mk, i) {
    const end = i + 1 < marks.length ? marks[i + 1].pos : html.length;
    const seg = html.slice(mk.pos, end);
    const card = makeEl("div");
    card.dataset["data-edit-issue"] = mk.idx;
    card.querySelector = function (sel) {
      const fm = /^\[data-f='([^']+)'\]$/.exec(sel);
      if (!fm) return null;
      if (fm[1] === "kind") {
        const km = /data-f="kind"[\s\S]*?value="([^"]+)" selected/.exec(seg);
        return valueNode(km ? km[1] : "handwork");
      }
      return fieldNodes(seg, fm[1])[0] || null;
    };
    // 行节点按选择器缓存:驱动对输入 value 的改动(等价用户输入)须在
    // collectEditor 的多次 querySelectorAll 之间保持,同真实 DOM
    const fieldCache = {};
    card.querySelectorAll = function (sel) {
      if (!(sel in fieldCache)) {
        if (sel === "[data-f='given-item']") fieldCache[sel] = fieldNodes(seg, "given-item");
        else if (sel === "[data-material-row]") fieldCache[sel] = rowNodes(seg, "data-material-row", ["m-title", "m-ref"]);
        else if (sel === "[data-check-row]") fieldCache[sel] = rowNodes(seg, "data-check-row", ["c-id", "c-text"]);
        else fieldCache[sel] = [];
      }
      return fieldCache[sel];
    };
    return card;
  });
}
function findById(node, id) {
  if (node._ids[id]) return node._ids[id];
  const kids = node.children.concat(Object.keys(node._ids).map(function (k) { return node._ids[k]; }));
  for (let i = 0; i < kids.length; i++) {
    const found = findById(kids[i], id);
    if (found) return found;
  }
  return null;
}
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
      // 提取 id="..." 生成可寻址子节点(view.js 渲染后按 id 挂数据),
      // 输入/文本域的渲染值回填为节点 value(= 用户未改动的编辑初值)
      const re = /id="([^"]+)"/g; let m;
      while ((m = re.exec(node._html))) {
        const sub = makeEl("div");
        sub._value = extractValue(node._html, m[1]);
        node._ids[m[1]] = sub;
      }
    },
  });
  Object.defineProperty(node, "value", {
    get() { return node._value || ""; }, set(v) { node._value = String(v); },
  });
  node.querySelector = function (sel) {
    if (sel.startsWith("#")) {
      const id = sel.slice(1);
      const found = findById(node, id);
      if (found) return found;
      node._ids[id] = makeEl("div");
      return node._ids[id];
    }
    return null;
  };
  node.querySelectorAll = function (sel) {
    const html = node.innerHTML;
    // 卡片与行操作钮按 html 快照缓存:同一渲染周期内多次 querySelectorAll
    // 返回同一批节点(bindEditor 绑的 listener 与驱动点击拿到的是同一对象);
    // 重渲染(innerHTML 变化)后缓存失效,等价真实 DOM 旧节点被丢弃
    if (sel === "[data-edit-issue]") {
      if (!node._cards || node._cards.html !== html) node._cards = { html: html, nodes: parseIssueCards(html) };
      return node._cards.nodes;
    }
    const rm = /^\[(data-(?:add|remove)-(?:given|material|check))\]$/.exec(sel);
    if (rm) {
      if (!node._rowOps || node._rowOps.html !== html) node._rowOps = { html: html, btns: {} };
      if (!node._rowOps.btns[sel]) {
        const re = new RegExp(rm[1] + '="([^"]+)"', "g");
        const out = []; let m;
        while ((m = re.exec(html))) {
          const b = makeEl("button");
          b.dataset[rm[1]] = m[1];
          out.push(b);
        }
        node._rowOps.btns[sel] = out;
      }
      return node._rowOps.btns[sel];
    }
    return [];
  };
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
  addEventListener() {},
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
globalThis.fetch = async (url, opts) => {
  const path = String(url).split("?")[0];
  calls.fetches.push(path);

  // 编辑器场景(editor_delimiter_roundtrip / editor_remove_row_with_empty):
  // tutor 台 + 一门课 + 场景草稿;POST 捕获 body
  if (scenario === "editor_delimiter_roundtrip" || scenario === "editor_remove_row_with_empty") {
    if (path === "/api/ext/cgc-2046/me/workspaces") {
      return { ok: true, status: 200, json: async () => ({ ok: true, result: { workspaces: [{ workspace_id: "ws-t1", name: "教研台", roles: ["tutor"] }] } }) };
    }
    if (path === "/api/ext/cgc-2046/workspace/courses") {
      return { ok: true, status: 200, json: async () => ({ ok: true, result: { courses: [{ course_id: "course-1", title: "分隔符压力课", status: "open" }] } }) };
    }
    if (path === "/api/ext/cgc-2046/courses/course-1/prep") {
      return { ok: false, status: 404, json: async () => ({ error: "no prep" }) };
    }
    if (path === "/api/ext/cgc-2046/courses/course-1/content") {
      if (opts && opts.method === "POST") {
        roundtripPosted = JSON.parse(String(opts.body || "{}"));
        return { ok: true, status: 200, json: async () => ({ ok: true, status: "saved" }) };
      }
      return { ok: true, status: 200, json: async () => ({ ok: true, result: scenario === "editor_remove_row_with_empty" ? REMOVE_ORIGINAL : ROUNDTRIP_ORIGINAL }) };
    }
  }
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

  // #347:打开编辑 → 不做任何改动 → 保存;POST content 必须与原始草稿 deep-equal
  if (scenario === "editor_delimiter_roundtrip") {
    const container = el("div");
    spec.render(container);           // boot:workspaces → courses → content
    await sleep(200);
    spec.render(container);
    await sleep(50);

    // 点「编辑内容」进入编辑态(enterEdit 拉 content 建 draft)
    const toggle = container.querySelector("#cgt-edit-toggle");
    ((toggle && toggle.listeners.click) || []).forEach(function (fn) { fn(); });
    await sleep(100);

    // 不碰任何输入(假 DOM 的 value 即渲染初值),直接点「保存草稿」
    const saveBtn = container.querySelector("#cgc-save");
    const saveHandlers = (saveBtn && saveBtn.listeners.click) || [];
    for (const fn of saveHandlers) await fn();
    await sleep(100);

    const deepEq = function (a, b) {
      if (a === b) return true;
      if (typeof a !== "object" || typeof b !== "object" || !a || !b) return false;
      if (Array.isArray(a) !== Array.isArray(b)) return false;
      const ka = Object.keys(a), kb = Object.keys(b);
      if (ka.length !== kb.length) return false;
      return ka.every(function (k) { return deepEq(a[k], b[k]); });
    };
    const expected = JSON.parse(JSON.stringify(ROUNDTRIP_ORIGINAL));
    delete expected.version;          // version 剥离走顶层 base_version
    const posted = roundtripPosted || {};
    const content = posted.content || {};
    const story0 = (((content.issues || [])[0] || {}).story) || {};

    const checks = {
      save_posted: !!roundtripPosted,
      workspace_scoped: posted.workspace_id === "ws-t1",
      base_version_pinned: posted.base_version === 3,
      version_key_stripped: !!roundtripPosted && !("version" in content),
      goals_roundtrip: deepEq(content.goals, expected.goals),
      given_roundtrip: deepEq(story0.given, expected.issues[0].story.given),
      materials_roundtrip: deepEq(story0.materials, expected.issues[0].story.materials),
      checklist_roundtrip: deepEq(story0.checklist, expected.issues[0].story.checklist),
      content_deep_equal: deepEq(content, expected),
    };

    const failed = Object.entries(checks).filter(([, v]) => !v);
    if (failed.length > 0) {
      console.error("FAIL: " + failed.map(([k]) => k).join(", "));
      console.error("posted: " + JSON.stringify(posted).slice(0, 800));
      process.exit(1);
    }
    console.log("OK " + scenario + " " + JSON.stringify(checks));
    return;
  }

  // advisor F1:given=[AAA,BBB,CCC],清空 AAA(等价用户清空输入)→ 点 BBB 的
  // 删除钮(data-remove-given="0:1")→ 保存;posted given 必须恰为 ["CCC"]
  // (修复前 collectEditor 先过滤空行,索引错位 splice 掉 CCC 留下 BBB)
  if (scenario === "editor_remove_row_with_empty") {
    const container = el("div");
    spec.render(container);
    await sleep(200);
    spec.render(container);
    await sleep(50);

    const toggle = container.querySelector("#cgt-edit-toggle");
    ((toggle && toggle.listeners.click) || []).forEach(function (fn) { fn(); });
    await sleep(100);

    // 清空第一行 given(节点按 html 快照缓存,改动对后续 collectEditor 可见)
    const card = container.querySelectorAll("[data-edit-issue]")[0];
    card.querySelectorAll("[data-f='given-item']")[0].value = "";

    // 点第二行(BBB)的删除钮
    const btn = container.querySelectorAll("[data-remove-given]").filter(function (b) {
      return b.getAttribute("data-remove-given") === "0:1";
    })[0];
    ((btn && btn.listeners.click) || []).forEach(function (fn) { fn(); });
    await sleep(50);

    const saveBtn = container.querySelector("#cgc-save");
    const saveHandlers = (saveBtn && saveBtn.listeners.click) || [];
    for (const fn of saveHandlers) await fn();
    await sleep(100);

    const deepEq = function (a, b) {
      if (a === b) return true;
      if (typeof a !== "object" || typeof b !== "object" || !a || !b) return false;
      if (Array.isArray(a) !== Array.isArray(b)) return false;
      const ka = Object.keys(a), kb = Object.keys(b);
      if (ka.length !== kb.length) return false;
      return ka.every(function (k) { return deepEq(a[k], b[k]); });
    };
    const posted = roundtripPosted || {};
    const given = (((((posted.content || {}).issues || [])[0] || {}).story) || {}).given;

    const checks = {
      save_posted: !!roundtripPosted,
      // 删的恰是 BBB;空行在 saveDraft 深过滤,不落库
      remove_targets_exact_row: deepEq(given, ["CCC"]),
    };

    const failed = Object.entries(checks).filter(([, v]) => !v);
    if (failed.length > 0) {
      console.error("FAIL: " + failed.map(([k]) => k).join(", "));
      console.error("posted given: " + JSON.stringify(given));
      process.exit(1);
    }
    console.log("OK " + scenario + " " + JSON.stringify(checks));
    return;
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
