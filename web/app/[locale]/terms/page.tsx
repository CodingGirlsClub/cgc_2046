import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";

/**
 * /terms 用户服务协议（静态法务页，#210 U1）。
 *
 * 内容一字不差转写自源档 docs/合规上架/用户服务协议.md（v1.0，2026-08-20 定稿）。
 * 法务文本变更时必须同步更新源档与本页（评审义务，见 plan 2026-08-008）。
 * 法律文本仅中文（CONTEXT.md D 决策）：en locale 同样渲染本中文内容，
 * 头注明示以中文版本为准。
 */
type PageProps = {
	params: Promise<{ locale: string }>;
};

export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
	const { locale } = await params;
	const t = await getTranslations({ locale, namespace: "legal.terms" });
	return {
		title: t("title"),
		description: t("description"),
	};
}

export default function TermsPage() {
	return (
		<main className="mx-auto max-w-3xl px-4 py-10">
			<h1 className="l-h1">CGC 平台用户服务协议</h1>

			<div className="mt-4 space-y-1 rounded-large border border-line bg-card px-5 py-4 text-[12px] leading-5 text-ink-3">
				<p>生效日期 2026-09-01 ｜ 法律文本以中文版本为准（The Chinese version prevails）</p>
				<p>版本 v1.0（2026-08-20）｜ 运营者：CodingGirlsClub（「我们」）</p>
				<p>文本源档：docs/合规上架/用户服务协议.md</p>
			</div>

			<p className="mt-8 text-sm leading-7 text-ink-2">
				<strong>欢迎使用 CGC 平台。注册账号或使用本平台任何功能即表示您已阅读、理解并同意本协议全部条款。</strong>
				若不同意，请停止注册与使用。
			</p>

			<section className="mt-10">
				<h2 className="l-h3">1. 平台服务</h2>
				<p className="mt-3 text-sm leading-7 text-ink-2">1.1 CGC 平台为技术社区提供活动/课程管理、报名与审批、在线学习、社区协作等服务的网站（codingirlsclub.com）与小程序。</p>
				<p className="mt-3 text-sm leading-7 text-ink-2">1.2 我们持续改进服务，可能增加、调整或中止部分功能；重大变更将提前公告。</p>
			</section>

			<section className="mt-10">
				<h2 className="l-h3">2. 账号</h2>
				<p className="mt-3 text-sm leading-7 text-ink-2">2.1 您可通过邮箱注册，或经微信/抖音/小红书及手机号快捷方式登录创建账号。<strong>同一手机号将归一为同一账号</strong>，请勿使用非本人手机号。</p>
				<p className="mt-3 text-sm leading-7 text-ink-2">2.2 您应妥善保管登录凭证与密码；账号下的操作均视为您本人行为。发现账号被盗用应立即通知我们。</p>
				<p className="mt-3 text-sm leading-7 text-ink-2">2.3 您应提供真实、准确的注册信息；因信息不实导致的损失由您自行承担。</p>
			</section>

			<section className="mt-10">
				<h2 className="l-h3">3. 用户行为规范</h2>
				<p className="mt-3 text-sm leading-7 text-ink-2">您承诺不利用本平台从事下列行为：</p>
				<ul className="mt-3 list-disc space-y-2 pl-6 text-sm leading-7 text-ink-2">
					<li>3.1 违反法律法规、危害国家安全、传播违法信息；</li>
					<li>3.2 冒用他人身份、恶意占用他人手机号/邮箱注册；</li>
					<li>3.3 对平台实施攻击、爬取、逆向、干扰（包括恶意刷接口、伪造请求、绕过限流）；</li>
					<li>3.4 在报名理由、学习产出、个人资料等任何输入点提交违法违规、侵犯他人权益的内容（平台将按内容安全要求进行机器与人工审核）；</li>
					<li>3.5 倒卖活动名额、票务或账号；</li>
					<li>3.6 其它破坏平台或其他用户体验的行为。</li>
				</ul>
				<p className="mt-3 text-sm leading-7 text-ink-2">违反上述规范的，我们有权视情节采取警示、限制功能、拒绝服务、封禁账号等措施，并保存相关记录依法处理。</p>
			</section>

			<section className="mt-10">
				<h2 className="l-h3">4. 内容与知识产权</h2>
				<p className="mt-3 text-sm leading-7 text-ink-2">4.1 您在平台提交的报名理由、学习记录、作业产出等内容，权利归您所有；您提交即授予平台为提供服务所必需的存储、展示与处理许可。</p>
				<p className="mt-3 text-sm leading-7 text-ink-2">4.2 平台运营数据（活动信息、课程内容中平台自有的部分）及平台软件的知识产权归平台所有。</p>
				<p className="mt-3 text-sm leading-7 text-ink-2">4.3 未经授权，任何人不得复制、转载平台受保护内容用于商业用途。</p>
			</section>

			<section className="mt-10">
				<h2 className="l-h3">5. 报名、订单与支付</h2>
				<p className="mt-3 text-sm leading-7 text-ink-2">5.1 活动报名分免费与付费；付费活动经微信支付/支付宝完成支付后报名生效。</p>
				<p className="mt-3 text-sm leading-7 text-ink-2">5.2 <strong>退款规则</strong>：退款以活动页面公示的规则为准；页面未特别说明时，活动开始前申请退款的，按原路全额退款；活动开始后不予退款（法定情形除外）。</p>
				<p className="mt-3 text-sm leading-7 text-ink-2">5.3 因不可抗力导致活动取消的，已付费用全额退还。</p>
			</section>

			<section className="mt-10">
				<h2 className="l-h3">6. AI/Agent 能力（BYO 说明）</h2>
				<p className="mt-3 text-sm leading-7 text-ink-2">6.1 本平台支持您通过自有 AI 助手（如 OpenClacky）经开放协议（MCP）连接平台能力。<strong>该连接使用您的账号身份与权限，一切经此产生的操作视为您本人操作</strong>。</p>
				<p className="mt-3 text-sm leading-7 text-ink-2">6.2 您应自行管理连接令牌：可随时在平台撤销；令牌泄露请立即撤销并通知我们。</p>
				<p className="mt-3 text-sm leading-7 text-ink-2">6.3 高风险操作（如发出邀请、审批加入申请）平台设置了二次确认机制，未经您确认不会落库生效。</p>
			</section>

			<section className="mt-10">
				<h2 className="l-h3">7. 免责与责任限制</h2>
				<p className="mt-3 text-sm leading-7 text-ink-2">7.1 平台按「现状」提供服务；因不可抗力、第三方服务（支付渠道、微信/抖音/小红书平台、云服务）故障导致的损失，我们在法律允许范围内不承担责任。</p>
				<p className="mt-3 text-sm leading-7 text-ink-2">7.2 在法律允许的最大范围内，我们对间接损失、利润损失、数据丢失不承担责任；我们的累计赔偿责任不超过您在引发责任的事件前 12 个月内就本平台支付的费用总额（免费用户为人民币 100 元）。</p>
			</section>

			<section className="mt-10">
				<h2 className="l-h3">8. 协议变更与终止</h2>
				<p className="mt-3 text-sm leading-7 text-ink-2">8.1 我们可能修订本协议，重大变更将公告通知；继续使用即视为接受修订。</p>
				<p className="mt-3 text-sm leading-7 text-ink-2">8.2 您可随时停止使用并退出登录；我们也可依第 3 节或法律规定中止/终止对违规用户的服务。</p>
				<p className="mt-3 text-sm leading-7 text-ink-2">8.3 协议终止后，我们将按《隐私政策》处理您的个人信息。</p>
			</section>

			<section className="mt-10">
				<h2 className="l-h3">9. 法律适用与争议解决</h2>
				<p className="mt-3 text-sm leading-7 text-ink-2">9.1 本协议适用中华人民共和国法律。</p>
				<p className="mt-3 text-sm leading-7 text-ink-2">9.2 争议应友好协商；协商不成的，提交运营者所在地有管辖权的人民法院裁判。</p>
			</section>

			<section className="mt-10">
				<h2 className="l-h3">10. 其他</h2>
				<p className="mt-3 text-sm leading-7 text-ink-2">10.1 本协议未尽事宜依《隐私政策》及平台公示规则执行。</p>
				<p className="mt-3 text-sm leading-7 text-ink-2">10.2 联系我们：info@codingirlsclub.com。</p>
			</section>

			<div className="mt-10 rounded-large border border-line bg-card px-5 py-4 text-sm leading-6 text-ink-2">
				<p><strong>重要提示</strong>：请重点阅读第 3 节（行为规范）、第 5 节（退款）、第 6 节（AI/Agent 操作归责）、第 7 节（免责）。如您对条款有疑问，请在注册前联系我们。</p>
			</div>
		</main>
	);
}
