/**
 * 小程序版原型 · 宣传页（weapp-d）——视觉参考 miniprogram/ 现有样式：
 * 橙 #ea5504 / 浅灰底 / 白卡圆角 / 渐变 hero / 底部 4 Tab。
 * 内容为宣传页的手机小程序浓缩版；完整叙事在网站版（variant-d）。
 * 草图定位：方向性低保真，只看结构/氛围/层级。
 */
import "../weapp.css";

const Pow = ({ n }: { n: number | string }) => (
	<span className="wep-pow">2<sup>{n}</sup></span>
);

const TABS = [
	{ i: "🧭", t: "发现", on: true },
	{ i: "📋", t: "我的报名", on: false },
	{ i: "🛠", t: "工作台", on: false },
	{ i: "👤", t: "我的", on: false },
];

export default function WeappD() {
	return (
		<main className="wep-phone">
			<div className="wep-nav">程序媛汇</div>

			<div className="wep-hero">
				<span className="wep-brand">程序媛汇 · <em>十周年 CAMPAIGN</em></span>
				<h1>Hacker Start 1024</h1>
				<span className="wep-sub">让普通人第一次亲手用 Agent 做出能跑的作品</span>
				<div className="wep-nums">
					<span><b>1,024</b> 场（<Pow n={10} />）</span>
					<span><b>10.24</b> 启动（<Pow n={0} />）</span>
					<span><b>16</b> 席位（<Pow n={4} />）</span>
				</div>
				<div className="wep-cta-row">
					<a href="/prototype/hackerstart-1024/weapp-host" className="wep-cta">我要参加 / 当志愿者</a>
					<a href="#wep-brand" className="wep-cta wep-cta--ghost">品牌合作</a>
				</div>
			</div>

			<div className="wep-body">
				<p className="wep-section-h">参与方式 <small>THREE WAYS IN</small></p>
				<div className="wep-card wep-card--border">
					<span className="wep-card__kicker">JOIN</span><span className="wep-arrow">›</span>
					<div className="wep-card__t">我要参加一场</div>
					<div className="wep-card__d">3 小时工作坊：15 分钟开场 · 2 小时动手 · 30 分钟 demo。8 人开班（<Pow n={3} />）、32 人满班（<Pow n={5} />），69 元押金到场退。场次陆续上线。</div>
				</div>
				<div className="wep-card wep-card--border">
					<span className="wep-card__kicker">VOLUNTEER</span><span className="wep-arrow">›</span>
					<div className="wep-card__t">成为志愿者</div>
					<div className="wep-card__d">三个职位：场次主理人 / 教程研究员 Tutor / 活动教练 Coach。零出资零抽成，四段流程全程通知。</div>
				</div>
				<div className="wep-card wep-card--border" id="wep-brand">
					<span className="wep-card__kicker">BRAND</span><span className="wep-arrow">›</span>
					<div className="wep-card__t">品牌专场合作</div>
					<div className="wep-card__d">16 席（<Pow n={4} />）× 64 场（<Pow n={6} />）＝ 1,024 场（<Pow n={10} />）。用为你定制的课程，触达第一批普通人用户。partners@codingirlsclub.com · 48 小时内回复。</div>
				</div>

				<p className="wep-section-h">接下来会发生什么 <small>TIMELINE</small></p>
				<div className="wep-card">
					<ul className="wep-steps">
						<li><span className="wep-steps__n">1</span><span><b>2026.10.24 启动</b>（<Pow n={0} />）· 全国首场开课</span></li>
						<li><span className="wep-steps__n">2</span><span><b>首期 64 场</b> · 首批场次集中交付</span></li>
						<li><span className="wep-steps__n">3</span><span><b>批次滚动</b> · 40+ 城陆续开班，直至 1,024 场</span></li>
					</ul>
				</div>

				<p className="wep-section-h">十年社区，可以被查证的十年 <small>RECOGNITION</small></p>
				<div className="wep-card">
					<div className="wep-card__d">
						2016-2025 历史累计：10 城 · 50+ 场工作坊 · 4,000+ 学员 · 阅读 2,000 万+。
						ICSE CHASE 2021 论文收录、UNDP 案例、中国日报 / 环球时报 / CCTV 报道——条条可点开查证。
						<span style={{ color: "#ea5504", fontWeight: 700 }}> 本轮一个 campaign 的参与人数目标 ≈ 过去十年累计。</span>
					</div>
				</div>

				<a href="/prototype/hackerstart-1024/variant-d" className="wep-note" style={{ display: "block" }}>查看完整版宣传页（网站） ›</a>
			</div>

			<div className="wep-tabbar">
				{TABS.map((t) => (
					<span key={t.t} className={`wep-tab${t.on ? " wep-tab--on" : ""}`}><i>{t.i}</i>{t.t}</span>
				))}
			</div>
		</main>
	);
}
