import { Suspense } from "react";
import Link from "next/link";
import { Icon } from "@/components/icons";
import {
	profileHref,
	VISIBILITY_LABEL,
	type ProfileContent,
} from "@/lib/profile";
import { Avatar } from "./profile-avatar";
import { RoleChips } from "./profile-role";
import { PortfolioPreview } from "./portfolio-preview";

export function Breadcrumb({
	editing,
	workspaceSlug,
	workspaceName,
}: {
	editing: boolean;
	workspaceSlug: string;
	workspaceName: string;
}) {
	return (
		<div className="profile-breadcrumb" aria-label="页面路径">
			<Link href="/">工作台</Link>
			{workspaceSlug ? (
				<>
					<span>›</span>
					<Link href={`/w/${workspaceSlug}`}>
						{workspaceName || workspaceSlug}
					</Link>
				</>
			) : null}
			<span>›</span>
			<Link href={profileHref(workspaceSlug)}>个人资料</Link>
			{editing ? (
				<>
					<span>›</span>
					<strong>编辑个人资料</strong>
				</>
			) : null}
		</div>
	);
}

export function ProfileSummary({ content }: { content: ProfileContent }) {
	return (
		<section className="profile-summary" data-testid="profile-summary">
			<Avatar content={content} />
			<div className="profile-summary__identity">
				<h2 data-testid="profile-display-name">{content.name}</h2>
				<RoleChips roles={content.workspaceRoles} />
				<div className="profile-summary__meta">
					<span>
						<Icon name="pin" size={20} />
						{content.location}
					</span>
					<i />
					<span>
						<Icon name="calendar" size={20} />
						加入于 {content.joinedAt}
					</span>
					<i />
					<span className="profile-visibility-pill">
						<Icon name="visibility" size={18} />
						{VISIBILITY_LABEL[content.visibility]}
					</span>
				</div>
			</div>
		</section>
	);
}

export function ViewContent({ content }: { content: ProfileContent }) {
	return (
		<div className="profile-view-grid">
			<div className="profile-view-main">
				<section
					className="profile-card profile-about-card"
					data-testid="about-card"
				>
					<h2>关于我</h2>
					<p>{content.about}</p>
				</section>
				<Suspense fallback={null}>
					<PortfolioPreview portfolio={content.portfolio} />
				</Suspense>
			</div>
			<div className="profile-view-aside">
				<section
					className="profile-card profile-skills-card"
					data-testid="skills-card"
				>
					<h2>技能标签</h2>
					<div className="profile-skill-list">
						{content.skills.map((skill) => (
							<span key={skill}>{skill}</span>
						))}
					</div>
				</section>
				<section
					className="profile-card profile-identity-card"
					data-testid="identity-card"
				>
					<h2>工作区身份</h2>
					<span className="profile-card__eyebrow">角色并集</span>
					<RoleChips roles={content.workspaceRoles} />
					<p>权限按所有角色并集合并</p>
					<div className="profile-identity-divider" />
					<div className="profile-member-number">
						<span>成员编号</span>
						<strong>{content.memberNumber}</strong>
					</div>
				</section>
			</div>
		</div>
	);
}