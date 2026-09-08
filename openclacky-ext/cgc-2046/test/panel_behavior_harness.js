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
// M3/L5:web 材料带 caption + 未知键(attribution),章节与 issue.chapter_id
// 一并进 round-trip——编辑器未覆盖的键必须原样存活(deep-equal 断言兜底)。
const ROUNDTRIP_ORIGINAL = {
  version: 3,
  course_title: "分隔符 | 压力课",
  goals: ["掌握 C/C++ 基础", "能读 HTTP/2 文档"],
  chapters: [{ id: "ch-1", title: "第一章 · 读 | 写" }],
  issues: [{
    id: "issue-1", kind: "handwork", title: "环境 | 配置", chapter_id: "ch-1",
    story: {
      as_a: "有 HTTP/2 经验的学员",
      given: ["熟悉 C/C++ 基础", "完成 读写/入门"],
      goal: "独立配置 a/b 环境",
      materials: [
        { kind: "web", title: "HTTP/2 | 图解", url: "https://example.com/http2",
          caption: "RFC 7540 配插图解", attribution: "示例来源标注(编辑器未覆盖的未知键)" },
        { kind: "text", title: "纯标题无链接", body: "" }
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

// L5 场景 editor_remove_chapter_clears_refs:删除被引用的章节后,引用它的
// issue.chapter_id 必须清为未分组(键消失),不留悬空 id
const CHAPTER_ORIGINAL = {
  version: 1,
  course_title: "章节清理课",
  goals: ["目标一"],
  chapters: [
    { id: "ch-1", title: "第一章" },
    { id: "ch-2", title: "第二章" }
  ],
  issues: [{
    id: "issue-1", kind: "handwork", title: "单元一", chapter_id: "ch-1",
    story: {
      as_a: "", given: [], goal: "",
      materials: [], checklist: [{ id: "c1", text: "验收一" }]
    }
  }]
};

// M2 场景 learner_typed_materials:已发布 revision 携带 typed/legacy 混合材料,
// 学习目标详情页只渲染 https 外链,legacy ref 永不进 href
const TYPED_REVISION = {
  version: 2,
  course_title: "零成员公开课",
  issues: [{
    id: "issue-1", kind: "handwork", title: "第一章 环境配置",
    objectives: [{
      id: "obj-1", title: "配置开发环境",
      materials: [
        { kind: "web", title: "MDN 文档", url: "https://example.com/docs" },
        { kind: "video", title: "配置演示", provider: "bilibili", external_id: "BV1xx411c7mD" },
        { kind: "web", title: "危险链接", url: "javascript:alert(1)" },
        { title: "旧行材料", ref: "javascript:alert(2)" }
      ],
      rubric: [{ id: "r1", text: "能独立跑通" }]
    }]
  }]
};

// 各场景共用的 deep-equal(键序不敏感,数组保序)
function deepEq(a, b) {
  if (a === b) return true;
  if (typeof a !== "object" || typeof b !== "object" || !a || !b) return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  const ka = Object.keys(a), kb = Object.keys(b);
  if (ka.length !== kb.length) return false;
  return ka.every(function (k) { return deepEq(a[k], b[k]); });
}

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
      if (fm && fields.indexOf(fm[1]) >= 0) {
        if (fm[1] === "m-kind") {
          const km = /data-f="m-kind"[\s\S]*?value="([^"]+)" selected/.exec(part);
          return valueNode(km ? km[1] : "text");
        }
        return fieldNodes(part, fm[1])[0] || null;
      }
      return null;
    };
    return row;
  });
}
// 章节编辑行:[data-edit-chapter] 裸标记切分,行内取 chapter-id/chapter-title 输入
function chapterRowNodes(html) {
  return html.split("data-edit-chapter").slice(1).map(function (part) {
    const row = makeEl("div");
    row.querySelector = function (sel) {
      const fm = /^\[data-f='([^']+)'\]$/.exec(sel);
      if (fm && (fm[1] === "chapter-id" || fm[1] === "chapter-title")) {
        return fieldNodes(part, fm[1])[0] || null;
      }
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
      // 章节归属 <select>:选中项取 value;未分组 option value="" 不匹配 [^"]+,
      // 兜底空串 = 未分组
      if (fm[1] === "chapter") {
        const km = /data-f="chapter"[\s\S]*?value="([^"]+)" selected/.exec(seg);
        return valueNode(km ? km[1] : "");
      }
      return fieldNodes(seg, fm[1])[0] || null;
    };
    // 行节点按选择器缓存:驱动对输入 value 的改动(等价用户输入)须在
    // collectEditor 的多次 querySelectorAll 之间保持,同真实 DOM
    const fieldCache = {};
    card.querySelectorAll = function (sel) {
      if (!(sel in fieldCache)) {
        if (sel === "[data-f='given-item']") fieldCache[sel] = fieldNodes(seg, "given-item");
        else if (sel === "[data-material-row]") fieldCache[sel] = rowNodes(seg, "data-material-row", ["m-kind", "m-title", "m-body", "m-url", "m-provider", "m-external-id", "m-alt-text", "m-caption"]);
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
    dispatchEvent() {},   // ⑧ Kit.injectIntoComposer 触发 input 事件,假 DOM 无需分发
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
    // [data-body='x'] 属性选择器(cgc-learn 两段式渲染:卡骨架 → 内容搬运进
    // body div):代理节点,innerHTML 读写直接落宿主 _html 中对应空 div 内
    const bm = /^\[data-body='([^']+)'\]$/.exec(sel);
    if (bm) {
      const sub = { tagName: "div", textContent: "", style: {}, dataset: {}, className: "", listeners: {},
        addEventListener(t, fn) { (sub.listeners[t] = sub.listeners[t] || []).push(fn); },
        setAttribute() {}, getAttribute() { return null; }, appendChild(c) { return c; },
        contains() { return true; }, scrollIntoView() {}, dispatchEvent() {},
        classList: { add() {}, remove() {}, toggle() {} } };
      const mark = 'data-body="' + bm[1] + '"';
      Object.defineProperty(sub, "innerHTML", {
        get() {
          const i = node._html.indexOf(mark);
          if (i < 0) return "";
          const start = node._html.indexOf(">", i) + 1;
          const end = node._html.indexOf("</div>", start);
          return end < 0 ? "" : node._html.slice(start, end);
        },
        set(v) {
          const i = node._html.indexOf(mark);
          if (i < 0) return;
          const start = node._html.indexOf(">", i) + 1;
          const end = node._html.indexOf("</div>", start);
          if (end < 0) return;
          node._html = node._html.slice(0, start) + String(v) + node._html.slice(end);
        },
      });
      return sub;
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
    // 章节编辑行挂在容器层(issue 卡之外),同按 html 快照缓存
    if (sel === "[data-edit-chapter]") {
      if (!node._chapterRows || node._chapterRows.html !== html) node._chapterRows = { html: html, nodes: chapterRowNodes(html) };
      return node._chapterRows.nodes;
    }
    // 学习中心大纲树节点(cgc-course renderTree 绑定点击 → 目标详情)
    if (sel === "[data-node]") {
      if (!node._treeNodes || node._treeNodes.html !== html) {
        const re = /data-node="([^"]+)"/g;
        const out = []; let m;
        while ((m = re.exec(html))) {
          const b = makeEl("div");
          b.dataset["data-node"] = m[1];
          out.push(b);
        }
        node._treeNodes = { html: html, nodes: out };
      }
      return node._treeNodes.nodes;
    }
    const rm = /^\[(data-(?:add|remove)-(?:given|material|check|chapter))\]$/.exec(sel);
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
    // 通用 [data-x] 属性选择器 fallback(admin-aside 待办行/动作钮/深链钮):
    // 同按 html 快照缓存;匹配整个标签并提取全部 data-* 属性(兄弟属性如
    // data-enroll-idx 与选择器属性共存,bind handler 按属性组合取数)
    const gm = /^\[(data-[a-z-]+)\]$/.exec(sel);
    if (gm) {
      if (!node._dataBtns || node._dataBtns.html !== html) node._dataBtns = { html: html, btns: {} };
      if (!node._dataBtns.btns[sel]) {
        const re = new RegExp('<[^>]*' + gm[1] + '="[^"]*"[^>]*>', "g");
        const out = []; let m;
        while ((m = re.exec(html))) {
          const b = makeEl("button");
          const attrRe = /(data-[a-z-]+)="([^"]*)"/g; let am;
          while ((am = attrRe.exec(m[0]))) b.dataset[am[1]] = am[2];
          out.push(b);
        }
        node._dataBtns.btns[sel] = out;
      }
      return node._dataBtns.btns[sel];
    }
    return [];
  };
  return node;
}
function el(tag) { return makeEl(tag); }

const calls = { fetches: [], urls: [] };
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
// admin-aside 注入路径 stub:宿主输入框缺席时 injectIntoComposer 走 window.prompt
// fallback——harness 不 stub 输入框,断言等价物 __prompted 文案
globalThis.prompt = (label, text) => { globalThis.__prompted = String(text == null ? "" : text); };
// home disconnect 连接确认框(home_hub 场景驱动确认路径);alert 捕获失败提示
globalThis.confirm = () => true;
globalThis.alert = (m) => { (globalThis.__alerts = globalThis.__alerts || []).push(String(m)); };
// learn_boot_and_inject:宿主会话输入框(contenteditable DIV,预置草稿验追加保护)+ 发送按钮
const __domById = {};
if (scenario === "learn_boot_and_inject") {
  const __input = el("div");
  __input.textContent = "我的补充问题草稿";
  const __send = el("button");
  __send.disabled = false;
  __send.click = () => { globalThis.__sendClicked = (globalThis.__sendClicked || 0) + 1; };
  __domById["user-input"] = __input;
  __domById["btn-send"] = __send;
}
// 深链打开捕获
globalThis.open = (url) => { (globalThis.__opened = globalThis.__opened || []).push(String(url)); };
globalThis.document = {
  hidden: false,
  addEventListener(t, fn) { (globalThis.__docListeners = globalThis.__docListeners || {}); (globalThis.__docListeners[t] = globalThis.__docListeners[t] || []).push(fn); },
  createElement: el,
  getElementById(id) { return __domById[id] || null; },
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
  calls.urls.push(String(url));   // 完整 url(P3 断言 query 里的 kind 分派)

  // admin_aside 场景:一个 owner 台(编程少女台/acme) + 一个 member-only 台(应被
  // ADMIN_ROLES 过滤);待办含报名审批/加入申请两行;status 透传 web_url(深链基址)
  if (scenario === "admin_aside") {
    if (path === "/api/ext/cgc-2046/me/workspaces") {
      return { ok: true, status: 200, json: async () => ({ ok: true, result: { workspaces: [
        { workspace_id: "ws-a1", name: "编程少女台", slug: "acme", roles: ["owner"] },
        { workspace_id: "ws-b2", name: "普通成员台", slug: "plain", roles: ["member"] },
      ] } }) };
    }
    if (path === "/api/ext/cgc-2046/tasks") {
      return { ok: true, status: 200, json: async () => ({ ok: true, result: { tasks: [
        { kind: "enrollment_approval", context_title: "Python 入门营", requester_name: "小安" },
        { kind: "join_request", requester_name: "阿珍" },
      ] } }) };
    }
    if (path === "/api/ext/cgc-2046/status") {
      return { ok: true, status: 200, json: async () => ({ ok: true, configured: true, web_url: "https://codingirlsclub.com" }) };
    }
    if (path === "/api/ext/cgc-2046/workspace/courses") {
      return { ok: true, status: 200, json: async () => ({ ok: true, result: { courses: [
        { course_id: "c-1", title: "Python 入门", status: "draft", prep_state: "review" },
        { course_id: "c-2", title: "数据科学营", status: "open", prep_state: null },
      ] } }) };
    }
    if (path === "/api/ext/cgc-2046/workspace/events") {
      return { ok: true, status: 200, json: async () => ({ ok: true, result: { count: 1, events: [
        { event_id: "ev-1", title: "线下沙龙", status: "open", enrollment_badge: "enrolling", slug: "salon-1" },
      ] } }) };
    }
    if (path === "/api/ext/cgc-2046/workspace/enrollments") {
      return { ok: true, status: 200, json: async () => ({ ok: true, result: {
        count: 2, offering_title: "Python 入门",
        enrollments: [
          { enrollment_id: "e-1", user: { id: "u1", email: "an@x.com", display_name: "小安" },
            status: "pending", tier: { id: "t1", name: "标准档", amount_cents: 19900 } },
          { enrollment_id: "e-2", user: { id: "u2", email: "zhen@x.com", display_name: "阿珍" },
            status: "confirmed", tier: null },
        ],
      } }) };
    }
    if (path === "/api/ext/cgc-2046/workspace/orders") {
      return { ok: true, status: 200, json: async () => ({ ok: true, result: {
        count: 3, more: false,
        orders: [
          { order_id: "o-1", status: "paid", amount_cents: 19900, tier_name: "标准档",
            enrollment: { enrollment_id: "e-9", learner_email: "a@x.com", enrollment_status: "confirmed" },
            offering: { course_id: "c-2", event_id: null }, provider: "alipay" },
          { order_id: "o-2", status: "refund_failed", amount_cents: 9900, tier_name: "早鸟",
            enrollment: { enrollment_id: "e-8", learner_email: "b@x.com", enrollment_status: "cancelled" },
            offering: { course_id: "c-1", event_id: null }, provider: "alipay" },
          { order_id: "o-3", status: "pending", amount_cents: 5000, tier_name: "标准档",
            enrollment: { enrollment_id: "e-7", learner_email: "c@x.com", enrollment_status: "payment_pending" },
            offering: { course_id: "c-1", event_id: null }, provider: "wxpay" },
          { order_id: "o-4", status: "pending", amount_cents: 100, tier_name: "标准档",
            enrollment: { enrollment_id: "e-10", learner_email: "d@x.com", enrollment_status: "payment_pending" },
            offering: { course_id: "c-1", event_id: null }, provider: "wxpay" },
          { order_id: "o-5", status: "pending", amount_cents: 100, tier_name: "标准档",
            enrollment: { enrollment_id: "e-11", learner_email: "e@x.com", enrollment_status: "payment_pending" },
            offering: { course_id: "c-1", event_id: null }, provider: "wxpay" },
          { order_id: "o-6", status: "pending", amount_cents: 100, tier_name: "标准档",
            enrollment: { enrollment_id: "e-12", learner_email: "f@x.com", enrollment_status: "payment_pending" },
            offering: { course_id: "c-1", event_id: null }, provider: "wxpay" },
          { order_id: "o-7", status: "pending", amount_cents: 100, tier_name: "标准档",
            enrollment: { enrollment_id: "e-13", learner_email: "g@x.com", enrollment_status: "payment_pending" },
            offering: { course_id: "c-1", event_id: null }, provider: "wxpay" },
        ],
      } }) };
    }
  }
  // ⑧ home_hub:hub 面板已连接态(状态 pill/身份区/任务/目录) + 断开 403 自愈
  if (scenario === "home_hub" || scenario === "home_unconnected" || scenario === "home_tasks_failed") {
    if (path === "/api/ext/cgc-2046/status") {
      return { ok: true, status: 200, json: async () => (scenario === "home_unconnected"
        ? { ok: true, configured: false, web_url: "https://codingirlsclub.com" }
        : { ok: true, configured: true, web_url: "https://codingirlsclub.com", csrf_token: "tok-1" }) };
    }
    if (path === "/api/ext/cgc-2046/me/workspaces") {
      return { ok: true, status: 200, json: async () => ({ ok: true, result: { workspaces: [
        { workspace_id: "ws-h1", name: "编程少女台<img src=x onerror=alert(1)>", slug: "acme", roles: ["owner"] },
        { workspace_id: "ws-h2", name: "普通成员台", slug: "plain", roles: ["member"] },
      ] } }) };
    }
    if (path === "/api/ext/cgc-2046/tasks") {
      // 跨台聚合:ws-h1 有 1 条报名审批;ws-h2 单台 403(allSettled 跳过不拖空白单)
      // home_tasks_failed:两台皆 403 → 全部失败必须渲染错误态(≠ 暂无待办空态)
      if (scenario === "home_tasks_failed") {
        return { ok: false, status: 403, json: async () => ({ error: "forbidden" }) };
      }
      if (String(url).indexOf("workspace_id=ws-h2") >= 0) {
        return { ok: false, status: 403, json: async () => ({ error: "forbidden" }) };
      }
      return { ok: true, status: 200, json: async () => ({ ok: true, result: { tasks: [
        { kind: "enrollment_approval", context_title: "Python 入门营", requester_name: "小安" },
      ] } }) };
    }
    if (path === "/api/ext/cgc-2046/activity") {
      return { ok: true, status: 200, json: async () => ({ ok: true, activity: [] }) };
    }
    if (path === "/api/ext/cgc-2046/connect" && opts && opts.method === "DELETE") {
      globalThis.__deleteBodies = (globalThis.__deleteBodies || []).concat(String(opts.body || ""));
      globalThis.__deleteAttempts = (globalThis.__deleteAttempts || 0) + 1;
      if (globalThis.__deleteAttempts === 1) {
        return { ok: false, status: 403, json: async () => ({ error: "forbidden", csrf_token: "tok-fresh" }) };
      }
      return { ok: true, status: 200, json: async () => ({ ok: true }) };
    }
    if (path === "/api/sessions") {
      if (opts && opts.method === "POST") {
        globalThis.__sessionPostBody = JSON.parse(String(opts.body || "{}"));
        return { ok: true, status: 200, json: async () => ({ session: { id: "sess-1", agent_profile: globalThis.__sessionPostBody.agent_profile, name: globalThis.__sessionPostBody.name } }) };
      }
      return { ok: true, status: 200, json: async () => ({ sessions: [
        { id: "sess-old", name: "旧诊断会话", agent_profile: "cgc-assistant", status: "running", updated_at: "2026-09-08T10:00:00Z" },
        { id: "sess-other", name: "别的助手会话", agent_profile: "other-agent", status: "idle", updated_at: "2026-09-08T11:00:00Z" },
      ] }) };
    }
  }
  // ⑧ tutor_aside_boot:session.aside 挂载 + tutor 台课程发现 + 草稿拉取链
  if (scenario === "tutor_aside_boot") {
    if (path === "/api/ext/cgc-2046/me/workspaces") {
      return { ok: true, status: 200, json: async () => ({ ok: true, result: { workspaces: [
        { workspace_id: "ws-t9", name: "教研台", slug: "teach", roles: ["tutor"] },
        { workspace_id: "ws-m1", name: "学员台", slug: "plain", roles: ["member"] },
      ] } }) };
    }
    if (path === "/api/ext/cgc-2046/workspace/courses") {
      return { ok: true, status: 200, json: async () => ({ ok: true, result: { courses: [
        { course_id: "c-9", title: "教研草稿课", status: "draft" },
      ] } }) };
    }
    if (path === "/api/ext/cgc-2046/courses/c-9/content") {
      return { ok: true, status: 200, json: async () => ({ ok: true, result: { version: 2, course_title: "教研草稿课",
        issues: [{ id: "i-1", kind: "handwork", title: "单元一", chapter_id: "",
          story: { as_a: "", given: [], goal: "", materials: [], checklist: [] },
          objectives: [{ id: "o-1", title: "目标一" }] }] } }) };
    }
    if (path === "/api/ext/cgc-2046/courses/c-9/prep") {
      return { ok: false, status: 404, json: async () => ({ error: "no prep" }) };
    }
  }
  // 编辑器场景(editor_delimiter_roundtrip / editor_remove_row_with_empty /
  // editor_remove_chapter_clears_refs):tutor 台 + 一门课 + 场景草稿;POST 捕获 body
  if (scenario === "editor_delimiter_roundtrip" || scenario === "editor_remove_row_with_empty" ||
      scenario === "editor_remove_chapter_clears_refs") {
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
      return { ok: true, status: 200, json: async () => ({ ok: true, result: scenario === "editor_remove_row_with_empty" ? REMOVE_ORIGINAL : scenario === "editor_remove_chapter_clears_refs" ? CHAPTER_ORIGINAL : ROUNDTRIP_ORIGINAL }) };
    }
  }
  // learner_typed_materials:已发布 revision 携带 typed/legacy 混合材料
  if (scenario === "learner_typed_materials" &&
      path.startsWith("/api/ext/cgc-2046/courses/") && path.endsWith("/revision")) {
    return { ok: true, status: 200, json: async () => ({ ok: true, result: TYPED_REVISION }) };
  }
  // web_url scheme 门(安全评审低危#4):home/discovery 两阶段 status(计数器切响应)——
  // #1 javascript: 走私(无门旧代码必败),#2 合法形态(home=README 联调 localhost http;
  // discovery=https 但带引号,过门后考 href 属性转义)
  if (scenario === "home_weburl_gate") {
    if (path === "/api/ext/cgc-2046/status") {
      globalThis.__statusCount = (globalThis.__statusCount || 0) + 1;
      return { ok: true, status: 200, json: async () => (globalThis.__statusCount === 1
        ? { ok: true, configured: true, web_url: "javascript:alert(1)//https://codingirlsclub.com", csrf_token: "tok-1" }
        : { ok: true, configured: true, web_url: "http://localhost:3000", csrf_token: "tok-1" }) };
    }
    if (path === "/api/ext/cgc-2046/me/workspaces") {
      return { ok: true, status: 200, json: async () => ({ ok: true, result: { is_platform_admin: true, workspaces: [
        { workspace_id: "ws-g1", name: "门测台", slug: "gate", roles: ["owner"] },
      ] } }) };
    }
    if (path === "/api/ext/cgc-2046/tasks") {
      return { ok: true, status: 200, json: async () => ({ ok: true, result: { tasks: [] } }) };
    }
    if (path === "/api/ext/cgc-2046/activity") {
      return { ok: true, status: 200, json: async () => ({ ok: true, activity: [] }) };
    }
    if (path === "/api/sessions") {
      return { ok: true, status: 200, json: async () => ({ sessions: [] }) };
    }
  }
  if (scenario === "discovery_weburl_gate") {
    if (path === "/api/ext/cgc-2046/discover") {
      return { ok: true, status: 200, json: async () => ({ ok: true, result: { offerings: [
        { id: "ev-g1", slug: "salon-gate", title: "门测沙龙", kind: "event", status: "open",
          workspace: { id: "ws-g1", name: "门测台" }, pricing: { enabled: false },
          registration_deadline: null, my_enrollment: null },
      ] } }) };
    }
    if (path === "/api/ext/cgc-2046/status") {
      globalThis.__statusCount = (globalThis.__statusCount || 0) + 1;
      return { ok: true, status: 200, json: async () => (globalThis.__statusCount === 1
        ? { ok: true, configured: true, web_url: "javascript:alert(1)//x" }
        : { ok: true, configured: true, web_url: 'https://gate.example.com/"onmouseover="alert(1)' }) };
    }
  }
  if (path.startsWith("/api/ext/cgc-2046/learning_state")) {
    return {
      ok: true, status: 200,
      json: async () => ({
        ok: true,
        result: {
          objectives: [
            { id: "obj-1", title: "配置开发环境", mastery: "developing", attempt_count: 0, required: true, locked: false, issue_id: "issue-1" },
            // ⑧ learn_boot_and_inject:locked 目标永不渲染注入点
            { id: "obj-2", title: "进阶锁定目标", mastery: "unstarted", attempt_count: 0, required: true, locked: true, issue_id: "issue-1" }
          ],
          progress: { mastered_required: 0, total_required: 1, complete: false },
          next_action: { objective_id: "obj-1", reason: "从这里开始" },
          review_queue: [{ objective_id: "obj-1", title: "配置开发环境", due: "今天" }]
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
      // admin-aside 等 session.aside 面板:捕获 mount 回调与 opts,场景段手动驱动
      mount(slot, cb, opts) { globalThis.__mounted = { slot, cb, opts }; },
      openWorkspace() {},
    },
    // 事件订阅捕获(ext.cgc-2046.tool_used / mcp_error):场景段手动触发
    subscribe(event, fn) {
      globalThis.__subs = globalThis.__subs || {};
      (globalThis.__subs[event] = globalThis.__subs[event] || []).push(fn);
    },
  },
  // ⑧ home_hub:/api/sessions 创建后的会话列表通道(cgc-home localSessions/select)
  Sessions: {
    all: [],
    add(s) { this.all.push(s); },
    renderList() {},
    select(id) { globalThis.__sessionSelected = id; },
  },
  // ⑧ toast 捕获(home disconnect 成功提示等)
  Modal: { toast(msg) { (globalThis.__toasts = globalThis.__toasts || []).push(String(msg)); } },
  // ⑧ 最近会话行点击导航(cgc-home data-session 行 → session 页)
  Router: { navigate(name, params) { globalThis.__navigated = { name: name, params: params }; } },
};

// ⑦ 共享骨架:业务面板 view.js 顶部依赖 window.CgcKit(ext.yml 首位声明注入);
// harness 复刻装载顺序——先 require 同扩展 panels/shared/view.js 再加载目标
require(require("path").resolve(require("path").dirname(viewPath), "..", "shared", "view.js"));
if (!globalThis.CgcKit) { console.error("FAIL: 共享骨架 CgcKit 未挂载"); process.exit(1); }
require(require("path").resolve(viewPath));

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  // web_url scheme 门·纯谓词真值表(安全评审低危#4):viewPath = panels/shared/view.js,
  // 无面板 spec——须在任何 registerWorkspace 检查前 early-return
  if (scenario === "kit_safe_url") {
    const safe = globalThis.CgcKit.safeWebUrl;
    const checks = {
      helper_exported: typeof safe === "function",
      https_ok: safe("https://codingirlsclub.com") === "https://codingirlsclub.com",
      https_uppercase_ok: !!safe("HTTPS://CODINGIRLSCLUB.COM"),
      localhost_http_ok: !!safe("http://localhost:3000"),
      loopback_ip_http_ok: !!safe("http://127.0.0.1:3000"),
      ipv6_loopback_http_ok: !!safe("http://[::1]:3000"),
      plain_http_rejected: safe("http://evil.example.com") === null,
      lan_ip_http_rejected: safe("http://192.168.1.5:3000") === null,
      localhost_subdomain_rejected: safe("http://localhost.evil.com") === null,
      javascript_rejected: safe("javascript:alert(1)") === null,
      javascript_comment_smuggle_rejected: safe("javascript:alert(1)//https://x.com") === null,
      tab_smuggle_javascript_rejected: safe("java\tscript:alert(1)") === null,
      data_rejected: safe("data:text/html,<script>1</script>") === null,
      file_rejected: safe("file:///etc/passwd") === null,
      relative_rejected: safe("/w/acme/settings") === null && safe("codingirlsclub.com") === null,
      protocol_less_rejected: safe("//evil.com") === null,
      non_string_rejected: safe(null) === null && safe(undefined) === null && safe(123) === null,
    };
    const failed = Object.entries(checks).filter(([, v]) => !v);
    if (failed.length > 0) {
      console.error("FAIL: " + failed.map(([k]) => k).join(", "));
      process.exit(1);
    }
    console.log("OK " + scenario + " " + JSON.stringify(checks));
    return;
  }

  // session.aside 面板(admin-aside/learn/tutor-aside)走 mount 捕获,不经 registerWorkspace
  const MOUNT_SCENARIOS = { admin_aside: 1, learn_boot_and_inject: 1, tutor_aside_boot: 1 };
  const { spec } = globalThis.__registered || {};
  if (!MOUNT_SCENARIOS[scenario] && (!spec || typeof spec.render !== "function")) {
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

    // deepEq 用顶部共享实现
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
      chapters_roundtrip: deepEq(content.chapters, expected.chapters),
      chapter_id_roundtrip: ((content.issues || [])[0] || {}).chapter_id === "ch-1",
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

    // deepEq 用顶部共享实现
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

  // L5:chapters [ch-1,ch-2]、issue.chapter_id=ch-1 → 点 ch-1 删除钮 → 保存;
  // posted chapters 必须恰剩 ch-2,且 issue 不再携带 chapter_id(未分组)
  if (scenario === "editor_remove_chapter_clears_refs") {
    const container = el("div");
    spec.render(container);
    await sleep(200);
    spec.render(container);
    await sleep(50);

    const toggle = container.querySelector("#cgt-edit-toggle");
    ((toggle && toggle.listeners.click) || []).forEach(function (fn) { fn(); });
    await sleep(100);

    const btn = container.querySelectorAll("[data-remove-chapter]").filter(function (b) {
      return b.getAttribute("data-remove-chapter") === "0";
    })[0];
    if (!btn) { console.error("FAIL: 未渲染章节删除钮"); process.exit(1); }
    (btn.listeners.click || []).forEach(function (fn) { fn(); });
    await sleep(50);

    const saveBtn = container.querySelector("#cgc-save");
    const saveHandlers = (saveBtn && saveBtn.listeners.click) || [];
    for (const fn of saveHandlers) await fn();
    await sleep(100);

    const posted = roundtripPosted || {};
    const content = posted.content || {};
    const issue0 = (content.issues || [])[0] || {};
    const checks = {
      save_posted: !!roundtripPosted,
      chapter_removed: deepEq(content.chapters, [{ id: "ch-2", title: "第二章" }]),
      issue_refs_cleared: !("chapter_id" in issue0),
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

  // M2+M4:learner 面板目标详情——材料来自 /revision(不再请求 /content);
  // typed web/video 仅 https 外链,javascript: scheme 与 legacy ref 永不进 DOM
  if (scenario === "learner_typed_materials") {
    const container = el("div");
    spec.render(container);
    await sleep(200);
    spec.render(container);
    await sleep(50);

    // 点大纲树 obj-1 节点进入目标详情(材料渲染面)
    const tree = container.querySelector("#cglc-tree");
    const node = (tree ? tree.querySelectorAll("[data-node]") : []).filter(function (b) {
      return b.getAttribute("data-node") === "obj-1";
    })[0];
    if (!node) { console.error("FAIL: 大纲树未渲染 obj-1 节点"); process.exit(1); }
    (node.listeners.click || []).forEach(function (fn) { fn(); });
    await sleep(50);

    const html = container.innerHTML;
    const checks = {
      typed_web_https_link: html.includes('href="https://example.com/docs"'),
      typed_video_bilibili_link: html.includes('href="https://www.bilibili.com/video/BV1xx411c7mD"'),
      no_javascript_scheme_anywhere: html.indexOf("javascript:") === -1,
      legacy_notice_shown: html.includes("需重新保存为 typed Material") && html.includes("旧行材料"),
      bad_scheme_web_plain_title: html.includes("危险链接"),
      content_route_not_fetched: !calls.fetches.some(function (p) { return /\/content$/.test(p); }),
      revision_route_fetched: calls.fetches.some(function (p) { return /\/revision$/.test(p); }),
    };

    const failed = Object.entries(checks).filter(([, v]) => !v);
    if (failed.length > 0) {
      console.error("FAIL: " + failed.map(([k]) => k).join(", "));
      console.error("html: " + html.slice(0, 1200));
      process.exit(1);
    }
    console.log("OK " + scenario + " " + JSON.stringify(checks));
    return;
  }

  // admin_aside(P0):session.aside 挂载 + 待办行可点注入 + 动作分组注入 +
  // web 深链 + tool_used 事件驱动刷新(debounce 后 /tasks 重拉)
  if (scenario === "admin_aside") {
    const mounted = globalThis.__mounted || {};
    if (typeof mounted.cb !== "function") { console.error("FAIL: mount 未捕获回调"); process.exit(1); }
    if (mounted.slot !== "session.aside") { console.error("FAIL: slot ≠ session.aside"); process.exit(1); }

    // agentProfile 不匹配不渲染(attach cgc-admin 纪律)
    const stray = el("div");
    mounted.cb(stray, { agentProfile: "cgc-tutor", sessionId: "s-x" });

    const container = el("div");
    mounted.cb(container, { agentProfile: "cgc-admin", sessionId: "s1" });
    await sleep(50);   // boot:workspaces → tasks + status

    // 查询锚在面板根(container.children[0] = view.js 的 root)——bind 绑定的
    // listener 缓存在同一节点的 html 快照上,从容器层查询拿到的是另一批节点
    const panel = container.children[0];
    const html = container.innerHTML;
    const taskRows = panel.querySelectorAll("[data-task-idx]");
    const actions = panel.querySelectorAll("[data-action]");
    const links = panel.querySelectorAll("[data-link-url]");


    // 点击第一行待办(报名审批) → prompt fallback 注入处理指令
    ((taskRows[0] && taskRows[0].listeners.click) || []).forEach(function (fn) { fn(); });
    const taskInject = globalThis.__prompted || "";
    // 点击「加入申请」动作钮 → 注入
    const joinBtn = actions.filter(function (b) { return b.getAttribute("data-action") === "join-requests"; })[0];
    ((joinBtn && joinBtn.listeners.click) || []).forEach(function (fn) { fn(); });
    const actionInject = globalThis.__prompted || "";
    // 点击首个深链(成员) → window.open
    ((links[0] && links[0].listeners.click) || []).forEach(function (fn) { fn(); });

    // 事件驱动刷新:ok 事件 debounce 后重拉 /tasks;error 事件不触发
    const tasksFetches = function () {
      return calls.fetches.filter(function (p) { return p === "/api/ext/cgc-2046/tasks"; }).length;
    };
    const beforeOk = tasksFetches();
    (globalThis.__subs["ext.cgc-2046.tool_used"] || []).forEach(function (fn) { fn({ status: "error" }); });
    await sleep(500);
    const afterError = tasksFetches();
    (globalThis.__subs["ext.cgc-2046.tool_used"] || []).forEach(function (fn) { fn({ status: "ok" }); });
    await sleep(800);  // debounce 400ms + 重拉渲染余量(原 500ms 在批量负载下偶发不足)
    const afterOk = tasksFetches();

    // P3:供给区统一投影(课程+活动,kind 徽章;draft 课叠教研徽章,open 活动叠报名徽章)
    const supplyOk = html.includes("课程与活动(3)") &&
      html.includes("Python 入门") && html.includes("数据科学营") && html.includes("线下沙龙") &&
      html.includes("草稿") && html.includes("待审核") && html.includes("报名中") &&
      html.includes(">课程</span>") && html.includes(">活动</span>") &&
      html.includes("cgaa-badge-kind-course") && html.includes("cgaa-badge-kind-event");
    // P1:订单区非终态优先(refund_failed 首行)
    // 注意力面:非终态才渲染(已支付终态不出现),refund_failed 首行,帽 5 + 尾行
    const ordersOk = html.indexOf("订单需处理（6）") >= 0 &&
      html.indexOf("退款失败") >= 0 && html.indexOf("退款失败") < html.indexOf("待支付") &&
      html.indexOf("已支付") < 0 && html.includes("¥99.00") && html.includes("还有 1 笔非终态");
    // P1:课程行点击展开报名队列(懒加载 /workspace/enrollments)
    const offeringBtns = panel.querySelectorAll("[data-offering-id]");
    const c1 = offeringBtns.filter(function (b) { return b.getAttribute("data-offering-id") === "c-1"; })[0];
    ((c1 && c1.listeners.click) || []).forEach(function (fn) { fn(); });
    await sleep(50);
    const html2 = container.innerHTML;
    const enrollFetched = calls.fetches.includes("/api/ext/cgc-2046/workspace/enrollments");
    const courseKindFetch = calls.urls.some(function (u) {
      return u.indexOf("/workspace/enrollments") >= 0 && u.indexOf("kind=course") >= 0;
    });
    // P4:draft 课展开动作排(发布/取消 + 对话修改 + 网站编辑深链;无「结束」)
    const draftActionsOk = html2.indexOf("发布") >= 0 && html2.indexOf("取消") >= 0 &&
      html2.indexOf("结束") < 0 && html2.indexOf("✎ 对话修改") >= 0 &&
      html2.indexOf("/w/acme/courses/c-1") >= 0;
    const c1Launch = panel.querySelectorAll("[data-lc-action]").filter(function (b) {
      return b.getAttribute("data-lc-id") === "c-1" && b.getAttribute("data-lc-action") === "launch";
    })[0];
    ((c1Launch && c1Launch.listeners.click) || []).forEach(function (fn) { fn(); });
    const lcInject = globalThis.__prompted || "";
    const c1Edit = panel.querySelectorAll("[data-edit-inject]").filter(function (b) {
      return b.getAttribute("data-lc-id") === "c-1";
    })[0];
    ((c1Edit && c1Edit.listeners.click) || []).forEach(function (fn) { fn(); });
    const editInject = globalThis.__prompted || "";
    // P1:可行动报名行(pending)点击 → 注入含 list_enrollments + enrollment_id
    const enrollRows = panel.querySelectorAll("[data-enroll-offering]");
    ((enrollRows[0] && enrollRows[0].listeners.click) || []).forEach(function (fn) { fn(); });
    const enrollInject = globalThis.__prompted || "";
    // P3:活动行点击下钻(kind=event 分派);活动报名行注入带 event 语义
    const ev1 = panel.querySelectorAll("[data-offering-id]")
      .filter(function (b) { return b.getAttribute("data-offering-id") === "ev-1"; })[0];
    ((ev1 && ev1.listeners.click) || []).forEach(function (fn) { fn(); });
    await sleep(50);
    const eventKindFetch = calls.urls.some(function (u) {
      return u.indexOf("/workspace/enrollments") >= 0 && u.indexOf("kind=event") >= 0;
    });
    const evEnrollRows = panel.querySelectorAll("[data-enroll-offering]")
      .filter(function (b) { return b.getAttribute("data-enroll-kind") === "event"; });
    ((evEnrollRows[0] && evEnrollRows[0].listeners.click) || []).forEach(function (fn) { fn(); });
    const evEnrollInject = globalThis.__prompted || "";
    // P4:open 活动展开动作排(结束/取消 + 活动编辑深链;c-1 已收起故无「发布」)
    const html3 = container.innerHTML;
    const openActionsOk = html3.indexOf("结束") >= 0 && html3.indexOf("取消") >= 0 &&
      html3.indexOf("发布") < 0 && html3.indexOf("/w/acme/events/ev-1") >= 0;
    // P3:创建活动动作注入
    const eventBtn = panel.querySelectorAll("[data-action]")
      .filter(function (b) { return b.getAttribute("data-action") === "create-event"; })[0];
    ((eventBtn && eventBtn.listeners.click) || []).forEach(function (fn) { fn(); });
    const eventInject = globalThis.__prompted || "";
    // P1:订单首行(refund_failed o-2)点击 → 注入查看指令
    const orderRows = panel.querySelectorAll("[data-order-idx]");
    ((orderRows[0] && orderRows[0].listeners.click) || []).forEach(function (fn) { fn(); });
    const orderInject = globalThis.__prompted || "";
    const checks = {
      wrong_agent_not_rendered: stray.innerHTML === "",

      admin_workspace_rendered: html.includes("编程少女台"),
      member_only_filtered: !html.includes("普通成员台"),
      task_rows_clickable: taskRows.length === 2,
      task_row_injects_prompt: taskInject.includes("报名审批") && taskInject.includes("Python 入门营") &&
        taskInject.includes("[编程少女台]") && taskInject.includes("list_my_tasks"),
      action_group_injects: actionInject.includes("待审批加入申请"),
      deeplinks_rendered: links.length === 8 &&
        (links[0].getAttribute("data-link-url") || "").includes("/w/acme/settings/members"),
      deeplink_opens: (globalThis.__opened || []).some(function (u) { return u.indexOf("/w/acme/settings/members") >= 0; }),
      error_event_no_refresh: afterError === beforeOk,
      supply_section_rendered: supplyOk,
      orders_attention_sorted: ordersOk,
      course_drilldown_fetches_enrollments: enrollFetched && html2.includes("小安") && html2.includes("待审批"),
      course_drilldown_kind: courseKindFetch,
      event_drilldown_kind: eventKindFetch,
      draft_row_actions: draftActionsOk,
      launch_action_injects: lcInject.includes("launch_course") && lcInject.includes("course_id=c-1"),
      edit_action_injects: editInject.includes("update_course") && editInject.includes("course_id=c-1"),
      open_row_actions: openActionsOk,
      event_enroll_injects: evEnrollInject.includes("活动") && evEnrollInject.includes("kind=event"),
      create_event_action_injects: eventInject.includes("创建一场新活动"),
      pending_enroll_injects: enrollInject.includes("list_enrollments") && enrollInject.includes("e-1"),
      order_row_injects: orderInject.includes("o-2"),
      ok_event_refreshes: afterOk > afterError,
    };

    const failed = Object.entries(checks).filter(([, v]) => !v);
    if (failed.length > 0) {
      console.error("FAIL: " + failed.map(([k]) => k).join(", "));
      console.error("html: " + html.slice(0, 1000));
      console.error("prompted: " + taskInject);
      process.exit(1);
    }
    console.log("OK " + scenario + " " + JSON.stringify(checks));
    return;
  }

  // ⑧ home_hub(cgc-home 行为迁移):已连接态渲染(状态 pill/角色目录/XSS 转义)
  // + 管理会话启动(POST /api/sessions → select → 注入指令) + 断开连接 403 CSRF 自愈
  if (scenario === "home_hub") {
    const container = el("div");
    spec.render(container);
    await sleep(150);   // boot:status → workspaces/tasks/activity/sessions

    const pillText = (container.querySelector("#cgc-state-pill") || {}).textContent || "";
    const bootHtml = container.innerHTML;

    // owner 角色 → 「工作台管理」目录卡;点击 → 建管理会话(绑定节点缓存在
    // #cgc-catalog 子节点的 html 快照上,场景段必须从同一子节点查询)
    const catalogEl = container.querySelector("#cgc-catalog");
    const cards = catalogEl.querySelectorAll("[data-catalog]");
    const wsadmin = cards.filter(function (b) { return b.getAttribute("data-catalog") === "wsadmin"; })[0];
    ((wsadmin && wsadmin.listeners.click) || []).forEach(function (fn) { fn(); });
    await sleep(1700);  // startAdminSession 的注入延迟 setTimeout(1500)

    // 断开连接:首次 DELETE 403 → Kit CSRF 自愈(403 body 换 token) → 重试 200
    const discBtn = container.querySelector("#cgc-disconnect");
    const discHandlers = (discBtn && discBtn.listeners.click) || [];
    for (const fn of discHandlers) await fn();
    await sleep(100);

    // 最近会话行(仅 cgc-assistant 会话入列)点击 → Router.navigate 进会话
    const sessRows = container.querySelector("#cgc-recent-sessions").querySelectorAll("[data-session]");
    ((sessRows[0] && sessRows[0].listeners.click) || []).forEach(function (fn) { fn(); });

    // 事件总线:tool_used 推送 → 活动区渲染
    (globalThis.__subs["ext.cgc-2046.tool_used"] || []).forEach(function (fn) {
      fn({ type: "tool_used", tool: "list_my_tasks", status: "ok" });
    });
    const htmlAfterEvent = container.innerHTML;

    // 聚焦重拉:visibilitychange(未隐藏且已连接)→ loadWorkspaces 重拉
    const wsFetchesBefore = calls.fetches.filter(function (p) { return p === "/api/ext/cgc-2046/me/workspaces"; }).length;
    (globalThis.__docListeners["visibilitychange"] || []).forEach(function (fn) { fn(); });
    await sleep(50);
    const wsFetchesAfter = calls.fetches.filter(function (p) { return p === "/api/ext/cgc-2046/me/workspaces"; }).length;

    // 工作台切换:沿用旧 LS key,已持久化选择不丢失
    const wrap = container.querySelector("#cgc-identity-wrap");
    ((wrap.listeners.change) || []).forEach(function (fn) { fn({ target: { id: "cgc-ws-select", value: "ws-h2" } }); });
    await sleep(50);

    const statusFetches = calls.fetches.filter(function (p) { return p === "/api/ext/cgc-2046/status"; }).length;
    const reg = globalThis.__registered || {};
    const checks = {
      pill_connected: pillText.indexOf("已连接") >= 0,
      nav_mount_top: !!(globalThis.__mounted && globalThis.__mounted.slot === "sidebar.nav.top" &&
        globalThis.__mounted.opts && globalThis.__mounted.opts.workspace === "cgc"),
      admin_card_rendered: bootHtml.indexOf('data-catalog="wsadmin"') >= 0 && bootHtml.indexOf("工作台管理") >= 0,
      tutor_card_gated_by_role: bootHtml.indexOf('data-catalog="tutor"') < 0,
      xss_escaped: bootHtml.indexOf("<img src=x onerror") < 0 && bootHtml.indexOf("&lt;img") >= 0,
      tasks_aggregated_cross_workspace: bootHtml.indexOf("报名审批") >= 0 && bootHtml.indexOf("Python 入门营") >= 0,
      tasks_partial_failure_tolerated: bootHtml.indexOf("待办加载失败") < 0,
      recent_session_filtered_by_agent: bootHtml.indexOf("旧诊断会话") >= 0 && bootHtml.indexOf("别的助手会话") < 0,
      session_row_navigates: !!(globalThis.__navigated && globalThis.__navigated.name === "session" && globalThis.__navigated.params.id === "sess-old"),
      focus_reload_refetches_workspaces: wsFetchesAfter === wsFetchesBefore + 1,
      workspace_selection_keeps_storage_key: store.get("cgc2046.workspacePanel.workspaceId") === "ws-h2",
      tool_used_renders_activity: htmlAfterEvent.indexOf("list_my_tasks") >= 0,
      token_not_rendered_to_dom: bootHtml.indexOf("tok-1") < 0 && htmlAfterEvent.indexOf("tok-1") < 0,
      session_posted_admin: !!(globalThis.__sessionPostBody && globalThis.__sessionPostBody.agent_profile === "cgc-admin"),
      session_selected: globalThis.__sessionSelected === "sess-1",
      admin_instruction_injected: (globalThis.__prompted || "").indexOf("管理助手") >= 0 &&
        (globalThis.__prompted || "").indexOf("list_my_workspaces") >= 0,
      delete_retried_on_403: (globalThis.__deleteAttempts || 0) === 2,

      delete_sends_empty_json_body: (globalThis.__deleteBodies || []).length === 2 &&
        (globalThis.__deleteBodies || []).every(function (b) { return b === "{}"; }),
      status_refreshed_after_disconnect: statusFetches >= 2,
      disconnect_toast: (globalThis.__toasts || []).some(function (t) { return t.indexOf("已断开") >= 0; }),
    };
    const failed = Object.entries(checks).filter(([, v]) => !v);
    if (failed.length > 0) {
      console.error("FAIL: " + failed.map(([k]) => k).join(", "));
      console.error("html: " + bootHtml.slice(0, 800));
      console.error("pill: " + pillText + " | prompted: " + (globalThis.__prompted || "") + " | toasts: " + JSON.stringify(globalThis.__toasts || []));
      process.exit(1);
    }
    console.log("OK " + scenario + " " + JSON.stringify(checks));
    return;
  }


  // ⑧ home_unconnected:未连接态渲染连接引导(pill/引导卡),目录收起为提示
  if (scenario === "home_unconnected") {
    const container = el("div");
    spec.render(container);
    await sleep(150);

    const pillText = (container.querySelector("#cgc-state-pill") || {}).textContent || "";
    const html = container.innerHTML;
    const checks = {
      pill_unconnected: pillText.indexOf("未连接") >= 0,
      guide_rendered: html.indexOf("cgc-connect-guide") >= 0 && html.indexOf("还未连接 CGC-2046") >= 0,
      catalog_not_rendered: html.indexOf("data-catalog=") < 0,
      onboarding_hint: html.indexOf("cgc2046-onboarding") >= 0,
    };
    const failed = Object.entries(checks).filter(([, v]) => !v);
    if (failed.length > 0) {
      console.error("FAIL: " + failed.map(([k]) => k).join(", "));
      console.error("html: " + html.slice(0, 800));
      process.exit(1);
    }
    console.log("OK " + scenario + " " + JSON.stringify(checks));
    return;
  }

  // ⑧ home_tasks_failed:全部工作台 tasks 请求失败 → 渲染错误态而非「暂无待办」
  // (空态会掩盖后端不可用/token 过期——与被选中台遮蔽同款静默错)
  if (scenario === "home_tasks_failed") {
    const container = el("div");
    spec.render(container);
    await sleep(150);
    const html = container.innerHTML;
    const checks = {
      tasks_all_failed_renders_error: html.indexOf("待办加载失败") >= 0,
      not_silent_empty: html.indexOf("暂无待办") < 0,
    };
    const failed = Object.entries(checks).filter(([, v]) => !v);
    if (failed.length > 0) {
      console.error("FAIL: " + failed.map(([k]) => k).join(", "));
      console.error("html: " + html.slice(0, 800));
      process.exit(1);
    }
    console.log("OK " + scenario + " " + JSON.stringify(checks));
    return;
  }
  // web_url scheme 门(安全评审低危#4):非法 scheme 必须等同未配置(锚隐藏/深链不渲染/
  // 目录卡隐藏);http://localhost(README 联调形态)必须放行。无门旧代码三断言必败。
  if (scenario === "home_weburl_gate") {
    const container = el("div");
    spec.render(container);
    await sleep(150);
    const phase1 = container.innerHTML;
    const webEl1 = container.querySelector("#cgc-open-web");
    const checks1 = {
      bad_scheme_anchor_hidden: !!webEl1 && webEl1.style.display === "none",
      bad_scheme_manage_hidden: phase1.indexOf("/settings/members") < 0,
      platform_admin_card_hidden: phase1.indexOf('data-catalog="admin"') < 0,
    };

    // 第二次 render → refresh 重拉 status(#2 = http://localhost:3000 合法联调形态)
    spec.render(container);
    await sleep(150);
    const phase2 = container.innerHTML;
    const webEl2 = container.querySelector("#cgc-open-web");
    const catalogEl = container.querySelector("#cgc-catalog");
    const adminCard = catalogEl.querySelectorAll("[data-catalog]")
      .filter(function (b) { return b.getAttribute("data-catalog") === "admin"; })[0];
    ((adminCard && adminCard.listeners.click) || []).forEach(function (fn) { fn(); });
    const checks2 = {
      localhost_anchor_shown: !!webEl2 && webEl2.style.display !== "none" &&
        webEl2.href === "http://localhost:3000",
      localhost_manage_link: phase2.indexOf('href="http://localhost:3000/w/gate/settings/members"') >= 0,
      platform_admin_card_shown: !!adminCard,
      admin_card_opens_localhost: (globalThis.__opened || []).indexOf("http://localhost:3000") >= 0,
    };

    const checks = Object.assign({}, checks1, checks2);
    const failed = Object.entries(checks).filter(([, v]) => !v);
    if (failed.length > 0) {
      console.error("FAIL: " + failed.map(([k]) => k).join(", "));
      console.error("phase1: " + phase1.slice(0, 600));
      console.error("phase2: " + phase2.slice(0, 600));
      process.exit(1);
    }
    console.log("OK " + scenario + " " + JSON.stringify(checks));
    return;
  }

  // web_url scheme 门(安全评审低危#4):discovery 详情链接——非法 scheme 标题退化纯文本;
  // 合法 https 但含引号必须转义(属性逃逸,旧代码必败)。两阶段经 #cgc-refresh 切换。
  if (scenario === "discovery_weburl_gate") {
    const container = el("div");
    spec.render(container);
    await sleep(150);
    const phase1 = container.innerHTML;
    const checks1 = {
      bad_scheme_no_anchor: phase1.indexOf("cgc-offering-link") < 0,
      title_degrades_plain: phase1.indexOf('<span class="task-name">门测沙龙</span>') >= 0,
    };

    // 刷新钮 → loadOfferings → status#2(https + 引号走私,过 scheme 门后考转义)
    const refresh = container.querySelector("#cgc-refresh");
    ((refresh && refresh.listeners.click) || []).forEach(function (fn) { fn(); });
    await sleep(150);
    const phase2 = container.innerHTML;
    const checks2 = {
      detail_anchor_rendered: phase2.indexOf("cgc-offering-link") >= 0,
      attr_breakout_escaped: phase2.indexOf('"onmouseover="') < 0 && phase2.indexOf("&quot;onmouseover=") >= 0,
      detail_url_correct: phase2.indexOf("https://gate.example.com/") >= 0 && phase2.indexOf("/events/salon-gate") >= 0,
    };

    const checks = Object.assign({}, checks1, checks2);
    const failed = Object.entries(checks).filter(([, v]) => !v);
    if (failed.length > 0) {
      console.error("FAIL: " + failed.map(([k]) => k).join(", "));
      console.error("phase1: " + phase1.slice(0, 600));
      console.error("phase2: " + phase2.slice(0, 600));
      process.exit(1);
    }
    console.log("OK " + scenario + " " + JSON.stringify(checks));
    return;
  }

  // ⑧ learn_boot_and_inject(cgc-learn 行为迁移):boot 列表渲染(掌握度/复习/锁定)
  // + 学习目标注入(草稿保留追加 + 发送点击) + 复习注入(到期复习文案)
  if (scenario === "learn_boot_and_inject") {
    const mounted = globalThis.__mounted || {};
    if (typeof mounted.cb !== "function") { console.error("FAIL: mount 未捕获回调"); process.exit(1); }
    const container = el("div");
    mounted.cb(container, { agentProfile: "cgc-assistant", sessionId: "s-l1" });
    await sleep(150);   // boot:enrollments → learning_state + revision

    const panel = container.children[0];   // learn 渲染进子 root,绑定节点缓存其上
    const html = container.innerHTML;
    const input = __domById["user-input"];

    const injectBtns = panel.querySelectorAll("[data-inject]");
    const learnBtn = injectBtns.filter(function (b) { return b.getAttribute("data-inject") === "obj-1" && !b.getAttribute("data-review"); })[0];
    ((learnBtn && learnBtn.listeners.click) || []).forEach(function (fn) { fn(); });
    const afterLearnText = input ? input.textContent : "";
    const learnSent = globalThis.__sendClicked || 0;

    const reviewBtn = injectBtns.filter(function (b) { return b.getAttribute("data-review") === "1"; })[0];
    ((reviewBtn && reviewBtn.listeners.click) || []).forEach(function (fn) { fn(); });
    const afterReviewText = input ? input.textContent : "";

    const checks = {
      mounted_as_assistant_aside: mounted.slot === "session.aside" &&
        !!(mounted.opts && (mounted.opts.agents || []).indexOf("cgc-assistant") >= 0),
      course_listed: html.indexOf("零成员公开课") >= 0,
      mastery_rendered: html.indexOf("学习中") >= 0,
      // 到期复习优先于 next_action(设计语义):resume 卡取复习条目
      resume_card_prioritizes_review: html.indexOf("继续复习") >= 0 && html.indexOf("配置开发环境") >= 0,
      locked_not_injectable: html.indexOf("进阶锁定目标") >= 0 && html.indexOf('data-inject="obj-2"') < 0,
      review_entry_rendered: !!reviewBtn,
      draft_preserved: afterLearnText.indexOf("我的补充问题草稿") >= 0,
      instruction_appended: afterLearnText.indexOf("配置开发环境") >= 0,
      send_clicked: learnSent > 0,
      review_prompt_marked: afterReviewText.indexOf("到期复习") >= 0,
    };
    const failed = Object.entries(checks).filter(([, v]) => !v);
    if (failed.length > 0) {
      console.error("FAIL: " + failed.map(([k]) => k).join(", "));
      console.error("html: " + html.slice(0, 800));
      console.error("input: " + afterLearnText.slice(0, 300));
      process.exit(1);
    }
    console.log("OK " + scenario + " " + JSON.stringify(checks));
    return;
  }

  // ⑧ tutor_aside_boot(cgc-tutor aside 行为迁移):session.aside 挂载门控 +
  // tutor 台课程发现(学员台过滤) + 自动选课后的 content/prep 草稿拉取
  if (scenario === "tutor_aside_boot") {
    const mounted = globalThis.__mounted || {};
    if (typeof mounted.cb !== "function") { console.error("FAIL: mount 未捕获回调"); process.exit(1); }
    if (mounted.slot !== "session.aside") { console.error("FAIL: slot ≠ session.aside"); process.exit(1); }

    // agentProfile 不匹配不渲染(attach cgc-tutor 纪律)
    const stray = el("div");
    mounted.cb(stray, { agentProfile: "cgc-admin", sessionId: "s-x" });

    const container = el("div");
    mounted.cb(container, { agentProfile: "cgc-tutor", sessionId: "s-t1" });
    await sleep(150);   // loadCourses → 自动选首门 → refreshDraft(content+prep)

    const html = container.innerHTML;
    const checks = {
      wrong_agent_not_rendered: stray.innerHTML === "",
      tutor_workspace_scoped: calls.urls.some(function (u) {
        return u.indexOf("/workspace/courses?workspace_id=ws-t9") >= 0;
      }) && !calls.urls.some(function (u) { return u.indexOf("workspace_id=ws-m1") >= 0; }),
      course_rendered: html.indexOf("教研草稿课") >= 0,
      draft_badge_rendered: html.indexOf("未发布") >= 0,
      content_fetched: calls.urls.some(function (u) { return u.indexOf("/courses/c-9/content") >= 0; }),
      prep_fetched: calls.urls.some(function (u) { return u.indexOf("/courses/c-9/prep") >= 0; }),
      objective_rendered: html.indexOf("目标一") >= 0,
      poll_started: timers.length >= 1,
      rewrite_button_rendered: html.indexOf('data-rewrite="o-1"') >= 0,
    };
    const failed = Object.entries(checks).filter(([, v]) => !v);
    if (failed.length > 0) {
      console.error("FAIL: " + failed.map(([k]) => k).join(", "));
      console.error("html: " + html.slice(0, 800));
      console.error("urls: " + JSON.stringify(calls.urls));
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
