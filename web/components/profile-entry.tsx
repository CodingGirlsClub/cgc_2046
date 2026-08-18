"use client";

/**
 * #69 个人资料入口（header 头像区）。
 *
 * 显示当前用户头像首字母 + 展示名，点击进入个人资料设置
 * （决策 B：/w/[slug]/settings/account/profile 或 /settings/account/profile）。
 * 数据经 fetchCurrentProfile（mock 先行，后端 #68 定稿后自动切真实）。
 */

import { Link } from "@/i18n/navigation";
import { useEffect, useState } from "react";
import { fetchCurrentProfile, profileHref, type CurrentProfile } from "@/lib/profile";

export default function ProfileEntry({ compact = false, slug }: { compact?: boolean; slug?: string | null }) {
  const [profile, setProfile] = useState<CurrentProfile | null>(null);

  useEffect(() => {
    let cancelled = false;
    fetchCurrentProfile()
      .then((p) => {
        if (!cancelled) setProfile(p);
      })
      .catch(() => {
        /* 加载失败保持占位 */
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const name = profile?.displayName || profile?.email || "…";
  const letter = name.slice(0, 1).toUpperCase();

  return (
    <Link
      href={profileHref(slug)}
      className="flex items-center gap-2 rounded-medium px-2 py-1 transition hover:bg-soft"
      data-testid="profile-entry"
    >
      <span className="flex h-8 w-8 items-center justify-center rounded-full bg-accent-mentionbg text-sm font-medium text-accent">
        {letter}
      </span>
      {!compact && <span className="l-p text-sm text-ink-2">{name}</span>}
    </Link>
  );
}
