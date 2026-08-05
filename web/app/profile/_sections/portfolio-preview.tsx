import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { Icon, type IconName } from "@/components/icons";
import {
	type PortfolioIcon,
	type ProfilePortfolioItem,
} from "@/lib/profile";

export function portfolioIconName(icon: PortfolioIcon | undefined): IconName {
	if (icon === "book") return "book";
	if (icon === "guide") return "guide";
	return "document";
}

export function PortfolioPreview({
	portfolio,
}: {
	portfolio: ProfilePortfolioItem[];
}) {
	const wsSlug = useSearchParams().get("ws");
	const preview = portfolio.slice(0, 3);
	return (
		<section
			className="profile-card profile-portfolio-card"
			data-testid="portfolio-card"
		>
			<header className="profile-card__heading">
				<h2>
					作品集 <span className="profile-count">{portfolio.length}</span>
				</h2>
			</header>
			{preview.length > 0 ? (
				<div className="profile-portfolio-list">
					{preview.map((item) => (
						<Link
							key={item.id}
							href={item.url || "#"}
							className="profile-portfolio-item"
							data-testid="portfolio-preview-item"
						>
							<span
								className={`profile-portfolio-icon profile-portfolio-icon--${item.icon ?? "document"}`}
							>
								<Icon name={portfolioIconName(item.icon)} size={26} />
							</span>
							<span className="profile-portfolio-item__body">
								<strong>{item.title}</strong>
								<span>{item.description}</span>
							</span>
							<Icon name="arrow" size={20} />
						</Link>
					))}
					<Link
						href={
							wsSlug ? `/profile/portfolio?ws=${wsSlug}` : "/profile/portfolio"
						}
						className="profile-portfolio-more"
						data-testid="portfolio-all-link"
					>
						查看全部 {portfolio.length} 个作品 <Icon name="arrow" size={18} />
					</Link>
				</div>
			) : (
				<div className="profile-empty-card">还没有添加作品集。</div>
			)}
		</section>
	);
}