/**
 * 草图 Variant A —— 站点语言延伸：完全复用首页 ld-* 设计语言（深色门面、纪念碑排印），
 * campaign 内容装进既有段落组件。判断点：与现有站点零跳变 vs campaign 个性不足。
 * 草图定位：方向性低保真，只看结构/氛围/层级。
 */
import SiteHeader from "@/components/site-header";
import { BrandLockup } from "@/components/brand";

const POWS = [
	{ v: "8", pow: "2³", label: "人开班" },
	{ v: "32", pow: "2⁵", label: "人满班" },
	{ v: "64", pow: "2⁶", label: "场品牌专场" },
	{ v: "16", pow: "2⁴", label: "个品牌席位" },
	{ v: "1,024", pow: "2¹⁰", label: "场全国计划" },
];

const STEPS = [
	{ t: "15 分钟开场", d: "认识 Agent、认识同场伙伴——不写代码，先知道要做什么" },
	{ t: "2 小时动手", d: "Agent 自适应学习陪你跑，第一次亲手把想法变成能跑的作品" },
	{ t: "30 分钟 demo", d: "人人上台展示自己的作品——带得走、发得出、跑得起来" },
];

const HISTORY = [
	{ v: "10 城", l: "覆盖城市" },
	{ v: "50+", l: "线下工作坊" },
	{ v: "4,000+", l: "学员" },
	{ v: "1,000+", l: "教练" },
	{ v: "2,000 万+", l: "总阅读量" },
];

const PERKS = [
	{ t: "系列命名", d: "专场系列名含你的品牌——联名系列，非单场冠名" },
	{ t: "定制课程", d: "课程主题、案例、教学路径按你的产品定制，课程完成即你的内容资产" },
	{ t: "现场转化钩子", d: "现场注册你的账号 / 发放产品权益 / 作品存入你的平台——激活变成可数的转化数据" },
	{ t: "下场观察", d: "你的团队直接进现场，零基础用户的第一手反馈进你的产品 backlog" },
];

export default function VariantA() {
	return (
		<main className="ld-root">
			<SiteHeader />

			<section aria-labelledby="hsa-hero" className="ld-hero">
				<div className="ld-container">
					<p className="ld-kicker">
						<span className="ld-kicker__dot" aria-hidden="true" />
						#hackerstart1024 · Coding Girls Club 程序媛汇
					</p>
					<h1 id="hsa-hero" className="ld-display">
						Hacker Start 1024
					</h1>
					<p className="ld-section__desc" style={{ maxWidth: "34em" }}>
						让普通人第一次亲手用 Agent 做出能跑的作品
					</p>
					<div className="ld-cta-row">
						<a href="#hsa-join" className="join-button join-button--primary">
							我要参加
						</a>
						<a href="#hsa-brand" className="ld-cta-quiet">
							品牌专场合作 →
						</a>
					</div>
					<ul className="ld-stats" style={{ maxWidth: 720 }}>
						{POWS.map((p) => (
							<li key={p.label}>
								<div className="ld-stat__value">
									{p.v}
									<sup style={{ fontSize: "0.45em", opacity: 0.55 }}>{p.pow}</sup>
								</div>
								<div className="ld-stat__label">{p.label}</div>
							</li>
						))}
					</ul>
					<p className="ld-stats__caption">全国 1,024 场（2¹⁰）· 2026.10.24 启动</p>
				</div>
			</section>

			<section aria-labelledby="hsa-why" className="ld-section">
				<div className="ld-container">
					<h2 id="hsa-why" className="ld-section__title">
						Agent 已经过了能力拐点，缺的是普通人敢不敢开始
					</h2>
					<div className="ld-manifesto">
						<p className="ld-manifesto__desc">
							Agent coding 已经能干活了，瓶颈变成了「普通人敢不敢开始、第一次有没有人陪跑」。
							所有厂商的自然流量都是开发者；零基础普通人的第一次，市场上没有现成通道。
							Hacker Start 1024 就是这条通道：3 小时一场 · 8-32 人小班 · Agent
							自适应学习 · 69 元押金——把「第一次亲手做出可运行的作品」变成可交付的东西。
						</p>
					</div>
				</div>
			</section>

			<section aria-labelledby="hsa-join" className="ld-section" id="hsa-join">
				<div className="ld-container">
					<div className="ld-section__head">
						<div>
							<h2 className="ld-section__title">我要参加</h2>
							<p className="ld-section__desc">
								3 小时，从零到上台 demo——一场 8 人开班（2³），32 人满班（2⁵）；69 元押金，到场即退。
							</p>
						</div>
						<a href="/events" className="ld-section__more">
							查看全部场次 →
						</a>
					</div>
					<ol className="ld-path">
						{STEPS.map((s, i) => (
							<li key={s.t} className="ld-step">
								<span className="ld-step__index">{String(i + 1).padStart(2, "0")}</span>
								<h3 className="ld-step__title">{s.t}</h3>
								<p className="ld-step__desc">{s.d}</p>
							</li>
						))}
					</ol>
					<p className="ld-stats__caption">首批场次 2026.10.24 起陆续开放，报名通道即将开启。</p>
				</div>
			</section>

			<section aria-labelledby="hsa-who" className="ld-section">
				<div className="ld-container">
					<h2 className="ld-section__title">十年社区，国家级背书</h2>
					<p className="ld-section__desc">
						Coding Girls Club 程序媛汇，2016 年成立，中国首个、规模最大的女性编程社区（社会企业）。
					</p>
					<ul className="ld-stats">
						{HISTORY.map((s) => (
							<li key={s.l}>
								<div className="ld-stat__value">{s.v}</div>
								<div className="ld-stat__label">{s.l}</div>
							</li>
						))}
					</ul>
					<p className="ld-stats__caption">2016-2025 历史累计</p>
					<ul className="ld-press">
						<li>
							<div className="ld-press__row">
								<span className="ld-press__outlet">ICSE CHASE 2021</span>
								<span className="ld-press__title">与卡内基梅隆大学研究学者合作论文（IEEE 出版）</span>
							</div>
						</li>
						<li>
							<div className="ld-press__row">
								<span className="ld-press__outlet">UNDP</span>
								<span className="ld-press__title">联合国开发计划署「科技与慈善」案例（2018）· 共青团中央「伙伴计划」获奖 · 联合国妇女署 #科技遇见她#</span>
							</div>
						</li>
						<li>
							<div className="ld-press__row">
								<span className="ld-press__outlet">媒体</span>
								<span className="ld-press__title">中国日报 · 环球时报 · CCTV · 果壳网</span>
							</div>
						</li>
					</ul>
					<p className="ld-manifesto__desc" style={{ fontWeight: 700 }}>
						本轮一个 campaign 的参与人数目标 ≈ 过去十年累计。
					</p>
				</div>
			</section>

			<section aria-labelledby="hsa-brand" className="ld-section" id="hsa-brand">
				<div className="ld-container">
					<h2 className="ld-section__title">品牌专场合作</h2>
					<p className="ld-section__desc">
						CGC 十年编程社区 × 你的品牌：联合主办 64 场品牌专场，用为你定制的一门课，把
						512-2,048 名付费用户变成你的产品第一批普通人用户。
					</p>
					<p className="ld-stats__caption">
						16 个品牌席位（2⁴）× 64 场（2⁶）= 1,024 场（2¹⁰）
					</p>
					<ol className="ld-path">
						{PERKS.map((p, i) => (
							<li key={p.t} className="ld-step">
								<span className="ld-step__index">{String(i + 1).padStart(2, "0")}</span>
								<h3 className="ld-step__title">{p.t}</h3>
								<p className="ld-step__desc">{p.d}</p>
							</li>
						))}
					</ol>
					<p className="ld-section__desc">
						专场打包合作 · 资源可折抵 · 首期 20 场验收后续批。
					</p>
				</div>
			</section>

			<section aria-labelledby="hsa-cta" className="ld-final">
				<div className="ld-container">
					<h2 id="hsa-cta">16 个席位（2⁴），先到先得</h2>
					<div className="ld-cta-row">
						<a href="mailto:wenyang@codingirlsclub.com" className="join-button join-button--primary">
							聊品牌专场合作
						</a>
						<a href="#hsa-join" className="ld-cta-quiet">
							我要参加 →
						</a>
					</div>
					<p className="ld-stats__caption">
						文洋 · wenyang@codingirlsclub.com · 15901003955 · WeChat 85861358
					</p>
				</div>
			</section>

			<footer className="ld-footer">
				<div className="ld-container ld-footer__inner">
					<BrandLockup className="ld-footer__brand" />
					<p>Coding Girls Club 程序媛汇 · 成立于 2016 · #hackerstart1024</p>
				</div>
			</footer>
		</main>
	);
}
