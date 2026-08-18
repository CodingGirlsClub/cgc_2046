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
import { useTranslations } from "next-intl";
import { Icon } from "@/components/icons";
import {
  AVATAR_ALLOWED_TYPES,
  AVATAR_MAX_MB,
  AVATAR_TYPE_LABEL,
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
import { ProfileLocaleSelect } from "./profile-locale-select";
import type { ProfileVisibility } from "@/lib/graphql/profile";
import { Avatar } from "./profile-avatar";
import { RoleChips } from "./profile-role";

function EditPortfolioRow({
  item,
  onChange,
  onRemove,
  disabled,
}: {
  item: ProfilePortfolioItem;
  onChange: (next: ProfilePortfolioItem) => void;
  onRemove: () => void;
  disabled: boolean;
}) {
  const t = useTranslations("workspaceAccount");
  return (
    <div
      className="profile-edit-portfolio-row"
      data-testid="portfolio-edit-row"
    >
      <span className="profile-drag-handle" aria-hidden="true">
        <Icon name="grip" size={19} />
      </span>
      <label>
        <span>{t("portfolioTitleLabel")}</span>
        <input
          value={item.title}
          disabled={disabled}
          onChange={(event) => onChange({ ...item, title: event.target.value })}
        />
      </label>
      <label>
        <span>{t("portfolioDescLabel")}</span>
        <input
          value={item.description}
          disabled={disabled}
          onChange={(event) =>
            onChange({ ...item, description: event.target.value })
          }
        />
      </label>
      <label>
        <span>{t("portfolioLinkLabel")}</span>
        <input
          value={item.url ?? ""}
          disabled={disabled}
          onChange={(event) => onChange({ ...item, url: event.target.value })}
        />
      </label>
      <label>
        <span>{t("portfolioIconLabel")}</span>
        <select
          value={item.icon ?? "document"}
          disabled={disabled}
          aria-label={t("portfolioIconAria")}
          onChange={(event) =>
            onChange({ ...item, icon: event.target.value as PortfolioIcon })
          }
        >
          <option value="document">{t("optionDocument")}</option>
          <option value="book">{t("optionBook")}</option>
          <option value="guide">{t("optionGuide")}</option>
        </select>
      </label>
      <button
        type="button"
        className="profile-remove-portfolio"
        aria-label={t("deletePortfolioAria", { title: item.title || t("untitled") })}
        disabled={disabled}
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
  initialPortfolio,
}: {
  profile: CurrentProfile;
  wsProfile: WorkspaceProfileContent | null;
  workspaceId: string;
  roles: MembershipRoleName[];
  memberNumber: string;
  initialPortfolio: ProfilePortfolioItem[];
}) {
  const t = useTranslations("workspaceAccount");
  const labelsT = useTranslations();
  const [draft, setDraft] = useState<ProfileDraft>(() => ({
    name: profile.displayName ?? "",
    location: wsProfile?.location ?? "",
    about: wsProfile?.about ?? "",
    skills: wsProfile?.skills ?? [],
    visibility: wsProfile?.visibility ?? "only_me",
    portfolio: initialPortfolio.map((item) => ({ ...item })),
    avatarUrl: wsProfile?.avatarUrl ?? null,
  }));
  // 上次已同步到后端的作品集（保存后刷新，避免二次保存把已建条目当新增重复 create）
  const lastSyncedRef = useRef<ProfilePortfolioItem[]>(initialPortfolio);
  const [saving, setSaving] = useState(false);
  const [savedMsg, setSavedMsg] = useState<string | null>(null);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [showAllPortfolio, setShowAllPortfolio] = useState(false);
  const visiblePortfolio = showAllPortfolio
    ? draft.portfolio
    : draft.portfolio.slice(0, 2);

  function addSkill() {
    const skill = window.prompt(t("addSkillPrompt"));
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
      setErrorMsg(t("nameRequired"));
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
      setSavedMsg(t("saved"));
    } catch (error: unknown) {
      setErrorMsg(error instanceof Error ? error.message : t("saveFailed"));
    } finally {
      // 无论成败，与服务器 reconcile——部分 create 已落库时，重试不会把它们当新增重复创建
      try {
        const refreshed = await fetchPortfolioItems(workspaceId);
        lastSyncedRef.current = refreshed;
        // 函数式更新：即使保存期间有其它 setDraft 排队，也只覆盖 portfolio 字段
        setDraft((prev) => ({ ...prev, portfolio: refreshed }));
      } catch {
        // reconcile 失败静默——下次保存仍会重试
      }
      setSaving(false);
    }
  }

  return (
    <div className="profile-edit-layout profile-settings-form">
      <section
        className="profile-edit-basic profile-card"
        data-testid="edit-basic-card"
      >
        <h2>{t("basicInfo")}</h2>
        <div className="profile-edit-avatar-block">
          <span className="profile-form-label">{t("avatar")}</span>
          <div className="profile-edit-avatar-row">
            <Avatar
              content={{ name: draft.name || "?", avatarUrl: draft.avatarUrl }}
              editable
              onFile={(avatarUrl) => setDraft({ ...draft, avatarUrl })}
              onError={(msg) => setErrorMsg(msg)}
            />
            <p>
              {t("avatarHint", { types: AVATAR_ALLOWED_TYPES.map((type) => AVATAR_TYPE_LABEL[type]).join("、"), max: AVATAR_MAX_MB })}
            </p>
          </div>
        </div>
        <div className="profile-edit-form-grid">
          <label>
            <span className="profile-form-label">{t("nameLabel")}</span>
            <input
              data-testid="profile-name-input"
              value={draft.name}
              disabled={saving}
              onChange={(event) =>
                setDraft({ ...draft, name: event.target.value })
              }
            />
          </label>
          <label>
            <span className="profile-form-label">{t("emailLabel")}</span>
            <input value={profile.email} readOnly disabled={saving} data-testid="profile-email-input" />
          </label>
          <label>
            <span className="profile-form-label">{t("locationLabel")}</span>
            <input
              data-testid="profile-location-input"
              value={draft.location}
              disabled={saving}
              onChange={(event) =>
                setDraft({ ...draft, location: event.target.value })
              }
            />
          </label>
        </div>
        <label className="profile-edit-about">
          <span className="profile-form-label">{t("aboutLabel")}</span>
          <textarea
            data-testid="profile-about-input"
            maxLength={240}
            value={draft.about}
            disabled={saving}
            onChange={(event) =>
              setDraft({ ...draft, about: event.target.value })
            }
          />
          <span className="profile-char-count">{draft.about.length} / 240</span>
        </label>
        <div className="profile-edit-skills">
          <span className="profile-form-label">{t("skillsLabel")}</span>
          <div className="profile-edit-skill-box">
            {draft.skills.map((skill) => (
              <span key={skill}>
                {skill}
                <button
                  type="button"
                  aria-label={t("deleteSkillAria", { skill })}
                  disabled={saving}
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
              disabled={saving}
              onClick={addSkill}
            >
              <Icon name="plus" size={16} />
              {t("addSkill")}
            </button>
          </div>
        </div>
      </section>

      <aside className="profile-edit-side">
        <section
          className="profile-card profile-edit-readonly"
          data-testid="edit-visibility-card"
        >
          <h2>{t("visibilityTitle")}</h2>
          <label className="profile-visibility-options">
            <span className="profile-form-label">{t("visibilityLabel")}</span>
            <select
              data-testid="profile-visibility-input"
              value={draft.visibility}
              disabled={saving}
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
                  {labelsT(VISIBILITY_OPTION_LABEL[value])}
                </option>
              ))}
            </select>
          </label>
          <div className="profile-edit-divider" />
          <h2>{t("identityTitle")}</h2>
          <p>{t("identityHint")}</p>
          <RoleChips roles={roles} />
          <label>
            <span className="profile-form-label">{t("memberNumber")}</span>
            <input value={memberNumber} readOnly disabled={saving} />
          </label>
          <div className="profile-edit-divider" />
          <ProfileLocaleSelect />
        </section>
      </aside>

      <section
        className="profile-card profile-edit-portfolio"
        data-testid="edit-portfolio-card"
      >
        <h2>{t("portfolioTitle")}</h2>
        <div className="profile-edit-portfolio-list">
          {visiblePortfolio.map((item) => (
            <EditPortfolioRow
              key={item.id}
              item={item}
              disabled={saving}
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
            disabled={saving}
            onClick={() => setShowAllPortfolio(true)}
          >
            {t("expandRest", { count: draft.portfolio.length - 2 })}
          </button>
        )}
        <button
          type="button"
          className="profile-add-portfolio"
          disabled={saving}
          onClick={() =>
            setDraft({
              ...draft,
              portfolio: [
                ...draft.portfolio,
                {
                  id: `portfolio-${crypto.randomUUID()}`,
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
          {t("addPortfolio")}
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
        <span>{labelsT(VISIBILITY_FOOTER_TEXT[draft.visibility])}</span>
        <button
          type="button"
          className="l-btn l-btn-primary"
          onClick={handleSave}
          disabled={saving}
        >
          {saving ? t("saving") : t("saveChanges")}
        </button>
      </footer>
    </div>
  );
}
