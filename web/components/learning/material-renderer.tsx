"use client";

import { useState } from "react";
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

function markdownToSafeHtml(source: string): string {
  // Deliberately small Markdown subset. Escape first, then add formatting tags.
  const escaped = source
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
  return escaped
    .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\n/g, "<br />");
}

export function MaterialRenderer({ material }: { material: TypedMaterial }) {
  const title = material.title || "材料";
  const [imageState, setImageState] = useState<"loading" | "loaded" | "error">("loading");

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
      return <span data-testid="course-material-unavailable">{title}（图片材料缺少安全地址或替代文本）</span>;
    }
    return (
      <figure className="learning-material learning-material--image" data-testid="course-material-image">
        {imageState === "loading" ? <span data-testid="course-material-image-loading">图片加载中…</span> : null}
        {imageState === "error" ? <span data-testid="course-material-image-error">图片暂时无法加载</span> : null}
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
          {title}（外部视频）
        </a>
      ) : <span data-testid="course-material-unavailable">{title}（视频提供方暂不支持，请联系教研重新保存）</span>;
    }
    const src = `https://player.bilibili.com/player.html?bvid=${encodeURIComponent(material.external_id)}&page=1`;
    return (
      <div className="learning-material learning-material--video" data-testid="course-material-video">
        <iframe
          title={title}
          src={src}
          loading="lazy"
          referrerPolicy="no-referrer"
          sandbox="allow-scripts allow-same-origin allow-presentation"
          allow="fullscreen; autoplay"
        />
        <a href={`https://www.bilibili.com/video/${encodeURIComponent(material.external_id)}`} target="_blank" rel="noopener noreferrer">
          无法播放？打开 Bilibili
        </a>
      </div>
    );
  }
  const url = safeHttpsUrl(material.url);
  return url ? (
    <a href={url} target="_blank" rel="noopener noreferrer" data-testid="course-material-link">{title}</a>
  ) : <span data-testid="course-material-unavailable">{title}（旧材料需要重新保存为 typed Material）</span>;
}
