"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import ReactMarkdown, { type Components, type Options as ReactMarkdownOptions } from "react-markdown";
import rehypeKatex from "rehype-katex";
import rehypeSanitize, { defaultSchema } from "rehype-sanitize";
import remarkBreaks from "remark-breaks";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import "katex/dist/katex.min.css";
import type { TypedMaterial } from "@/lib/graphql/course-content";

const BILIBILI_ID = /^BV[0-9A-Za-z]{10}$/;

function safeHttpsUrl(value: string | undefined): string | null {
  if (!value) return null;
  try {
    const url = new URL(value);
    return url.protocol === "https:" ? url.toString() : null;
  } catch {
    return null;
  }
}

/**
 * Markdown 渲染：react-markdown + remark-gfm（表格 / 删除线 / 自动链接）+
 * remark-breaks（单换行 → <br />，与讲义历史排版一致），产出再经 rehype-sanitize
 * 白名单过滤。
 *
 * 安全契约（沿用旧 escape-first 语义）：
 * - react-markdown 默认不渲染原始 HTML，`<script>` 之类只作为文本出现；
 *   sanitize 再按白名单收窄标签、属性与 id。
 * - 危险协议由 react-markdown 默认的 urlTransform 处理（`javascript:` 被换成空 href），
 *   组件再把它降级为纯文本——空 href 会以新窗口打开当前页。
 * - 图片不直连第三方：`img` 覆写为指向原地址的 https 链接（外链统一 rel=noopener）。
 * - 标题降一级（`#` → h2），避免课程正文级联到页面 h1 语义。
 *
 * 旧实现是刻意做小的子集（仅标题 / `- ` 列表 / 粗体 / 行内代码），讲义里的 GFM
 * 表格会退化成竖线纯文本，故整体换用成熟渲染器（#1118）。
 *
 * 讲义里的原始 HTML 改为转义文本，而不是被静默吞掉（旧实现是 escape-first：
 * `<script>` 以 `&lt;script&gt;` 出现在正文里）。作者写 `<你的文件名>` 这类
 * 占位符时不会凭空少一段，攻击面仍然为零——节点降级成 text，不产生元素。
 */
type HastNode = { type: string; value?: string; children?: HastNode[] };

function rawHtmlAsText() {
  const walk = (node: HastNode) => {
    if (!node.children) return;
    node.children = node.children.flatMap((child) => {
      if (child.type === "raw" || child.type === "html") {
        return [{ type: "text", value: child.value ?? "" }];
      }
      walk(child);
      return [child];
    });
  };
  return (tree: HastNode) => walk(tree);
}

type MarkdownPlugins = NonNullable<ReactMarkdownOptions["remarkPlugins"]>;
const MARKDOWN_REMARK_PLUGINS: MarkdownPlugins = [remarkGfm, remarkMath, remarkBreaks];

// 公式（$…$ / $$…$$）：remark-math 先把公式标成带 math-inline / math-display 类的 code 节点，
// sanitize 白名单放行这两个类名，sanitize 之后才由 rehype-katex 渲染。顺序不能反：katex 产出的
// span 带大量 class 与 style，先渲染再 sanitize 会把公式剥碎。katex 保持默认 trust: false
// （\href、\url、\includegraphics 不产生链接或外链资源），并限制 maxSize / maxExpand，
// 恶意公式卡不死页面；写错的公式按原文红字显示，不抛错。
const SANITIZE_SCHEMA = {
  ...defaultSchema,
  clobberPrefix: "",
  attributes: {
    ...defaultSchema.attributes,
    code: [...(defaultSchema.attributes?.code ?? []), ["className", /^language-./, "math-inline", "math-display"]],
  },
};
const KATEX_OPTIONS = { throwOnError: false, trust: false, strict: "ignore", maxSize: 20, maxExpand: 200 } as const;
// rehype-sanitize 的默认 clobberPrefix 会给 id/name 再加一层 `user-content-`，而 remark-gfm
// 生成的脚注引用 href 已是 `#user-content-fn-1` —— 二次前缀让 id 变成
// `user-content-user-content-fn-1`，脚注跳转变死链。前缀由库自己加好，这里置空。
// 协议面不靠 sanitize：react-markdown 的默认 urlTransform 已把 `javascript:` 等危险
// 协议替换为「空 href」（实测去掉 sanitize 后协议守卫仍绿），sanitize 承担的是标签、
// 属性与 id 白名单。
const MARKDOWN_REHYPE_PLUGINS: MarkdownPlugins = [rawHtmlAsText, [rehypeSanitize, SANITIZE_SCHEMA], [rehypeKatex, KATEX_OPTIONS]];

// react-markdown 的组件覆写表（ElementType 契约）：标题降一级、外链统一新窗口、
// 表格包横向滚动容器。className 由这里挂，不来自正文（sanitize 会剥掉正文属性）。
const MARKDOWN_COMPONENTS: Components = {
  h1: ({ children }) => <h2>{children}</h2>,
  h2: ({ children }) => <h3>{children}</h3>,
  h3: ({ children }) => <h4>{children}</h4>,
  // 正文列是窄栏（桌面三列网格的中间列），宽表靠容器横向滚动而不是撑破布局
  table: ({ children }) => (
    <div className="learning-material__table-wrap">
      <table>{children}</table>
    </div>
  ),
  // 外链统一新窗口；同页片段（脚注引用/回链、目录锚点）留在本页——否则点脚注会开一个
  // 同页新标签。危险协议被 react-markdown 的默认 urlTransform 换成空 href，那种情况
  // 不能渲染成会打开当前页的链接，退化为纯文本。
  a: ({ href, children }) =>
    !href ? (
      <span>{children}</span>
    ) : href.startsWith("#") ? (
      <a href={href}>{children}</a>
    ) : (
      <a href={href} target="_blank" rel="noopener noreferrer">
        {children}
      </a>
    ),
  img: ({ src, alt }) => {
    const url = safeHttpsUrl(typeof src === "string" ? src : undefined);
    const label = alt || url;
    if (!label) return null;
    return url ? (
      <a href={url} target="_blank" rel="noopener noreferrer">
        {label}
      </a>
    ) : (
      <span>{label}</span>
    );
  },
};

/**
 * 不可信 Markdown 的唯一渲染入口：课程讲义（tutor 撰写）与课程页对话栏里 agent 的回复（可能被讲义注入影响）共用，
 * 安全规则只此一份（见上方注释）。
 */
export function SafeMarkdown({ children }: { children: string }) {
  return (
    <ReactMarkdown remarkPlugins={MARKDOWN_REMARK_PLUGINS} rehypePlugins={MARKDOWN_REHYPE_PLUGINS} components={MARKDOWN_COMPONENTS}>
      {children}
    </ReactMarkdown>
  );
}

export function MaterialRenderer({ material, autoPlay = false }: { material: TypedMaterial; autoPlay?: boolean }) {
  const t = useTranslations("material");
  const title = material.title || t("title");
  const [imageState, setImageState] = useState<"loading" | "loaded" | "error">("loading");
  const [playing, setPlaying] = useState(false);

  if (material.kind === "text") {
    return <p data-testid="course-material-text">{material.body || ""}</p>;
  }
  if (material.kind === "markdown") {
    return (
      <div className="learning-material learning-material--markdown" data-testid="course-material-markdown">
        <SafeMarkdown>{material.body || ""}</SafeMarkdown>
      </div>
    );
  }
  if (material.kind === "image") {
    const url = safeHttpsUrl(material.url);
    if (!url || !material.alt_text?.trim()) {
      return <span data-testid="course-material-unavailable">{title}{t("imageUnavailable")}</span>;
    }
    return (
      <figure className="learning-material learning-material--image" data-testid="course-material-image">
        {imageState === "loading" ? <span data-testid="course-material-image-loading">{t("imageLoading")}</span> : null}
        {imageState === "error" ? <span data-testid="course-material-image-error">{t("imageError")}</span> : null}
        <img
          src={url}
          alt={material.alt_text}
          loading="lazy"
          onLoad={() => setImageState("loaded")}
          onError={() => setImageState("error")}
          hidden={imageState !== "loaded"}
        />
        {material.caption ? <figcaption>{material.caption}</figcaption> : null}
      </figure>
    );
  }
  if (material.kind === "video") {
    if (material.provider !== "bilibili" || !material.external_id || !BILIBILI_ID.test(material.external_id)) {
      const fallback = safeHttpsUrl(material.url);
      return fallback ? (
        <a href={fallback} target="_blank" rel="noopener noreferrer" data-testid="course-material-link">
          {title}{t("externalVideo")}
        </a>
      ) : <span data-testid="course-material-unavailable">{title}{t("providerUnavailable")}</span>;
    }
    // autoplay=1 对点击按钮挂载的路径无副作用：挂载即播放，浏览器策略拦截时 B 站播放器退化为手动播放键
    const src = `https://player.bilibili.com/player.html?bvid=${encodeURIComponent(material.external_id)}&page=1&autoplay=1`;
    return (
      <div className="learning-material learning-material--video" data-testid="course-material-video">
        {playing || autoPlay ? (
          <iframe
            title={title}
            src={src}
            loading="lazy"
            referrerPolicy="no-referrer"
            sandbox="allow-scripts allow-same-origin allow-presentation"
            allow="fullscreen; autoplay"
          />
        ) : (
          <button type="button" onClick={() => setPlaying(true)} data-testid="course-material-video-play">
            ▶ {t("playVideo")} · {title}
          </button>
        )}
        <a href={`https://www.bilibili.com/video/${encodeURIComponent(material.external_id)}`} target="_blank" rel="noopener noreferrer">
          {t("openBilibili")}
        </a>
      </div>
    );
  }
  const url = safeHttpsUrl(material.url);
  return url ? (
    <a href={url} target="_blank" rel="noopener noreferrer" data-testid="course-material-link">{title}</a>
  ) : <span data-testid="course-material-unavailable">{title}{t("legacy")}</span>;
}
