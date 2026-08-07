"use client";

/**
 * 共享 Icon 集（⑤ WorkspaceShell 壳收敛）。
 *
 * 三页原先各手抄一份 SVG（路径变体互不相同：如 users/settings/calendar 在
 * members 与 profile 是不同画法）。2026-08-02 决策（⑤ Q2）：壳单设计，
 * 图标路径统一以 members 页版本为基准（strokeWidth 1.7），重叠图标收敛，
 * 页面特有图标（edit/pin/trash 等）也收进同一份，不再在页面内手抄。
 */

export type IconName =
	| "grid"
	| "home"
	| "users"
	| "settings"
	| "user"
	| "search"
	| "chevron"
	| "lock"
	| "info"
	| "shield"
	| "calendar"
	| "owner"
	| "check"
	| "arrow"
	| "arrow-left"
	| "edit"
	| "grip"
	| "pin"
	| "plus"
	| "trash"
	| "visibility"
	| "book"
	| "guide"
	| "document"
	| "community"
	| "role"
	| "members"
	| "activity"
	| "enter"
	| "request"
	| "invite"
	| "workspace";

export function Icon({
	name,
	size = 20,
	className,
}: {
	name: IconName;
	size?: number;
	className?: string;
}) {
	const common = {
		width: size,
		height: size,
		viewBox: "0 0 24 24",
		fill: "none",
		stroke: "currentColor",
		strokeWidth: 1.7,
		strokeLinecap: "round" as const,
		strokeLinejoin: "round" as const,
		"aria-hidden": true,
		className,
	};

	switch (name) {
		case "grid":
			return (
				<svg {...common}>
					<rect x="3" y="3" width="7" height="7" rx="1" />
					<rect x="14" y="3" width="7" height="7" rx="1" />
					<rect x="3" y="14" width="7" height="7" rx="1" />
					<rect x="14" y="14" width="7" height="7" rx="1" />
				</svg>
			);
		case "home":
			return (
				<svg {...common}>
					<path d="m3 10 9-7 9 7v10a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1Z" />
				</svg>
			);
		case "users":
			return (
				<svg {...common}>
					<path d="M16 21v-1.6a4.4 4.4 0 0 0-4.4-4.4H7.4A4.4 4.4 0 0 0 3 19.4V21" />
					<circle cx="9.5" cy="7.5" r="3.5" />
					<path d="M21 21v-1.5a4.3 4.3 0 0 0-3.2-4.15M16.7 4.1a3.5 3.5 0 0 1 0 6.8" />
				</svg>
			);
		case "settings":
			return (
				<svg {...common}>
					<circle cx="12" cy="12" r="3" />
					<path d="M19.4 15a1.7 1.7 0 0 0 .34 1.88l.06.06-1.7 1.7-.06-.06a1.7 1.7 0 0 0-1.88-.34 1.7 1.7 0 0 0-1.03 1.56V21h-2.4v-.2a1.7 1.7 0 0 0-1.03-1.56 1.7 1.7 0 0 0-1.88.34l-.06.06-1.7-1.7.06-.06A1.7 1.7 0 0 0 8.46 15a1.7 1.7 0 0 0-1.56-1.03H6.7v-2.4h.2A1.7 1.7 0 0 0 8.46 10a1.7 1.7 0 0 0-.34-1.88l-.06-.06 1.7-1.7.06.06a1.7 1.7 0 0 0 1.88.34 1.7 1.7 0 0 0 1.03-1.56V5h2.4v.2a1.7 1.7 0 0 0 1.03 1.56 1.7 1.7 0 0 0 1.88-.34l.06-.06 1.7 1.7-.06.06A1.7 1.7 0 0 0 19.4 10a1.7 1.7 0 0 0 1.56 1.03h.2v2.4h-.2A1.7 1.7 0 0 0 19.4 15Z" />
				</svg>
			);
		case "user":
			return (
				<svg {...common}>
					<circle cx="12" cy="8" r="3.5" />
					<path d="M4 21a8 8 0 0 1 16 0" />
				</svg>
			);
		case "search":
			return (
				<svg {...common}>
					<circle cx="10.8" cy="10.8" r="6.4" />
					<path d="m16 16 4.5 4.5" />
				</svg>
			);
		case "chevron":
			return (
				<svg {...common}>
					<path d="m8 10 4 4 4-4" />
				</svg>
			);
		case "lock":
			return (
				<svg {...common}>
					<rect x="5" y="10" width="14" height="10" rx="2" />
					<path d="M8 10V7a4 4 0 0 1 8 0v3M12 14v2" />
				</svg>
			);
		case "info":
			return (
				<svg {...common}>
					<circle cx="12" cy="12" r="9" />
					<path d="M12 10.5v5M12 7.5h.01" />
				</svg>
			);
		case "shield":
			return (
				<svg {...common}>
					<path d="M12 3 19 6v5c0 4.7-2.9 8.1-7 10-4.1-1.9-7-5.3-7-10V6l7-3Z" />
					<path d="m9.3 12 1.8 1.8 3.7-4" />
				</svg>
			);
		case "calendar":
			return (
				<svg {...common}>
					<rect x="4" y="5" width="16" height="15" rx="2" />
					<path d="M8 3v4M16 3v4M4 10h16" />
				</svg>
			);
		case "owner":
			// 有意别名：与 user 同形（permissions 页「Owner 专门指派」语义用名），2026-08-02 ⑤ review P3-2
			return (
				<svg {...common}>
					<circle cx="12" cy="8" r="3.5" />
					<path d="M4 21a8 8 0 0 1 16 0" />
				</svg>
			);
		case "check":
			return (
				<svg {...common}>
					<path d="m5 12 4.5 4.5L19 7" />
				</svg>
			);
		case "arrow":
			return (
				<svg {...common}>
					<path d="M4 12h15M13 6l6 6-6 6" />
				</svg>
			);
		case "arrow-left":
			return (
				<svg {...common}>
					<path d="M20 12H5M11 6l-6 6 6 6" />
				</svg>
			);
		case "edit":
			return (
				<svg {...common}>
					<path d="m4 16.5-.7 3.8 3.8-.7L18.6 8.1a2.1 2.1 0 0 0-3-3L4 16.5Z" />
					<path d="m13.8 6.2 4 4" />
				</svg>
			);
		case "grip":
			return (
				<svg {...common}>
					<circle cx="8" cy="7" r="1" fill="currentColor" stroke="none" />
					<circle cx="16" cy="7" r="1" fill="currentColor" stroke="none" />
					<circle cx="8" cy="12" r="1" fill="currentColor" stroke="none" />
					<circle cx="16" cy="12" r="1" fill="currentColor" stroke="none" />
					<circle cx="8" cy="17" r="1" fill="currentColor" stroke="none" />
					<circle cx="16" cy="17" r="1" fill="currentColor" stroke="none" />
				</svg>
			);
		case "pin":
			return (
				<svg {...common}>
					<path d="M20 10c0 5-8 11-8 11S4 15 4 10a8 8 0 1 1 16 0Z" />
					<circle cx="12" cy="10" r="2.5" />
				</svg>
			);
		case "plus":
			return (
				<svg {...common}>
					<path d="M12 5v14M5 12h14" />
				</svg>
			);
		case "trash":
			return (
				<svg {...common}>
					<path d="M4 7h16M10 11v6M14 11v6M6 7l1 14h10l1-14M9 7V4h6v3" />
				</svg>
			);
		case "visibility":
			return (
				<svg {...common}>
					<path d="M2.5 12s3.2-5 9.5-5 9.5 5 9.5 5-3.2 5-9.5 5-9.5-5-9.5-5Z" />
					<circle cx="12" cy="12" r="2.2" />
				</svg>
			);
		case "book":
			return (
				<svg {...common}>
					<path d="M4 5.5A3.5 3.5 0 0 1 7.5 2H12v18H7.5A3.5 3.5 0 0 0 4 23Z" />
					<path d="M20 5.5A3.5 3.5 0 0 0 16.5 2H12v18h4.5a3.5 3.5 0 0 1 3.5 3Z" />
				</svg>
			);
		case "guide":
			return (
				<svg {...common}>
					<path d="M5 4h6a3 3 0 0 1 3 3v13H8a3 3 0 0 0-3 1Z" />
					<path d="M19 4h-5a3 3 0 0 0-3 3v13h6a3 3 0 0 1 3 1Z" />
				</svg>
			);
		case "document":
			return (
				<svg {...common}>
					<path d="M6 3h8l4 4v14H6Z" />
					<path d="M14 3v5h5M9 13h6M9 17h6" />
				</svg>
			);
		// 内容/工作区卡图标（2026-08-02 首页 WorkspaceIcon 合并：画法原样随迁，
		// 线帽统一走共享 common（round）。内容图标与壳导航图标同集，禁止页面内手抄 SVG）
		case "community":
		case "members":
			// 有意别名：community（加入方式卡）与 members（社区规模/成员按钮）同形，对标 owner/user
			return (
				<svg {...common}>
					<circle cx="9" cy="8" r="3" />
					<path d="M3.5 19c.6-3.2 2.4-5 5.5-5s4.9 1.8 5.5 5" />
					<path d="M15.5 5.8a3 3 0 0 1 0 5.5M17.2 14.3c1.8.8 2.8 2.2 3.3 4.7" />
				</svg>
			);
		case "role":
			return (
				<svg {...common}>
					<circle cx="12" cy="8" r="3" />
					<path d="M5.5 19.5c.8-3.2 3-4.8 6.5-4.8s5.7 1.6 6.5 4.8" />
				</svg>
			);
		case "activity":
			return (
				<svg {...common}>
					<path d="M4 5.5h16v10H9l-5 4v-14Z" />
					<path d="M8 9.5h8M8 12.5h5" />
				</svg>
			);
		case "enter":
			return (
				<svg {...common}>
					<path d="M13 5h6v14h-6M4 12h11M11 8l4 4-4 4" />
				</svg>
			);
		case "request":
			return (
				<svg {...common}>
					<path d="M12 3v18M7.5 7.5h9M7.5 16.5h9" />
					<circle cx="12" cy="12" r="8.5" />
				</svg>
			);
		case "invite":
		case "workspace":
			// invite 与 workspace 同形：首页原无显式 invite case（落入默认 fallback 公文包，
			// 用于「待凭据加入」状态卡）；合并后共享该画法，保持现状
			return (
				<svg {...common}>
					<path d="M6 9.5V6.8A6 6 0 0 1 18 6.8v2.7" />
					<rect x="4" y="9.5" width="16" height="10.5" rx="2" />
					<path d="M12 13v3" />
				</svg>
			);
		default: {
			// 穷尽校验：新增 IconName 成员而漏写 case 时编译期报错（⑤ review P3-3）
			return name satisfies never;
		}
	}
}
