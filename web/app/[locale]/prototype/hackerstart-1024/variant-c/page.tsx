/**
 * 草图 Variant C —— 混合：深色门面（复用 ld-hero，与首页同语言开屏）→ 浅色正文中段
 * （参与者叙事 + 十年信任，含「十年 → 1,024 场」刻度条）→ 深色品牌尾段（席位格）。
 * 双入口 = 深色 hero 双 CTA；页面呈「深-浅-深」三段式。
 * 判断点：站点一致性与 campaign 个性的折中是否成立。
 * 草图定位：方向性低保真，只看结构/氛围/层级。
 */
import SiteHeader from "@/components/site-header";
import "../hs1024.css";

const STEPS = [
	{ t: "15 分钟开场", d: "认识 Agent、认识同场伙伴——不写代码，先知道要做什么" },
	{ t: "2 小时动手", d: "Agent 自适应学习陪你跑，第一次亲手把想法变成能跑的作品" },
	{ t: "30 分钟 demo", d: "人人上台展示自己的作品——带得走、发得出、跑得起来" },
];

const PERKS = [
	{ t: "系列命名", d: "专场系列名含你的品牌——联名系列，非单场冠名" },
	{ t: "定制课程", d: "课程主题、案例、教学路径按你的产品定制，课程完成即你的内容资产" },
	{ t: "现场转化钩子", d: "现场注册你的账号 / 发放产品权益 / 作品存入你的平台——激活变成可数的转化数据" },
	{ t: "下场观察", d: "你的团队直接进现场，零基础用户的第一手反馈进你的产品 backlog" },
];

const SEATS = Array.from({ length: 16 }, (_, i) => i < 3);

export default function VariantC() {
	return (
		<main className="ld-root">
			<SiteHeader />

			{/* 深色门面：站点语言开屏 */}
			<section aria-labelledby="hsc-hero" className="ld-hero">
				<div className="ld-container">
					<p className="ld-kicker">
						<span className="ld-kicker__dot" aria-hidden="true" />
						#hackerstart1024 · Coding Girls Club 程序媛汇
					</p>
					<h1 id="hsc-hero" className="ld-display">
						Hacker Start 1024
					</h1>
					<p className="ld-section__desc" style={{ maxWidth: "34em" }}>
						让普通人第一次亲手用 Agent 做出能跑的作品
					</p>
					<div className="ld-cta-row">
						<a href="#hsc-join" className="join-button join-button--primary">我要参加</a>
						<a href="#hsc-brand" className="ld-cta-quiet">品牌专场合作 →</a>
					</div>
					<p className="ld-stats__caption" style={{ marginTop: 56 }}>
						全国 1,024 场（2¹⁰）· 2026.10.24 启动 · 40+ 城 · 16 个品牌专场席位（2⁴）
					</p>
				</div>
			</section>

			{/* 浅色中段：参与者叙事 */}
			<div className="hsc-light">
				<div className="hs-container">
					{/* 刻度条：十年 → 1,024 场 */}
					<div className="hsc-scale" role="img" aria-label="2016 年成立，十年积累，2026.10.24 启动 1,024 场">
						<span className="hsc-scale__tick">2016 · 十年社区</span>
						<span className="hsc-scale__rail">
							<span className="hsc-scale__fill" />
							<span className="hsc-scale__dot" />
							<span className="hsc-scale__now">2026.10.24 启动</span>
						</span>
						<span className="hsc-scale__tick">1,024 场</span>
					</div>
					<p className="hsc-scale-cap">本轮一个 campaign 的参与人数目标 ≈ 过去十年累计（2016-2025 历史累计：10 城 · 50+ 场工作坊 · 4,000+ 学员 · 阅读 2,000 万+）</p>
				</div>

				<section className="hsc-section" aria-labelledby="hsc-why">
					<div className="hs-container">
						<p className="hsc-kicker">为什么是现在</p>
						<h2 className="hsc-title">Agent 已经过了能力拐点，缺的是普通人敢不敢开始</h2>
						<p className="hsc-lead">
							Agent coding 已经能干活了，瓶颈变成了「普通人敢不敢开始、第一次有没有人陪跑」。
							所有厂商的自然流量都是开发者；零基础普通人的第一次，市场上没有现成通道。
							Hacker Start 1024 就是这条通道：3 小时一场 · 8-32 人小班 · Agent
							自适应学习 · 69 元押金（到场退）。
						</p>
					</div>
				</section>

				<section className="hsc-section" id="hsc-join" aria-labelledby="hsc-join-t">
					<div className="hs-container">
						<p className="hsc-kicker">我要参加</p>
						<h2 className="hsc-title" id="hsc-join-t">3 小时，从零到上台 demo</h2>
						<div className="hsc-steps">
							{STEPS.map((s) => (
								<div key={s.t}>
									<b>{s.t}</b>
									{s.d}
								</div>
							))}
						</div>
						<p className="hsc-lead" style={{ marginTop: 22 }}>
							8 人开班（2³）· 32 人满班（2⁵）· 18 岁以上。
							首批场次 2026.10.24 起陆续开放，报名通道即将开启。
						</p>
					</div>
				</section>

				<section className="hsc-section" aria-labelledby="hsc-who">
					<div className="hs-container">
						<p className="hsc-kicker">我们是谁</p>
						<h2 className="hsc-title">十年社区，国家级背书</h2>
						<p className="hsc-lead">
							Coding Girls Club 程序媛汇，2016 年成立，中国首个、规模最大的女性编程社区（社会企业）。
							论文被 ICSE CHASE 2021（IEEE）收录；联合国开发计划署「科技与慈善」案例（2018）；
							共青团中央「伙伴计划」获奖；联合国妇女署 #科技遇见她#；中国日报 · 环球时报 · CCTV · 果壳网报道。
						</p>
					</div>
				</section>
			</div>

			{/* 深色尾段：品牌席位 */}
			<section className="hsc-dark" id="hsc-brand" aria-labelledby="hsc-brand-t">
				<div className="hs-container">
					<p className="hsc-kicker">品牌专场合作</p>
					<h2 className="hsc-title" id="hsc-brand-t" style={{ maxWidth: "26em" }}>
						十年社区 × 你的品牌：把 512-2,048 名付费用户变成你的产品第一批普通人用户
					</h2>
					<p className="hsc-lead">
						联合主办 64 场品牌专场，用为你定制的一门课——系列命名 / 定制课程 / 现场转化钩子 / 下场观察。
					</p>
					<p className="hsb-seats-cap">16 席（2⁴）× 64 场（2⁶）＝ 1,024 场（2¹⁰）</p>
					<div className="hsc-seats" aria-hidden="true">
						{SEATS.map((open, i) => (
							<span key={i} className={`hsc-seat${open ? " hsc-seat--open" : ""}`} />
						))}
					</div>
					<p className="hsb-seats-cap">品牌专场席位按签约进度更新 · 首批席位评审中 · 专场打包 · 资源可折抵 · 首期 20 场验收后续批</p>
					<div className="hs-cta-row">
						<a href="mailto:wenyang@codingirlsclub.com" className="hs-cta hs-cta--light">
							聊品牌专场合作 · 48 小时内回复
						</a>
					</div>
					<p className="hsb-seats-cap" style={{ marginTop: 20 }}>
						文洋 · wenyang@codingirlsclub.com · 15901003955 · WeChat 85861358
					</p>
				</div>
			</section>

			<footer className="ld-footer">
				<div className="ld-container ld-footer__inner">
					<p>Coding Girls Club 程序媛汇 · 成立于 2016 · #hackerstart1024</p>
				</div>
			</footer>
		</main>
	);
}
