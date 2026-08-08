"use client";

/**
 * 个人资料设置表单（ADR-0004 per-workspace 后唯一编辑入口）。
 *
 * 由工作区 profile 页使用：
 * - /w/[slug]/settings/account/profile（per-workspace 档案编辑）
 *
 * 数据流：
 * - 全局身份（displayName/memberNumber）来自 me（CurrentProfile）
 * - per-workspace 字段（avatar/location/about/skills/visibility/portfolio）
 *   来自 workspaceProfile + myWorkspacePortfolio（WorkspaceProfileContent）
 * - 保存：updateDisplayName（全局）+ updateWorkspaceProfile（per-workspace）
 *   + Portfolio diff 同步（带 workspaceId）
 */

import { useRef, useState } from "react";
import { Icon } from "@/components/icons";
import {
  createPortfolioItem,
  deletePortfolioItem,
  fetchPortfolioItems,
  updateDisplayName,
  updatePortfolioItem,
  updateWorkspaceProfile,
  type CurrentProfile,
  type PortfolioIcon,
  type ProfileDraft,
  type ProfilePortfolioItem,
  type WorkspaceProfileContent,
  VISIBILITY_FOOTER_TEXT,
  VISIBILITY_OPTION_LABEL,
} from "@/lib/profile";
import type { MembershipRoleName } from "@/lib/graphql/workspace";
import type { ProfileVisibility } from "@/lib/graphql/profile";
import { Avatar } from "./profile-avatar";
import { RoleChips } from "./profile-role";

function EditPortfolioRow({
  item,
  onChange,
  onRemove,
}: {
  item: ProfilePortfolioItem;
  onChange: (next: ProfilePortfolioItem) => void;
  onRemove: () => void;
}) {
  return (
    <div
      className="profile-edit-portfolio-row"
      data-testid="portfolio-edit-row"
    >
      <span className="profile-drag-handle" aria-hidden="true">
        <Icon name="grip" size={19} />
      </span>
      <label>
        <span>作品标题</span>
        <input
          value={item.title}
          onChange={(event) => onChange({ ...item, title: event.target.value })}
        />
      </label>
      <label>
        <span>作品简介</span>
        <input
          value={item.description}
          onChange={(event) =>
            onChange({ ...item, description: event.target.value })
          }
        />
      </label>
      <label>
        <span>作品链接</span>
        <input
          value={item.url ?? ""}
          onChange={(event) => onChange({ ...item, url: event.target.value })}
        />
      </label>
      <label>
        <span>图标类型</span>
        <select
          value={item.icon ?? "document"}
          aria-label="作品图标类型"
          onChange={(event) =>
            onChange({ ...item, icon: event.target.value as PortfolioIcon })
          }
        >
          <option value="document">文档</option>
          <option value="book">书籍</option>
          <option value="guide">指南</option>
        </select>
      </label>
      <button
        type="button"
        className="profile-remove-portfolio"
        aria-label={`删除作品：${item.title || "未命名作品"}`}
        onClick={onRemove}
      >
        <Icon name="trash" size={19} />
      </button>
    </div>
  );
}

export function ProfileSettingsForm({
  profile,
  wsProfile,
  workspaceId,
  roles,
  memberNumber,
}: {
  profile: CurrentProfile;
  wsProfile: WorkspaceProfileContent | null;
  workspaceId: string;
  roles: MembershipRoleName[];
  memberNumber: string;
}) {
  const [draft, setDraft] = useState<ProfileDraft>(() => ({
    name: profile.displayName ?? "",
    location: wsProfile?.location ?? "",
    about: wsProfile?.about ?? "",
    skills: wsProfile?.skills ?? [],
    visibility: wsProfile?.visibility ?? "only_me",
    portfolio: (wsProfile?.portfolio ?? []).map((item) => ({ ...item })),
    avatarUrl: wsProfile?.avatarUrl ?? null,
  }));
  // 上次已同步到后端的作品集（保存后刷新，避免二次保存把已建条目当新增重复 create）
  const lastSyncedRef = useRef<ProfilePortfolioItem[]>(
    wsProfile?.portfolio ?? [],
  );
  const [saving, setSaving] = useState(false);
  const [savedMsg, setSavedMsg] = useState<string | null>(null);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [showAllPortfolio, setShowAllPortfolio] = useState(false);
  const visiblePortfolio = showAllPortfolio
    ? draft.portfolio
    : draft.portfolio.slice(0, 2);

  function addSkill() {
    const skill = window.prompt("添加技能标签");
    if (!skill?.trim() || draft.skills.includes(skill.trim())) return;
    setDraft({ ...draft, skills: [...draft.skills, skill.trim()] });
  }

  /** 作品集 diff 同步：新增条目 create、被移除条目 delete、内容变化条目 update（带 workspaceId） */
  async function syncPortfolioChanges(
    prev: ProfilePortfolioItem[],
    next: ProfilePortfolioItem[],
  ) {
    const original = new Map(prev.map((item) => [item.id, item]));
    const nextIds = new Set(next.map((item) => item.id));
    for (const item of next) {
      const orig = original.get(item.id);
      if (!orig) {
        await createPortfolioItem(workspaceId, {
          title: item.title,
          description: item.description,
          url: item.url ?? null,
          icon: item.icon ?? "document",
        });
      } else if (
        orig.title !== item.title ||
        (orig.description ?? "") !== (item.description ?? "") ||
        (orig.url ?? null) !== (item.url ?? null) ||
        (orig.icon ?? "document") !== (item.icon ?? "document")
      ) {
        await updatePortfolioItem(item.id, workspaceId, {
          title: item.title,
          description: item.description,
          url: item.url ?? null,
          icon: item.icon ?? "document",
        });
      }
    }
    for (const item of prev) {
      if (!nextIds.has(item.id)) {
        await deletePortfolioItem(item.id, workspaceId);
      }
    }
  }

  async function handleSave() {
    const name = draft.name.trim();
    if (!name) {
      setErrorMsg("姓名不能为空");
      return;
    }
    setSaving(true);
    setErrorMsg(null);
    setSavedMsg(null);
    try {
      // 全局身份：displayName → updateDisplayName
      await updateDisplayName(name);
      // per-workspace 档案：avatar/location/about/skills/visibility → updateWorkspaceProfile
      await updateWorkspaceProfile(workspaceId, {
        avatarUrl: draft.avatarUrl,
        location: draft.location,
        about: draft.about,
        skills: draft.skills,
        visibility: draft.visibility,
      });
      await syncPortfolioChanges(lastSyncedRef.current, draft.portfolio);
      // 保存成功后重新拉取作品集，确保 id 与后端一致（新增条目由后端生成 uuid）
      const refreshedPortfolio = await fetchPortfolioItems(workspaceId);
      lastSyncedRef.current = refreshedPortfolio;
      setDraft({ ...draft, name, portfolio: refreshedPortfolio });
      setSavedMsg("资料已保存");
    } catch (error: unknown) {
      setErrorMsg(error instanceof Error ? error.message : "保存失败");
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="profile-edit-layout profile-settings-form">
      <section
        className="profile-edit-basic profile-card"
        data-testid="edit-basic-card"
      >
        <h2>基本资料</h2>
        <div className="profile-edit-avatar-block">
          <span className="profile-form-label">头像</span>
          <div className="profile-edit-avatar-row">
            <Avatar
              content={{ name: draft.name || "?", avatarUrl: draft.avatarUrl }}
              editable
              onFile={(avatarUrl) => setDraft({ ...draft, avatarUrl })}
            />
            <p>支持 PNG、JPG、WebP、GIF，文件大小不超过 2.2MB。</p>
          </div>
        </div>
        <div className="profile-edit-form-grid">
          <label>
            <span className="profile-form-label">姓名（全局）</span>
            <input
              data-testid="profile-name-input"
              value={draft.name}
              onChange={(event) =>
                setDraft({ ...draft, name: event.target.value })
              }
            />
          </label>
          <label>
            <span className="profile-form-label">邮箱</span>
            <input value={profile.email} readOnly data-testid="profile-email-input" />
          </label>
          <label>
            <span className="profile-form-label">所在地</span>
            <input
              data-testid="profile-location-input"
              value={draft.location}
              onChange={(event) =>
                setDraft({ ...draft, location: event.target.value })
              }
            />
          </label>
        </div>
        <label className="profile-edit-about">
          <span className="profile-form-label">个人简介</span>
          <textarea
            data-testid="profile-about-input"
            maxLength={240}
            value={draft.about}
            onChange={(event) =>
              setDraft({ ...draft, about: event.target.value })
            }
          />
          <span className="profile-char-count">{draft.about.length} / 240</span>
        </label>
        <div className="profile-edit-skills">
          <span className="profile-form-label">技能标签</span>
          <div className="profile-edit-skill-box">
            {draft.skills.map((skill) => (
              <span key={skill}>
                {skill}
                <button
                  type="button"
                  aria-label={`删除标签 ${skill}`}
                  onClick={() =>
                    setDraft({
                      ...draft,
                      skills: draft.skills.filter((item) => item !== skill),
                    })
                  }
                >
                  ×
                </button>
              </span>
            ))}
            <button
              type="button"
              className="profile-add-skill"
              onClick={addSkill}
            >
              <Icon name="plus" size={16} />
              添加标签
            </button>
          </div>
        </div>
      </section>

      <aside className="profile-edit-side">
        <section
          className="profile-card profile-edit-readonly"
          data-testid="edit-visibility-card"
        >
          <h2>可见范围</h2>
          <label className="profile-visibility-options">
            <span className="profile-form-label">资料可见范围</span>
            <select
              data-testid="profile-visibility-input"
              value={draft.visibility}
              onChange={(event) =>
                setDraft({
                  ...draft,
                  visibility: event.target.value as ProfileVisibility,
                })
              }
            >
              {(
                Object.keys(VISIBILITY_OPTION_LABEL) as ProfileVisibility[]
              ).map((value) => (
                <option key={value} value={value}>
                  {VISIBILITY_OPTION_LABEL[value]}
                </option>
              ))}
            </select>
          </label>
          <div className="profile-edit-divider" />
          <h2>工作区身份</h2>
          <p>角色由 Owner / Admin 管理，此处不可编辑</p>
          <RoleChips roles={roles} />
          <label>
            <span className="profile-form-label">成员编号</span>
            <input value={memberNumber} readOnly />
          </label>
        </section>
      </aside>

      <section
        className="profile-card profile-edit-portfolio"
        data-testid="edit-portfolio-card"
      >
        <h2>作品集</h2>
        <div className="profile-edit-portfolio-list">
          {visiblePortfolio.map((item) => (
            <EditPortfolioRow
              key={item.id}
              item={item}
              onChange={(next) =>
                setDraft({
                  ...draft,
                  portfolio: draft.portfolio.map((entry) =>
                    entry.id === item.id ? next : entry,
                  ),
                })
              }
              onRemove={() =>
                setDraft({
                  ...draft,
                  portfolio: draft.portfolio.filter(
                    (entry) => entry.id !== item.id,
                  ),
                })
              }
            />
          ))}
        </div>
        {!showAllPortfolio && draft.portfolio.length > 2 && (
          <button
            type="button"
            className="profile-expand-portfolio"
            onClick={() => setShowAllPortfolio(true)}
          >
            展开其余 {draft.portfolio.length - 2} 个作品
          </button>
        )}
        <button
          type="button"
          className="profile-add-portfolio"
          onClick={() =>
            setDraft({
              ...draft,
              portfolio: [
                ...draft.portfolio,
                {
                  id: `portfolio-${Date.now()}`,
                  workspaceId,
                  title: "",
                  description: "",
                  url: "",
                  icon: "document",
                },
              ],
            })
          }
        >
          <Icon name="plus" size={18} />
          添加作品
        </button>
      </section>

      {savedMsg && (
        <div className="settings-saved" role="status">
          <Icon name="check" size={16} />
          {savedMsg}
        </div>
      )}
      {errorMsg && (
        <div className="members-error" role="alert">
          {errorMsg}
        </div>
      )}
      <footer className="profile-settings-form__footer">
        <span>{VISIBILITY_FOOTER_TEXT[draft.visibility]}</span>
        <button
          type="button"
          className="l-btn l-btn-primary"
          onClick={handleSave}
          disabled={saving}
        >
          {saving ? "保存中…" : "保存更改"}
        </button>
      </footer>
    </div>
  );
}
