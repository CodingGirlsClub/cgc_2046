/**
 * 草图 Variant B —— campaign 专属视觉：浅色纸面 + 2 的幂主视觉（巨大 2¹⁰、二进制纹理）、
 * 等宽字体点缀；参与者段浅色，品牌段整体翻成深色席位面板（4×4=2⁴ 座位格视觉双关）。
 * 判断点：campaign 个性强、可独立传播 vs 与站点现有深色语言断裂。
 * 草图定位：方向性低保真，只看结构/氛围/层级。
 */
import SiteHeader from "@/components/site-header";
import "../hs1024.css";

const BINARY_1024 = "10000000000"; // 1024 的二进制

const SEATS = Array.from({ length: 16 }, (_, i) => i < 3);

const PERKS = [
	{ t: "系列命名", d: "专场系列名含你的品牌——联名系列，非单场冠名" },
	{ t: "定制课程", d: "课程主题、案例、教学路径按你的产品定制，课程完成即你的内容资产" },
	{ t: "现场转化钩子", d: "现场注册你的账号 / 发放产品权益 / 作品存入你的平台——激活变成可数的转化数据" },
	{ t: "下场观察", d: "你的团队直接进现场，零基础用户的第一手反馈进你的产品 backlog" },
];

export default function VariantB() {
	return (
		<main className="hs-root">
			<SiteHeader />

			<header className="hsb-hero">
				<div className="hs-container">
					<p className="hsb-kicker">#hackerstart1024 · Coding Girls Club 程序媛汇</p>
					<div className="hsb-hero__pow">
						2<sup>10</sup>
					</div>
					<h1 className="hsb-hero__title">Hacker Start 1024</h1>
					<p className="hsb-hero__sub">
						让普通人第一次亲手用 Agent 做出能跑的作品
					</p>
					<div className="hsb-hero__nums">
						<span>全国 1,024 场</span>
						<span>2026.10.24 启动</span>
						<span>40+ 城</span>
						<span>16 个品牌专场席位</span>
					</div>
					<div className="hs-cta-row">
						<a href="#hsb-join" className="hs-cta hs-cta--dark">我要参加</a>
						<a href="#hsb-brand" className="hs-cta hs-cta--ghost">品牌专场合作 →</a>
					</div>
				</div>
				<p className="hsb-hero__binary" aria-hidden="true">
					{Array.from({ length: 8 }, () => BINARY_1024).join(" ")}
				</p>
			</header>

			<section className="hsb-section" aria-labelledby="hsb-pow">
				<div className="hs-container">
					<p className="hsb-kicker">数字叙事 · 全篇沿 2 的幂</p>
					<div className="hsb-pows">
						<div className="hsb-pow">8 <small>人开班 · 2³</small></div>
						<div className="hsb-pow">32 <small>人满班 · 2⁵</small></div>
						<div className="hsb-pow">64 <small>场品牌专场 · 2⁶</small></div>
						<div className="hsb-pow">16 <small>个品牌席位 · 2⁴</small></div>
						<div className="hsb-pow">1,024 <small>场全国计划 · 2¹⁰</small></div>
					</div>
				</div>
			</section>

			<section className="hsb-section" aria-labelledby="hsb-why">
				<div className="hs-container">
					<p className="hsb-kicker">为什么是现在</p>
					<h2 className="hsb-title">Agent 已经过了能力拐点，缺的是普通人敢不敢开始</h2>
					<p className="hsb-lead">
						Agent coding 已经能干活了，瓶颈变成了「普通人敢不敢开始、第一次有没有人陪跑」。
						所有厂商的自然流量都是开发者；零基础普通人的第一次，市场上没有现成通道。
						Hacker Start 1024 就是这条通道。
					</p>
				</div>
			</section>

			<section className="hsb-section" id="hsb-join" aria-labelledby="hsb-join-t">
				<div className="hs-container">
					<p className="hsb-kicker">我要参加</p>
					<h2 className="hsb-title" id="hsb-join-t">3 小时，从零到上台 demo</h2>
					<div className="hsb-steps">
						<div className="hsb-step">
							<div className="hsb-step__n">01 · 15 min</div>
							<div className="hsb-step__t">开场</div>
							<div className="hsb-step__d">认识 Agent、认识同场伙伴——不写代码，先知道要做什么</div>
						</div>
						<div className="hsb-step">
							<div className="hsb-step__n">02 · 2 h</div>
							<div className="hsb-step__t">动手</div>
							<div className="hsb-step__d">Agent 自适应学习陪你跑，第一次亲手把想法变成能跑的作品</div>
						</div>
						<div className="hsb-step">
							<div className="hsb-step__n">03 · 30 min</div>
							<div className="hsb-step__t">Demo</div>
							<div className="hsb-step__d">人人上台展示自己的作品——带得走、发得出、跑得起来</div>
						</div>
					</div>
					<div className="hsb-facts">
						<span>8 人开班（2³）</span>
						<span>32 人满班（2⁵）</span>
						<span>69 元押金 · 到场即退</span>
						<span>18 岁以上</span>
					</div>
					<p className="hsb-lead" style={{ marginTop: 24 }}>
						首批场次 2026.10.24 起陆续开放，报名通道即将开启。
					</p>
				</div>
			</section>

			<section className="hsb-section" aria-labelledby="hsb-who">
				<div className="hs-container">
					<p className="hsb-kicker">我们是谁 · 2016-2025 历史累计</p>
					<div className="hsb-stats">
						<div><div className="hsb-stat__v">10 城</div><div className="hsb-stat__l">覆盖城市</div></div>
						<div><div className="hsb-stat__v">50+</div><div className="hsb-stat__l">线下工作坊</div></div>
						<div><div className="hsb-stat__v">4,000+</div><div className="hsb-stat__l">学员</div></div>
						<div><div className="hsb-stat__v">1,000+</div><div className="hsb-stat__l">教练</div></div>
						<div><div className="hsb-stat__v">2,000 万+</div><div className="hsb-stat__l">总阅读量</div></div>
						<div><div className="hsb-stat__v">17 所</div><div className="hsb-stat__l">高校联动</div></div>
					</div>
					<p className="hsb-endorse">
						中国首个、规模最大的女性编程社区（社会企业）。论文被 ICSE CHASE 2021（IEEE）收录；
						联合国开发计划署「科技与慈善」案例（2018）；共青团中央「伙伴计划」获奖;
						联合国妇女署 #科技遇见她#；中国日报 · 环球时报 · CCTV · 果壳网报道。
					</p>
					<div className="hsb-lever">本轮一个 campaign 的参与人数目标 ≈ 过去十年累计。</div>
				</div>
			</section>

			<section className="hsb-brand" id="hsb-brand" aria-labelledby="hsb-brand-t">
				<div className="hs-container">
					<p className="hsb-kicker">品牌专场合作</p>
					<h2 className="hsb-oneliner" id="hsb-brand-t">
						十年社区 × 你的品牌：用<em>为你定制的一门课</em>，把 512-2,048 名付费用户变成你的产品第一批普通人用户。
					</h2>
					<p className="hsb-seats-cap">16 席（2⁴）× 64 场（2⁶）＝ 1,024 场（2¹⁰）</p>
					<div className="hsb-seats" aria-hidden="true">
						{SEATS.map((open, i) => (
							<span key={i} className={`hsb-seat${open ? " hsb-seat--open" : ""}`}>
								{String(i + 1).padStart(2, "0")}
							</span>
						))}
					</div>
					<p className="hsb-seats-cap">品牌专场席位按签约进度更新 · 首批席位评审中</p>
					<div className="hsb-perks">
						{PERKS.map((p) => (
							<div key={p.t} className="hsb-perk">
								<div className="hsb-perk__t">{p.t}</div>
								<div className="hsb-perk__d">{p.d}</div>
							</div>
						))}
					</div>
					<p className="hsb-lead" style={{ marginTop: 28 }}>
						专场打包合作 · 资源可折抵 · 首期 20 场验收后续批。
						请附一句话介绍你的产品与期望的专场主题，48 小时内回复。
					</p>
					<div className="hs-cta-row">
						<a href="mailto:wenyang@codingirlsclub.com" className="hs-cta hs-cta--gold">
							聊品牌专场合作
						</a>
					</div>
					<p className="hsb-seats-cap" style={{ marginTop: 20 }}>
						文洋 · wenyang@codingirlsclub.com · 15901003955 · WeChat 85861358
					</p>
				</div>
			</section>

			<footer className="hsb-footer">
				<div className="hs-container" style={{ display: "flex", flexWrap: "wrap", gap: "8px 24px" }}>
					<span>Coding Girls Club 程序媛汇 · 成立于 2016</span>
					<span>#hackerstart1024</span>
				</div>
			</footer>
		</main>
	);
}
