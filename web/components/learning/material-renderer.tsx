"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
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
 * 刻意小的 Markdown 子集（escape-first：任何 HTML 先实体转义，永不进入 DOM）：
 * - `# `/`## `/`### ` 行 → <h2>/<h3>/<h4>
 * - 连续 `- ` 行 → 单个 <ul> 内多条 <li>
 * - 行内 **粗体**、`行内代码`
 * - 普通行之间换行 → <br />
 * 不支持链接/图片/嵌套列表；富格式走 typed Material 的其它 kind。
 */
function markdownToSafeHtml(source: string): string {
  const escaped = source
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
  const inline = (text: string) =>
    text
      .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
      .replace(/`([^`]+)`/g, "<code>$1</code>");
  const HEADING_TAG: Record<number, string> = { 1: "h2", 2: "h3", 3: "h4" };
  const out: string[] = [];
  let listOpen = false;
  let prevPlain = false;
  for (const line of escaped.split("\n")) {
    const heading = /^(#{1,3}) (.+)$/.exec(line);
    const item = /^- (.+)$/.exec(line);
    if (item) {
      if (!listOpen) {
        out.push("<ul>");
        listOpen = true;
      }
      out.push(`<li>${inline(item[1])}</li>`);
      prevPlain = false;
      continue;
    }
    if (listOpen) {
      out.push("</ul>");
      listOpen = false;
    }
    if (heading) {
      const tag = HEADING_TAG[heading[1].length];
      out.push(`<${tag}>${inline(heading[2])}</${tag}>`);
      prevPlain = false;
      continue;
    }
    if (prevPlain) out.push("<br />");
    out.push(inline(line));
    prevPlain = true;
  }
  if (listOpen) out.push("</ul>");
  return out.join("");
}

export function MaterialRenderer({ material }: { material: TypedMaterial }) {
  const t = useTranslations("material");
  const title = material.title || t("title");
  const [imageState, setImageState] = useState<"loading" | "loaded" | "error">("loading");
  const [playing, setPlaying] = useState(false);

  if (material.kind === "text") {
    return <p data-testid="course-material-text">{material.body || ""}</p>;
  }
  if (material.kind === "markdown") {
    return (
      <div
        className="learning-material learning-material--markdown"
        data-testid="course-material-markdown"
        dangerouslySetInnerHTML={{ __html: markdownToSafeHtml(material.body || "") }}
      />
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
    const src = `https://player.bilibili.com/player.html?bvid=${encodeURIComponent(material.external_id)}&page=1`;
    return (
      <div className="learning-material learning-material--video" data-testid="course-material-video">
        {playing ? (
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
