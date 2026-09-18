/**
 * 小程序版原型 · 志愿者申请页（weapp-host）——视觉参考 miniprogram/ 现有样式。
 * 批次卡用小程序 visitor 卡同款橙色渐变；职位卡用 initiative 卡橙左边框；
 * 底部 Tab 高亮「我的」。完整叙事在网站版（host-apply）。
 * 草图定位：方向性低保真，只看结构/氛围/层级。
 */
import "../weapp.css";

const Pow = ({ n }: { n: number | string }) => (
	<span className="wep-pow">2<sup>{n}</sup></span>
);

const ROLES = [
	{ k: "EVENT MODERATOR", t: "场次主理人", d: "组织一场 3 小时工作坊的完整 owner——把它开到你的城市。适合有场地或社群资源、每期一个周末的组织者。", chip: "首批最需要" },
	{ k: "TUTOR", t: "教程研究员", d: "把课程写成可复用的教程与示例项目，一门课预估投入 5-10 小时。适合会编程、能写作的程序员，远程参与。" },
	{ k: "COACH", t: "活动教练", d: "线下现场辅助陪跑：巡场答疑、帮学员跑通动手环节，学员自学为主、不讲课。适合用过 Agent 工具的人。" },
];

const FLOW = [
	{ t: "网申", d: "先完善简历（跨批复用），再申请项目：批次、职位、城市。同批限申一个职位" },
	{ t: "面试", d: "线上群面约 30 分钟——微信群约时间，自我介绍 + 材料共读讨论" },
	{ t: "训练营", d: "线上训练营（站内的一门课程）：walkthrough + 共备，入选后运营拉你进课程" },
	{ t: "项目分配", d: "主理人指派场次、Tutor 分配课程任务——正式进入志愿者网络" },
];

const TABS = [
	{ i: "🧭", t: "发现", on: false },
	{ i: "📋", t: "我的报名", on: false },
	{ i: "🛠", t: "工作台", on: false },
	{ i: "👤", t: "我的", on: true },
];

export default function WeappHost() {
	return (
		<main className="wep-phone">
			<div className="wep-nav">当志愿者</div>

			<div className="wep-hero">
				<span className="wep-brand">HACKER START 1024 · <em>VOLUNTEER CREW</em></span>
				<h1>把 Hacker Start 1024<br />开到你的城市</h1>
				<span className="wep-sub">志愿者体系招募中：组织一场 3 小时的工作坊，或把课程写成教程。</span>
			</div>

			<div className="wep-body">
				<p className="wep-section-h">当前批次 <small>COHORT</small></p>
				<div className="wep-card" style={{ background: "linear-gradient(135deg, #ea5504, #f26a1f)", color: "#fff", boxShadow: "0 5px 14px rgba(234,85,4,.22)" }}>
					<span className="wep-chip" style={{ background: "rgba(255,255,255,.2)", color: "#fff" }}>进行中</span>
					<div className="wep-card__t" style={{ color: "#fff" }}>第 1 批 · 首批志愿者招募</div>
					<div className="wep-card__d" style={{ color: "rgba(255,255,255,.88)" }}>报名截止 2026.10.10（草案）· 执行周期 2026.10-2027 批次滚动。错过这批，下一批可再申请。</div>
				</div>

				<p className="wep-section-h">选择你的职位 <small>OPEN ROLES</small></p>
				{ROLES.map((r) => (
					<div key={r.t} className="wep-card wep-card--border">
						<span className="wep-card__kicker">{r.k}</span>
						{r.chip ? <span className="wep-chip" style={{ marginLeft: 8 }}>{r.chip}</span> : null}
						<div className="wep-card__t">{r.t}</div>
						<div className="wep-card__d">{r.d}</div>
					</div>
				))}
				<div className="wep-card__d" style={{ textAlign: "center" }}>同一批次只能申请一个职位 · 入职后职位不互斥</div>

				<p className="wep-section-h">从申请到上岗 <small>THE JOURNEY</small></p>
				<div className="wep-card">
					<ul className="wep-steps">
						{FLOW.map((f, i) => (
							<li key={f.t}><span className="wep-steps__n">{i + 1}</span><span><b>{f.t}</b> · {f.d}</span></li>
						))}
					</ul>
				</div>
				<div className="wep-card__d" style={{ textAlign: "center" }}>📩 每一段的结果都邮件+微信小程序双通道通知</div>

				<a href="#wep-apply" className="wep-cta wep-cta-block">登录并申请（10 分钟）</a>
				<p className="wep-note">两步网申：先完善简历档案，再申请项目 · 简历仅招募团队可见（PIPL）</p>
				<a href="/prototype/hackerstart-1024/host-apply" className="wep-note" style={{ display: "block" }}>查看完整版申请页（网站） ›</a>
			</div>

			<div className="wep-tabbar">
				{TABS.map((t) => (
					<span key={t.t} className={`wep-tab${t.on ? " wep-tab--on" : ""}`}><i>{t.i}</i>{t.t}</span>
				))}
			</div>
		</main>
	);
}
