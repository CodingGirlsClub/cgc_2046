import { useState } from "react";
import { Icon } from "@/components/icons";
import {
  type PortfolioIcon,
  type ProfileDraft,
  type ProfilePortfolioItem,
  VISIBILITY_OPTION_LABEL,
} from "@/lib/profile";
import { type MembershipRoleName } from "@/lib/graphql/workspace";
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

export function EditContent({
  draft,
  roles,
  memberNumber,
  onDraftChange,
}: {
  draft: ProfileDraft;
  roles: MembershipRoleName[];
  memberNumber: string;
  onDraftChange: (next: ProfileDraft) => void;
}) {
  const [showAllPortfolio, setShowAllPortfolio] = useState(false);
  const visiblePortfolio = showAllPortfolio
    ? draft.portfolio
    : draft.portfolio.slice(0, 2);

  function addSkill() {
    const skill = window.prompt("添加技能标签");
    if (!skill?.trim() || draft.skills.includes(skill.trim())) return;
    onDraftChange({ ...draft, skills: [...draft.skills, skill.trim()] });
  }

  return (
    <div className="profile-edit-layout">
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
              onFile={(avatarUrl) => onDraftChange({ ...draft, avatarUrl })}
            />
            <p>支持 PNG、JPG、WebP、GIF，文件大小不超过 2.2MB。</p>
          </div>
        </div>
        <div className="profile-edit-form-grid">
          <label>
            <span className="profile-form-label">姓名</span>
            <input
              data-testid="profile-name-input"
              value={draft.name}
              onChange={(event) =>
                onDraftChange({ ...draft, name: event.target.value })
              }
            />
          </label>
          <label>
            <span className="profile-form-label">所在地</span>
            <input
              data-testid="profile-location-input"
              value={draft.location}
              onChange={(event) =>
                onDraftChange({ ...draft, location: event.target.value })
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
              onDraftChange({ ...draft, about: event.target.value })
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
                    onDraftChange({
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
                onDraftChange({
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
                onDraftChange({
                  ...draft,
                  portfolio: draft.portfolio.map((entry) =>
                    entry.id === item.id ? next : entry,
                  ),
                })
              }
              onRemove={() =>
                onDraftChange({
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
            onDraftChange({
              ...draft,
              portfolio: [
                ...draft.portfolio,
                {
                  id: `portfolio-${Date.now()}`,
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
    </div>
  );
}
