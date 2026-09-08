// CGC-2046 面板共享骨架(架构评审⑦):loopback 数据访问 / HTML 转义 /
// CSRF 自愈 / 注入管道 / 可见性轮询 / typed Material 渲染。
//
// 装载机制:本文件经 ext.yml `panels:` 首位声明(id: cgc-2046-shared)注入——
// 宿主按声明顺序生成 <script> 标签(loader.rb resolve_units 顺序语义 +
// http_server.rb container_ext_script_tags),先于其余 7 个面板执行,挂
// window.CgcKit。无 attach、无 agent 引用、不 mount 任何 UI → 永不显示
// (panel_agents_map 可见性语义)。
//
// 行为等价说明(原 7 面板同形拷贝归一):
//   - rawGet 错误对象统一挂 { body, status } 超集(原 admin-aside/tutor-aside/learn
//     拷贝无 body;消费方均不读 e.body,超集安全)。
//   - apiGet 不再携带 CSRF header(原 discovery 拷贝独有;GET 为安全方法,
//     guard_write! 只校验写路由,header 本就被忽略)。
//   - injectIntoComposer 补发上限统一 8s(原 learn 拷贝 5s,为当时实证描述;
//     其余 6 处均 8s,新建会话订阅确认更慢,8s 为安全并集)。
//   - materialMarkup 以 course 版为准:image 渲染 caption(2026-09-07 42e2b8c2
//     同 commit 给 course/learn 双写 typed 渲染,learn 漏同步 caption);
//     死 class 归一(course 的 cgch-mat-ref/cglc-video/cglc-material-text 均无
//     CSS 定义),统一生成 {prefix}-material / {prefix}-mat-ref,prefix = 面板
//     CSS 命名空间(learn 的 cgla-mat-ref 样式不变)。
//   - CSRF token 全局共享一份缓存:同源 /status 下发的进程级 token,各面板
//     原各自缓存同值;403 自愈刷新后全局面板受益,语义不变。

(() => {
  "use strict";
  if (!window.Clacky || !Clacky.ext || Clacky.ext.pure) return;
  if (window.CgcKit) return; // 幂等:页面热重载重复注入不重复挂载

  const API = "/api/ext/cgc-2046";

  function escapeHtml(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  // ---- CSRF(进程级 token,经 /status 同源下发;宿主热重载会轮换 → 403 自愈) ----
  let csrfToken = "";

  // 已有 /status 响应顺带喂入(home/discovery 的 status 调用点,省一次请求)
  function csrfFromStatus(body) {
    if (body && body.csrf_token) csrfToken = String(body.csrf_token);
  }

  async function ensureCsrf() {
    if (csrfToken) return;
    try {
      const res = await fetch(API + "/status", { headers: { Accept: "application/json" } });
      const body = await res.json().catch(function () { return {}; });
      if (res.ok && body.csrf_token) csrfToken = String(body.csrf_token);
    } catch (e) { /* 静默 */ }
  }

  // 重取 CSRF token(宿主热重载会轮换进程级 token——403-on-CSRF 自愈路径)
  async function refreshCsrf() {
    csrfToken = "";
    await ensureCsrf();
    return !!csrfToken;
  }

  // ---- loopback fetch 封装 ----
  // rawGet:错误挂 { body, status };body.ok === false 不视为传输层错误
  // (读路由的业务失败由调用方按 payload 判定,与原 4 拷贝语义一致)
  async function rawGet(path) {
    const res = await fetch(API + path, { headers: { Accept: "application/json" } });
    const body = await res.json().catch(function () { return {}; });
    if (!res.ok) throw Object.assign(new Error(body.error || ("HTTP " + res.status)), { body, status: res.status });
    return body;
  }

  // apiGet:workspaceId 给了就拼 query(curriculum/course 形态,空串也拼,
  // 与原拷贝一致);不给裸 GET(learn/discovery 形态)
  async function apiGet(path, workspaceId) {
    if (workspaceId == null) return rawGet(path);
    const sep = path.indexOf("?") >= 0 ? "&" : "?";
    return rawGet(path + sep + "workspace_id=" + encodeURIComponent(workspaceId));
  }

  // 写路由 POST JSON:先确保 CSRF token;403-on-CSRF 重取 token 重试一次;
  // 错误体挂 status/body
  async function apiPost(path, payload) {
    await ensureCsrf();
    let res = await fetch(API + path, { method: "POST", headers: postHeaders(), body: JSON.stringify(payload) });
    if (res.status === 403 && (await refreshCsrf())) {
      res = await fetch(API + path, { method: "POST", headers: postHeaders(), body: JSON.stringify(payload) });
    }
    const body = await res.json().catch(function () { return {}; });
    if (!res.ok) throw Object.assign(new Error(body.message || body.error || "HTTP " + res.status), { body, status: res.status });
    return body;
  }

  // 写路由 DELETE(home 断开连接):与 apiPost 同款的 CSRF 头 + 403 自愈;
  // body:"{}" 必带——fetch 规范:无 body 的请求浏览器不发送 Content-Type,
  // guard_write! 的 415 检查会误拦(真机实证);业务 ok:false 视为失败
  async function apiDelete(path) {
    const headers = postHeaders();
    let res = await fetch(API + path, { method: "DELETE", headers: headers, body: "{}" });
    if (res.status === 403 && (await refreshCsrf())) {
      headers["X-CGC-CSRF-Token"] = csrfToken;
      res = await fetch(API + path, { method: "DELETE", headers: headers, body: "{}" });
    }
    const body = await res.json().catch(function () { return {}; });
    if (!res.ok || !body.ok) throw new Error(body.error || ("HTTP " + res.status));
    return body;
  }

  function postHeaders() {
    const headers = { "Content-Type": "application/json", Accept: "application/json" };
    if (csrfToken) headers["X-CGC-CSRF-Token"] = csrfToken;
    return headers;
  }

  // ---- 注入会话管道 ----
  // contenteditable 注入(宿主 #user-input 是 DIV 非 textarea):textContent 赋值
  // (value 赋值 Composer.text 读不到,真机实证) + dispatch input + 点发送;
  // 发送按钮在会话订阅确认前禁用,200ms 轮询待启用补发(8s 上限)。
  // 输入框/按钮缺失的兜底文案各异,保留在各面板;草稿保护(learn)也在面板侧
  // 算好 finalText 后传入。
  function injectIntoComposer(input, send, text) {
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

  // ---- 可见性轮询 ----
  // ms 周期执行 tick;页面隐藏跳过本轮;opts.container 提供容器时,容器脱离
  // DOM 按 opts.detach 处理("stop" 停止轮询,默认仅跳过本轮——aside 面板
  // 反复 mount 场景由调用方在 mount 处先 stop 旧轮询)。返回 stop()。
  // discovery 支付轮询无 hidden 跳过语义且自管清理,不经本助手。
  function poll(ms, tick, opts) {
    opts = opts || {};
    var stopped = false;
    var timer = setInterval(function () {
      if (stopped) return;
      if (opts.container) {
        var el = opts.container();
        if (!el || !document.contains(el)) {
          if (opts.detach === "stop") stop();
          return;
        }
      }
      if (document.hidden) return;
      tick();
    }, ms);
    function stop() {
      if (stopped) return;
      stopped = true;
      clearInterval(timer);
    }
    return stop;
  }

  // ---- typed Material 渲染(M2) ----
  // safeMaterialUrl:scheme 门——web/image 仅 https: 进链接/img;text/markdown
  // 与非法值一律 null(永不进 href/src)
  function safeMaterialUrl(material) {
    if (!material || material.kind === "text" || material.kind === "markdown") return null;
    const url = material.url;
    if (typeof url !== "string" || !/^https:\/\//i.test(url)) return null;
    return url;
  }

  // 行内 markdown 小子集:标题/加粗/行内代码/https 链接/列表项;插值先转义
  function markdownMarkup(body) {
    return String(body || "").split(/\n+/).map(function (line) {
      var s = escapeHtml(line.trim());
      if (!s) return "";
      s = s.replace(/^###\s+(.+)$/, "<h5>$1</h5>").replace(/^##\s+(.+)$/, "<h4>$1</h4>").replace(/^#\s+(.+)$/, "<h3>$1</h3>");
      s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>").replace(/`([^`]+)`/g, "<code>$1</code>");
      s = s.replace(/\[([^\]]+)\]\((https:\/\/[^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>');
      return /^[-*]\s+/.test(s) ? "<li>" + s.replace(/^[-*]\s+/, "") + "</li>" : "<p>" + s + "</p>";
    }).join("");
  }

  // typed 分派 + scheme 门:web/image 仅 https: 进链接/img;video 仅
  // bilibili + 合法 BV 号出外链;text/markdown 标题+正文;legacy {title,ref}
  // 只显示标题 + 重存提示,ref 永不进 href。插值一律 escapeHtml。
  // prefix = 面板 CSS 命名空间;image 的 figcaption 统一渲染 caption
  function materialMarkup(material, prefix) {
    if (!material) return "";
    var title = escapeHtml(material.title || "材料");
    if (material.ref || !material.kind) {
      return '<span class="' + prefix + '-material">' + title +
        ' <span class="cgch-empty">需重新保存为 typed Material</span></span>';
    }
    if (material.kind === "text") return '<div class="' + prefix + '-material"><strong>' + title + '</strong><p>' + escapeHtml(material.body || "") + '</p></div>';
    if (material.kind === "markdown") return '<div class="' + prefix + '-material"><strong>' + title + '</strong>' + markdownMarkup(material.body) + '</div>';
    if (material.kind === "image") {
      var imageUrl = safeMaterialUrl(material);
      if (!imageUrl || !material.alt_text) return '<span class="' + prefix + '-material">' + title + '</span>';
      return '<figure class="' + prefix + '-material"><img src="' + escapeHtml(imageUrl) + '" alt="' + escapeHtml(material.alt_text) + '" loading="lazy" onerror="this.hidden=true;this.nextElementSibling.hidden=false"><span hidden>图片加载失败</span><figcaption>' + title + (material.caption ? "：" + escapeHtml(material.caption) : "") + '</figcaption></figure>';
    }
    if (material.kind === "video") {
      if (material.provider !== "bilibili" || !/^BV[0-9A-Za-z]{10}$/.test(String(material.external_id || ""))) return '<span class="' + prefix + '-material">' + title + '</span>';
      return '<a class="' + prefix + '-material ' + prefix + '-mat-ref" href="https://www.bilibili.com/video/' + encodeURIComponent(material.external_id) + '" target="_blank" rel="noopener noreferrer">▶ ' + title + '</a>';
    }
    var url = safeMaterialUrl(material);
    return url ? '<a class="' + prefix + '-material ' + prefix + '-mat-ref" href="' + escapeHtml(url) + '" target="_blank" rel="noopener noreferrer">' + title + '</a>' : '<span class="' + prefix + '-material">' + title + '</span>';
  }

  window.CgcKit = {
    API: API,
    escapeHtml: escapeHtml,
    csrfFromStatus: csrfFromStatus,
    ensureCsrf: ensureCsrf,
    refreshCsrf: refreshCsrf,
    rawGet: rawGet,
    apiGet: apiGet,
    apiPost: apiPost,
    apiDelete: apiDelete,
    injectIntoComposer: injectIntoComposer,
    poll: poll,
    safeMaterialUrl: safeMaterialUrl,
    markdownMarkup: markdownMarkup,
    materialMarkup: materialMarkup
  };
})();
