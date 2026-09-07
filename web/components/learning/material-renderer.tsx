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
  const t = useTranslations("material");
  const title = material.title || t("title");
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
        <iframe
          title={title}
          src={src}
          loading="lazy"
          referrerPolicy="no-referrer"
          sandbox="allow-scripts allow-same-origin allow-presentation"
          allow="fullscreen; autoplay"
        />
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
