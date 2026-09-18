/**
 * 草图：志愿者申请页（单页叙事 + 尾部表单）——按 ABC 美好社会咨询社模式重构。
 * 模型（与创始人对话定稿）：招募批次（像咨询季：截止+执行周期）/ 多职位（场次主理人
 * featured + 教程研究员）/ 两段式网申（先完善简历档案，再申请项目）/ 四段流程
 * （网申 → 面试群面 → 训练营 → 项目分配，每段邮件+微信小程序通知）/ 同批仅申一个职位。
 * 经济模型：零出资零抽成；场地=免费合作+咖啡馆学员消费。Give and Take 叙事框架。
 * 草图定位：方向性低保真，只看结构/氛围/层级；职位要求、批次时间均为草案。
 */
import SiteHeader from "@/components/site-header";
import "../hs1024.css";

const ROLES = [
	{
		id: "host",
		featured: true,
		t: "场次主理人",
		en: "Event Moderator",
		duty: ["开场前：协调场地与时间、配合招生（报名走平台）", "现场 3 小时：执行单场 SOP——15 分钟开场 → 2 小时动手 → 30 分钟 demo", "场后：作品收集、数据复盘、滚动开班", "媒体素材：现场收集照片/视频，发动大家带 #hackerstart1024 标签发社媒"],
		reqs: ["认同「让普通人第一次用 Agent 做出作品」的使命", "能组织 8 人以上的线下场次（有场地或社群资源）", "每期可投入一个周末 + 共备时间，年满 18 岁", "无编程背景要求——课程包与 Agent 兜住技术环节"],
	},
	{
		id: "tutorial",
		featured: false,
		t: "教程研究员",
		en: "Tutor",
		duty: ["把 Agent 工作坊课程写成可复用的教程与示例项目", "与课程组共同迭代教学内容、案例与练习", "让每一场工作坊的教学质量可持续复制"],
		reqs: ["有编程与写作能力，能把技术讲给普通人听", "Agent coding 工具使用经验加分", "一门课程预估投入 5-10 小时", "远程协作，不限城市"],
	},
	{
		id: "coach",
		featured: false,
		t: "活动教练",
		en: "Coach",
		duty: ["线下活动现场的教学支持：巡场答疑、帮学员跑通动手环节", "现场看一看、解决点问题——学员自学为主，教练不讲课", "与主理人配合，保障单场体验"],
		reqs: ["用过 Agent coding 工具，能解现场常见卡点", "愿意陪跑、教学相长，无需授课经验", "按场次排班，一场 3 小时", "开班城市现场参与"],
	},
];

const HOST_DUTY = [
	{ t: "开场前", d: "协调场地与时间、配合招生（报名走平台，你不用做表单）、按物料清单准备现场" },
	{ t: "现场 3 小时", d: "执行单场 SOP：15 分钟开场 → 2 小时动手 → 30 分钟 demo；技术环节由课程包与 Agent 自适应学习兜底" },
	{ t: "场后", d: "作品收集、数据回收（平台自动）、现场素材整理与社媒动员（带 #hackerstart1024）、一次简短复盘；跑顺后滚动开班" },
];

const SUPPLY = [
	{ t: "课程包与 SOP", d: "定制课程内容、单场流程手册、Agent 自适应学习平台——照着做就能开一场" },
	{ t: "运营系统", d: "报名、69 元押金风控、到场核销全链路平台，你不碰钱" },
	{ t: "免费场地合作", d: "我们尽量找免费的合作场地；咖啡馆场次由学员现场消费支持——你没有场地预算压力，只负责落地协调" },
	{ t: "社区与曝光", d: "40+ 城主理人网络、128 名志愿者体系、campaign 级联合宣传；志愿者权益定稿中" },
];

const FLOW = [
	{
		t: "网申",
		what: "两小步：先【完善简历】（上传一次，跨批次复用），再【申请项目】（批次、职位、城市、投入）",
		you: "15 分钟填完；同批次只能选一个职位",
		when: "截止 2026.10.10 前（草案）",
		notice: "提交即收确认邮件",
		start: true,
	},
	{
		t: "面试",
		what: "邮件+微信小程序通知结果；通过后进微信群约群面——30 秒自我介绍 + 阅读材料集体讨论",
		you: "线上 30 分钟，展示你的表达与组织热情",
		when: "约 1 周",
		notice: "面试结果邮件+微信小程序通知",
	},
	{
		t: "训练营",
		what: "线上训练营（站内的一门课程）：课程 walkthrough + 共备，需确认出席；入选后运营会把你拉进对应课程",
		you: "完整走一次课程包，把第一场的每个环节过一遍",
		when: "1-2 周",
		notice: "训练营预约与结果邮件+微信小程序通知",
	},
	{
		t: "项目分配",
		what: "主理人指派到你的城市场次（成为场次主理人）；教程研究员分配课程任务——正式进入志愿者网络",
		you: "按你的节奏排期，平台持续支持",
		when: "训练营结束后",
		notice: "分配结果邮件+微信小程序通知",
	},
];

const FAQ_GROUPS = [
	{
		g: "共同关心",
		items: [
			{ q: "要花钱吗？", a: "不用。志愿者零出资零抽成：报名押金（69 元，到场退）全程走平台，你经手的是组织不是钱；场地以免费合作为主，不占你的预算。" },
			{ q: "简历传了之后怎么用？", a: "简历进入你的志愿者简历档案：本批和以后批次都能复用，不用重传；可随时更新。仅招募团队可见，遵循 PIPL，不用于招募以外的用途。" },
			{ q: "同一批能申请几个职位？", a: "一个。同一批次只能在可选职位中选一个参与；下一批可以换职位再申请。" },
			{ q: "可以同时做几个职位吗？", a: "可以。申请时一批一个职位；入职后职位不互斥——比如 Tutor 也可以去线下当 Coach，按场次和任务参与就行。" },
		],
	},
	{
		g: "场次主理人",
		items: [
			{ q: "需要编程背景吗？", a: "不需要。课程包和 Agent 自适应学习会兜住技术环节——你自己先作为参与者完整体验一次，就是最好的准备。（草案，待确认）" },
			{ q: "场地谁解决？", a: "我们尽量找免费的合作场地：社区空间、企业会议室、高校教室；用咖啡馆时，由学员现场消费来支持（到场点杯咖啡即可，不另付场地费）。你负责选点与协调落地。" },
			{ q: "一场多少人？我时间有限。", a: "8 人即可开班（2³）、32 人满班（2⁵）。建议一期一场起步，跑顺后再滚动。" },
		],
	},
	{
		g: "活动教练",
		items: [
			{ q: "要讲课吗？", a: "不用。学员自学为主（Agent 自适应学习陪跑），教练现场巡场、答疑、帮学员跑通动手环节——现场看一看、解决点问题就好。" },
			{ q: "和主理人什么关系？", a: "主理人管整场组织，教练管现场体验。可以只当教练，也可以在不同场次两个职位都做。" },
		],
	},
	{
		g: "教程研究员",
		items: [
			{ q: "一门课要投入多少时间？", a: "一门课程预估 5-10 小时，以课程为单位投入，不用每周固定坐班。" },
			{ q: "怎么协作？", a: "远程参与、不限城市，与课程组异步协作；你写的教程会被全国场次复用。" },
		],
	},
];

const FORM_STEPS = [
	{
		n: 1,
		t: "完善简历",
		fields: ["上传简历（PDF / Word，跨批次复用）", "手机号 · 姓名（登录后自动带出，可改）", "每周可投入小时数", "技能标签（多选：组织 / 社群 / 写作 / 开发 / 设计 / 其他）"],
	},
	{
		n: 2,
		t: "申请项目",
		fields: ["招募批次（默认当前批次：第 1 批）", "申请职位（单选：场次主理人 / 教程研究员）", "申请城市（教程研究员填「远程」）", "如何得知我们", "是否有内部推荐人", "想对我们说的话（选填）"],
	},
];

const MY_STATUS = ["网申", "面试", "训练营", "项目分配"];

export default function VolunteerApply() {
	return (
		<main className="hsd-root">
			<SiteHeader />

			{/* ① Hero */}
			<div className="hsd-hero-wrap">
				<div className="hsd-container">
					<section className="hsd-hero" aria-labelledby="vol-hero-t">
						<p className="hsd-hero__eyebrow">#HACKERSTART1024 · 成为志愿者 · JOIN THE CREW</p>
						<h1 className="hsd-hero__title" id="vol-hero-t">把 Hacker Start 1024<br />开到你的城市</h1>
						<p className="hsd-hero__sub">志愿者体系招募中：组织一场 3 小时的工作坊，或把课程写成教程。</p>
						<p className="hsd-hero__nums">
							<span><b>40+</b> 城 网络正在扩张</span>
							<span>单场 <b>8-32</b> 人</span>
							<span><b>1,024</b> 场</span>
						</p>
						<div className="hsd-hero__cta">
							<a href="#vol-form" className="hsd-cta--white">直接申请</a>
							<a href="#vol-roles" className="hsd-cta--outline">先看职位</a>
						</div>
						<div className="hsd-wave" aria-hidden="true">
							{[8, 16, 24, 32, 48, 64, 48, 80, 64, 100, 80, 64, 48, 32, 24, 16].map((h, i) => (
								<i key={i} style={{ height: `${h}%` }} />
							))}
						</div>
					</section>
				</div>
			</div>

			{/* ② 招募批次（ABC 咨询季式） */}
			<section className="hsd-section" aria-labelledby="cohort-t">
				<div className="hsd-container">
					<div className="hsd-badge-row">
						<span className="hsd-badge">当前批次</span>
						<span className="hsd-badge-label">Cohort</span>
					</div>
					<h2 className="hsd-title" id="cohort-t">
						第 1 批 · 首批招募，<em>时间规划透明</em>
					</h2>
					<div className="hsd-formula">
						<div className="hsd-fcell hsd-fcell--pink">
							<div className="hsd-fcell__v" style={{ fontSize: 26 }}>第 1 批</div>
							<div className="hsd-fcell__l">首批志愿者招募</div>
						</div>
						<div className="hsd-fcell hsd-fcell--mint">
							<div className="hsd-fcell__v" style={{ fontSize: 26 }}>10.10</div>
							<div className="hsd-fcell__l">申请截止（草案）· 23:59</div>
						</div>
						<div className="hsd-fcell hsd-fcell--solid">
							<div className="hsd-fcell__v" style={{ fontSize: 26 }}>2026.10-2027</div>
							<div className="hsd-fcell__l">执行周期 · 批次滚动</div>
						</div>
					</div>
					<p className="hsd-lead hsd-lead--muted" style={{ marginTop: 18 }}>
						每批单独招募、单独排期——错过这一批，下一批开放时可以再申请。
					</p>
				</div>
			</section>

			{/* ③ 选择职位（ABC 申请职位式：职位 + 职位描述） */}
			<section className="hsd-section" id="vol-roles" aria-labelledby="roles-t">
				<div className="hsd-container">
					<div className="hsd-badge-row">
						<span className="hsd-badge">选择你的职位</span>
						<span className="hsd-badge-label">Open Roles</span>
					</div>
					<h2 className="hsd-title" id="roles-t">
						一个体系，<em>三种打开方式</em>
					</h2>
					<div className="hsd-tiles">
						{ROLES.map((r, i) => (
							<div key={r.id} className="hsd-tile" style={r.featured ? { borderColor: "#c9497d", borderWidth: 2 } : undefined}>
								<div className="hsd-tile__t"><span className="hsd-tile__n">{i + 1}</span>
									{r.t}
									{r.featured ? <span style={{ marginLeft: 8, fontSize: 12, background: "#faedf2", color: "#b0406b", borderRadius: 999, padding: "3px 10px", fontWeight: 700 }}>首批最需要</span> : null}
									<small style={{ display: "block", color: "#b9b3c2", fontWeight: 400, letterSpacing: "0.08em" }}>{r.en}</small>
								</div>
								<div className="hsd-tile__d">
									<b style={{ color: "#2b2b33" }}>职责说明</b>
									<ul style={{ margin: "6px 0 10px", paddingLeft: 18 }}>
										{r.duty.map((d) => <li key={d}>{d}</li>)}
									</ul>
									<b style={{ color: "#2b2b33" }}>职位要求</b>
									<ul style={{ margin: "6px 0 0", paddingLeft: 18 }}>
										{r.reqs.map((q) => <li key={q}>{q}</li>)}
									</ul>
								</div>
							</div>
						))}
					</div>
					<div className="hsd-pill">
						<span>同一批次只能申请一个职位</span><span>·</span><span>下一批可换职位再申请</span><span>·</span><span>入职后职位不互斥，可跨角色参与</span>
					</div>
				</div>
			</section>

			{/* ④ featured 职位深读：主理人长什么样（职责/支持/经济模型） */}
			<section className="hsd-section" aria-labelledby="supply-t">
				<div className="hsd-container">
					<div className="hsd-badge-row">
						<span className="hsd-badge">走近「场次主理人」</span>
						<span className="hsd-badge-label">Role Deep-dive</span>
					</div>
					<blockquote className="hsd-epi">
						「The most meaningful way to succeed is to help others succeed.」
						<em>—— Adam Grant《Give and Take》</em>
					</blockquote>
					<h2 className="hsd-title" id="supply-t">给出一个周末，<em>收获一座城市</em></h2>
					<div className="hsd-cap3">
						{HOST_DUTY.map((d, i) => (
							<div key={d.t} className="hsd-tile">
								<div className="hsd-tile__t"><span className="hsd-tile__n">{i + 1}</span>{d.t}</div>
								<div className="hsd-tile__d">{d.d}</div>
							</div>
						))}
					</div>
					<div className="hsd-tiles" style={{ marginTop: 14 }}>
						{SUPPLY.map((s, i) => (
							<div key={s.t} className="hsd-tile">
								<div className="hsd-tile__t"><span className="hsd-tile__n">{i + 1}</span>{s.t}</div>
								<div className="hsd-tile__d">{s.d}</div>
							</div>
						))}
					</div>
				</div>
			</section>

			{/* ⑤ 流程四段（ABC 式：网申 → 面试 → 训练营 → 项目分配） */}
			<section className="hsd-section" aria-labelledby="flow-t">
				<div className="hsd-container">
					<div className="hsd-badge-row">
						<span className="hsd-badge">从申请到上岗</span>
						<span className="hsd-badge-label">The Journey</span>
					</div>
					<h2 className="hsd-title" id="flow-t">四段流程，<em>每段都知道会发生什么</em></h2>
					<div className="hsd-ladder">
						{FLOW.map((f, i) => (
							<div key={f.t} className="hsd-ladder__step" style={f.start ? { background: "#faedf2" } : undefined}>
								<span className="hsd-ladder__n">{String(i + 1).padStart(2, "0")}</span>
								<span style={{ flex: 1 }}>
									<span className="hsd-ladder__t" style={{ display: "block" }}>{f.t} <small style={{ color: "#b9b3c2", fontWeight: 400 }}>· {f.when}</small></span>
									<span className="hsd-ladder__d" style={{ display: "block" }}>{f.what}</span>
									<span className="hsd-ladder__d" style={{ display: "block", color: "#c9497d" }}>你要做的：{f.you}</span>
									<span className="hsd-ladder__d" style={{ display: "block", color: "#2fa69d", fontSize: 12.5 }}>📩 {f.notice}</span>
								</span>
							</div>
						))}
					</div>
					<p className="hsd-ladder__cap">时长为当前预期（草案）——每一段的结果都邮件+微信小程序双通道通知</p>
				</div>
			</section>

			{/* ⑥ 志愿者 FAQ */}
			<section className="hsd-section" id="vol-faq" aria-labelledby="vfaq-t">
				<div className="hsd-container">
					<div className="hsd-badge-row">
						<span className="hsd-badge">常见问题</span>
						<span className="hsd-badge-label">FAQ</span>
					</div>
					<h2 className="hsd-title" id="vfaq-t">申请之前，<em>你大概想问</em></h2>
					{FAQ_GROUPS.map((group) => (
						<div key={group.g}>
							<p className="hsd-sub">{group.g}</p>
							<div className="hsd-faq">
								{group.items.map((f) => (
									<details key={f.q}>
										<summary>{f.q}</summary>
										<p>{f.a}</p>
									</details>
								))}
							</div>
						</div>
					))}
				</div>
			</section>

			{/* ⑦ 两步申请表单（草图 UI，未接线） */}
			<section className="hsd-section" id="vol-form" aria-labelledby="form-t">
				<div className="hsd-container">
					<div className="hsd-badge-row">
						<span className="hsd-badge hsd-badge--mint">申请表单</span>
						<span className="hsd-badge-label">Apply</span>
					</div>
					<h2 className="hsd-title" id="form-t">两步网申，<em>先简历后项目</em></h2>
					<p className="hsd-lead hsd-lead--muted">登录后填写；过往申请人可直接更新简历、跳过已填内容。（两步流与状态自查为定稿交互，本草图未接线）</p>
					<div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(300px, 1fr))", gap: 14, maxWidth: 760 }}>
						{FORM_STEPS.map((s) => (
							<div key={s.n} className="hsd-tile" style={{ padding: 24 }}>
								<div className="hsd-tile__t"><span className="hsd-tile__n">{s.n}</span>{s.t}</div>
								<ul style={{ margin: "8px 0 0", paddingLeft: 18 }}>
									{s.fields.map((f) => <li key={f} className="hsd-tile__d" style={{ marginBottom: 4 }}>{f}</li>)}
								</ul>
							</div>
						))}
					</div>
					<span className="hsd-cta--rose" style={{ marginTop: 26 }}>提交申请</span>
					<p className="hsd-cta-note">简历档案仅招募团队可见，遵循 PIPL，不用于招募以外的用途</p>
				</div>
			</section>

			{/* ⑧ 我的申请（状态自查，草图示意） */}
			<section className="hsd-section" aria-labelledby="myst-t">
				<div className="hsd-container">
					<div className="hsd-badge-row">
						<span className="hsd-badge">我的申请</span>
						<span className="hsd-badge-label">My Application</span>
					</div>
					<h2 className="hsd-title" id="myst-t">提交之后，<em>随时可查</em></h2>
					<div className="hsd-timeline" style={{ gridTemplateColumns: "repeat(4, 1fr)" }}>
						{MY_STATUS.map((s, i) => (
							<div key={s} className={`hsd-tl__item${i === 1 ? " hsd-tl__item--start" : ""}`}>
								<div className="hsd-tl__t" style={{ fontSize: 14 }}>{s}</div>
								<div className="hsd-tl__d">{i < 1 ? "已完成" : i === 1 ? "当前：面试沟通中" : "待进行"}</div>
							</div>
						))}
					</div>
				</div>
			</section>

			<footer className="hsd-footer">
				<div className="hsd-container" style={{ display: "flex", flexWrap: "wrap", justifyContent: "space-between", gap: "8px 20px" }}>
					<span>Coding Girls Club 程序媛汇 · Hacker Start 1024 · <a href="/prototype/hackerstart-1024/variant-d" style={{ color: "#c9497d" }}>← 返回宣传页</a></span>
					<b>#hackerstart1024</b>
				</div>
			</footer>
		</main>
	);
}
