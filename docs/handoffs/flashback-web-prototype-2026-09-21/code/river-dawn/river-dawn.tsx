"use client";

import { useCallback, useEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";
import MapScene from "./map-scene";
import { CITIES, QUOTES, STAGES, WISHES, type City, type Entry, type Mode } from "./data";
import styles from "./river.module.css";

type Dialog = "share" | "write" | "recover" | "echo" | "notify" | "private" | null;
function Icon({ name, filled = false }: { name: string; filled?: boolean }) {
	const paths: Record<string, ReactNode> = {
		heart: <path d="M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.7l-1.1-1.1a5.5 5.5 0 0 0-7.8 7.8L12 21l8.8-8.6a5.5 5.5 0 0 0 0-7.8Z" />,
		share: <><path d="M12 16V2m-4 4 4-4 4 4M5 10H3v11h18V10h-2" /></>,
		arrow: <path d="M3 12h18m-6-6 6 6-6 6" />,
		back: <path d="M21 12H3m6-6-6 6 6 6" />,
		replay: <><path d="M4 8a9 9 0 1 1-1 8M4 3v5h5M12 7v5l3 2" /></>,
		write: <><path d="m15 4 5 5-11 11H4v-5ZM13 6l5 5M4 22h17" /></>,
		ring: <><circle cx="12" cy="12" r="10" /><circle cx="12" cy="12" r="6" /><circle cx="12" cy="12" r="2" /></>,
		bell: <><path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9ZM10 21h4" /></>,
		close: <path d="m5 5 14 14M19 5 5 19" />,
		check: <path d="m4 12 5 5L20 6" />,
		phone: <><rect x="6" y="2" width="12" height="20" rx="2" /><path d="M10 18h4" /></>,
	};
	return <svg width="20" height="20" viewBox="0 0 24 24" fill={filled ? "currentColor" : "none"} stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{paths[name] || paths.arrow}</svg>;
}

function Modal({ title, children, onClose }: { title: string; children: ReactNode; onClose: () => void }) {
	const ref = useRef<HTMLDialogElement>(null);
	useEffect(() => { ref.current?.showModal(); }, []);
	return <dialog ref={ref} className={styles.dialog} onCancel={onClose} onClose={onClose}
		onClick={event => { if (event.target === event.currentTarget) onClose(); }} aria-label={title}>
		<div className={styles.dialogInner}>
			<div className={styles.dialogHeader}><span>闪念间 / {title}</span><button onClick={onClose} aria-label="关闭"><Icon name="close" /></button></div>
			{children}
		</div>
	</dialog>;
}

export default function RiverDawn({ initialMode, initialId, initialCity, showIntro }: {
	initialMode: Mode; initialId?: string; initialCity?: string; showIntro: boolean;
}) {
	const first = (initialMode === "voices" ? QUOTES : WISHES).find(q => q.id === initialId)
		|| (initialMode === "voices" ? QUOTES : WISHES).find(q => q.city === initialCity)
		|| (initialMode === "voices" ? QUOTES : WISHES)[0];
	const [mode, setMode] = useState<Mode>(initialMode);
	const [city, setCity] = useState<City>(first.city);
	const [currentId, setCurrentId] = useState(first.id);
	const [wishes, setWishes] = useState(WISHES);
	const [likes, setLikes] = useState<Set<string>>(new Set());
	const [expectations, setExpectations] = useState<Set<string>>(new Set());
	const [progress, setProgress] = useState(showIntro ? 0 : 1);
	const [playing, setPlaying] = useState(showIntro);
	const [playback, setPlayback] = useState(0);
	const [storyboard, setStoryboard] = useState(false);
	const [phone, setPhone] = useState(false);
	const [dialog, setDialog] = useState<Dialog>(null);
	const [shareAll, setShareAll] = useState(false);
	const [shareUrl, setShareUrl] = useState("");
	const [copied, setCopied] = useState(false);
	const [toast, setToast] = useState("");
	const [pulse, setPulse] = useState(0);
	const [echoOnly, setEchoOnly] = useState(false);
	const [draft, setDraft] = useState("");
	const [draftCity, setDraftCity] = useState<City>(first.city);
	const [visibility, setVisibility] = useState("public");
	const [identity, setIdentity] = useState("anonymous");
	const [notified, setNotified] = useState<Set<string>>(new Set());
	const [recoveryNext, setRecoveryNext] = useState(false);
	const reduced = useRef(false);
	const progressRef = useRef(progress);
	const isIntro = progress < 1;
	const entries = mode === "voices" ? QUOTES : wishes;
	const available = echoOnly && mode === "wishes" ? entries.filter(q => q.echo) : entries;
	const current = entries.find(q => q.id === currentId) || entries[0];
	const count = current.count + ((mode === "voices" ? likes : expectations).has(current.id) ? 1 : 0);
	const stage = progress < 0.18 ? 0 : progress < 0.46 ? 1 : progress < 0.86 ? 2 : 3;
	const currentIndex = available.findIndex(q => q.id === current.id);
	const daylight = Math.min(1, Math.max(0, (progress - 0.87) / 0.13));

	const updateUrl = useCallback((nextMode: Mode, entry?: Entry) => {
		const url = new URL(window.location.href);
		url.search = "";
		url.searchParams.set("view", nextMode);
		url.searchParams.set("intro", "0");
		if (entry) { url.searchParams.set("city", entry.city); url.searchParams.set("item", entry.id); }
		window.history.replaceState(null, "", url);
	}, []);
	const finishIntro = useCallback(() => {
		setPlaying(false); setProgress(1); progressRef.current = 1;
		const url = new URL(window.location.href); url.searchParams.set("intro", "0");
		window.history.replaceState(null, "", url);
	}, []);
	useEffect(() => {
		const query = window.matchMedia("(prefers-reduced-motion: reduce)");
		const sync = () => { reduced.current = query.matches; if (query.matches) finishIntro(); };
		sync(); query.addEventListener("change", sync);
		return () => query.removeEventListener("change", sync);
	}, [finishIntro]);
	useEffect(() => {
		if (!playing) return;
		let frame = 0;
		let cancelled = false;
		const start = performance.now() - progressRef.current * 6400;
		const tick = (now: number) => {
			if (cancelled) return;
			const p = Math.min(1, (now - start) / 6400);
			progressRef.current = p; setProgress(p);
			if (p < 1) frame = requestAnimationFrame(tick); else finishIntro();
		};
		frame = requestAnimationFrame(tick);
		return () => { cancelled = true; cancelAnimationFrame(frame); };
	}, [playing, playback, finishIntro]);
	useEffect(() => {
		if (!toast) return;
		const timer = window.setTimeout(() => setToast(""), 3400);
		return () => window.clearTimeout(timer);
	}, [toast]);
	const select = (entry: Entry) => {
		finishIntro(); setCity(entry.city); setCurrentId(entry.id); setPulse(0);
		updateUrl(mode, entry);
	};
	const selectCity = (next: City) => {
		const entry = (isIntro ? entries : available).find(q => q.city === next);
		if (isIntro) setEchoOnly(false);
		if (entry) select(entry);
		else setToast(`${next}还没有${echoOnly ? "回响" : "公开内容"}，可以看看其他城市。`);
	};
	const switchMode = (next: Mode) => {
		finishIntro(); setMode(next); setEchoOnly(false); setPulse(0);
		const list = next === "voices" ? QUOTES : wishes;
		const entry = list.find(q => q.city === city) || list[0];
		setCurrentId(entry.id); setCity(entry.city); updateUrl(next, entry);
	};
	const navigate = (step: number) => select(available[(Math.max(0, currentIndex) + step + available.length) % available.length]);
	const toggleReaction = () => {
		const set = mode === "voices" ? setLikes : setExpectations;
		const had = (mode === "voices" ? likes : expectations).has(current.id);
		set(prev => { const copy = new Set(prev); if (copy.has(current.id)) copy.delete(current.id); else copy.add(current.id); return copy; });
		if (!had && !reduced.current) setPulse(n => n + 1);
		if (!had) setToast(mode === "voices" ? "谢谢你，让这句话被更多人听见。" : "你已加入这份期待。是否接收提醒，由你选择。");
	};
	const openShare = (all = false) => {
		setShareAll(all); setCopied(false);
		const url = new URL(window.location.href); url.search = "";
		url.searchParams.set("view", mode); url.searchParams.set("entry", "share");
		if (!all && !current.mine) url.searchParams.set("item", current.id);
		setShareUrl(url.toString()); setDialog("share");
	};
	const replay = () => {
		if (reduced.current) { setToast("已按系统设置减少动态效果，直接展示白昼。"); return; }
		progressRef.current = 0; setProgress(0); setPlaying(true); setPlayback(n => n + 1); setStoryboard(false);
	};
	const inspectFrame = (index: number) => { setPlaying(false); progressRef.current = STAGES[index].at; setProgress(STAGES[index].at); };
	const submitWish = (event: React.FormEvent) => {
		event.preventDefault();
		if (!draft.trim()) return;
		if (visibility === "private") { setDialog("private"); return; }
		const entry: Entry = { id: `demo-${wishes.length + 1}`, city: draftCity, text: draft.trim(), author: identity === "anonymous" ? "林**" : "小林", year: 2026, count: 0, mine: true };
		setWishes(prev => [...prev, entry]); setMode("wishes"); setCity(entry.city); setCurrentId(entry.id); setEchoOnly(false);
		setDialog(null); setDraft(""); setPulse(n => n + 1); setToast("你的愿望，已经挂在这里了。仅在本次原型体验中保留。");
		updateUrl("wishes");
	};

	return <div className={styles.prototype}>
		<div className={`${styles.viewport} ${phone ? styles.phonePreview : ""}`}>
		<div className={`${styles.app} ${isIntro ? styles.inIntro : ""} ${isIntro && progress > 0.94 ? styles.dayText : ""}`} style={{ "--daylight": daylight } as CSSProperties} data-mode={mode}>
			<div className={styles.atmosphere} />
			<a className={styles.skipLink} href="#river-reading">跳到阅读区</a>
			<header className={styles.header}>
				<a className={styles.brand} href="?intro=0" aria-label="闪念间金句墙"><strong>闪念间<span className={styles.brandSeal}>间</span></strong><small>by Coding Girls Club</small></a>
				<nav className={styles.nav} aria-label="公开空间">
					<button className={mode === "voices" ? styles.activeNav : ""} onClick={() => switchMode("voices")} aria-pressed={mode === "voices"}>金句墙 <span>VOICES</span></button>
					<button className={mode === "wishes" ? styles.activeNav : ""} onClick={() => switchMode("wishes")} aria-pressed={mode === "wishes"}>许愿树 <span>WISHES</span></button>
				</nav>
				<div className={styles.headerActions}>{isIntro ? <button onClick={finishIntro}>跳过片头 <Icon name="arrow" /></button> : <>
					{mode === "wishes" && <button className={styles.primary} onClick={() => { setDraftCity(city); setDialog("write"); }}><Icon name="write" />写下我的愿望</button>}
					<button onClick={() => openShare(true)} aria-label={mode === "voices" ? "分享金句墙" : "分享许愿树"}><Icon name="share" /><span>分享{mode === "voices" ? "金句墙" : "许愿树"}</span></button>
				</>}</div>
			</header>

			<main className={styles.workspace}>
				<section className={styles.mapSection} aria-label="山河与城市">
					<div className={styles.mapHeading}><div><p className={styles.eyebrow}>{mode === "voices" ? "2012 — 2018 / 那些年的声音" : "WISHES / 把期待留在这里"}</p><h1>{mode === "voices" ? "山河之间，听见彼此。" : "山河已亮，愿望继续生长。"}</h1></div><span className={styles.mapTag}>{mode === "voices" ? "12 个声音" : `${wishes.length} 个愿望`}</span></div>
					<MapScene city={city} mode={mode} progress={progress} onCity={selectCity} pulse={pulse} selectedWish={mode === "wishes" ? current.text : undefined} onRead={() => { document.getElementById("river-reading")?.focus({ preventScroll: true }); document.getElementById("river-reading")?.scrollIntoView({ block: "nearest" }); }} />
					{isIntro && <div className={styles.introCaption}><p className={styles.eyebrow}>一场相遇，很多种可能</p><h1><span>0{stage + 1}</span> {STAGES[stage].name}</h1><p>{STAGES[stage].text}</p><small>点击城市，随时开始阅读。传播起点与顺序为原型示意。</small></div>}
					<div className={styles.mapFoot}><span><i />青绿山川</span><span><i />声音与愿望的连接</span><button onClick={replay}><Icon name="replay" />重看山河亮起</button></div>
					<div className={styles.cityBar} aria-label="按城市浏览"><span>选择城市</span>{CITIES.map(c => <button key={c.name} onClick={() => selectCity(c.name)} aria-pressed={city === c.name}>{c.name}</button>)}</div>
				</section>

				<section className={styles.reader} id="river-reading" tabIndex={-1} aria-label={mode === "voices" ? "金句阅读区" : "愿望阅读区"}>
					<div className={styles.readerTop}><p className={styles.eyebrow}>{mode === "voices" ? "那年，她这样写" : "一个面向未来的愿望"}<span /></p><span className={styles.location}>{city}</span></div>
					{mode === "wishes" && <div className={styles.filters} aria-label="愿望筛选"><button aria-pressed={!echoOnly} onClick={() => setEchoOnly(false)}>全部</button><button aria-pressed={echoOnly} onClick={() => { setEchoOnly(true); const q = wishes.find(w => w.city === city && w.echo) || wishes.find(w => w.echo); if (q) select(q); }}>已有回响</button></div>}
					<blockquote className={`${styles.quote} ${mode === "wishes" ? styles.wishQuote : ""}`} data-testid="selected-text">{current.id === "q1" ? <><span>我想成为一个，</span><span>敢说「我不会，</span><span>但我可以学」的人。</span></> : current.text}</blockquote>
					<p className={styles.attribution}>{current.author}<span>·</span>{mode === "voices" && <>{current.year}<span>·</span></>}{current.city}{current.mine && <span className={styles.mine}>我的愿望</span>}</p>
					{mode === "wishes" && <p className={styles.expectCount}><strong>{count}</strong> 人也在期待</p>}
					<div className={styles.reactions}>
						<button className={mode === "wishes" ? styles.primary : styles.likeButton} onClick={toggleReaction} aria-pressed={(mode === "voices" ? likes : expectations).has(current.id)} aria-label={mode === "voices" ? "赞这句话" : "我也期待"}>
							<Icon name={mode === "voices" ? "heart" : expectations.has(current.id) ? "check" : "ring"} filled={mode === "voices" && likes.has(current.id)} />
							{mode === "voices" ? count : expectations.has(current.id) ? "已加入期待" : "我也期待"}
						</button>
						<button className={mode === "voices" ? styles.primary : styles.secondary} onClick={() => openShare()}><Icon name="share" />{mode === "voices" ? "分享这句话" : "分享愿望"}</button>
					</div>
					{mode === "wishes" && <>
						<button className={styles.notifyLink} onClick={() => setDialog("notify")}><Icon name="bell" />{notified.has(current.id) ? "已选择接收提醒（演示）" : "有新进展时，告诉我"}<Icon name="arrow" /></button>
						{current.echo ? <button className={styles.echo} onClick={() => setDialog("echo")}><span className={styles.echoBadge}>有回响了</span><strong>{current.echo}</strong><span>一个愿望，正在成为一次相聚。<Icon name="arrow" /></span></button> : <div className={styles.waitingWish}><span>愿望正在生长</span><p>让更多人看见，也许下一次相聚就从这里开始。</p></div>}
					</>}
					<div className={styles.pagination}><button onClick={() => navigate(-1)} aria-label="上一条"><Icon name="back" /><span>上一{mode === "voices" ? "句" : "个"}</span></button><span>{String(Math.max(0, currentIndex) + 1).padStart(2, "0")}<i>/</i>{String(available.length).padStart(2, "0")}</span><button onClick={() => navigate(1)} aria-label="下一条"><span>下一{mode === "voices" ? "句" : "个"}</span><Icon name="arrow" /></button></div>
					{mode === "voices" ? <p className={styles.disclosure}>来自当年的报名回答，经本人选择并授权公开。<br />每一次共鸣，都让这些声音走得更远。</p> : <button className={`${styles.primary} ${styles.writeMobile}`} onClick={() => { setDraftCity(city); setDialog("write"); }}><Icon name="write" />写下我的愿望</button>}
					{current.mine && <button className={styles.withdraw} onClick={() => { setWishes(wishes.filter(w => w.id !== current.id)); setCurrentId(WISHES[0].id); setCity(WISHES[0].city); setToast("愿望已从公开地图撤回。"); }}>撤回我的愿望</button>}
					<footer className={styles.readerFooter}><button onClick={() => { setRecoveryNext(false); setDialog("recover"); }}>找回你的那一张 <Icon name="arrow" /></button><button onClick={() => switchMode(mode === "voices" ? "wishes" : "voices")}>{mode === "voices" ? "去许愿树，写下未来" : "去金句墙，听听当年的声音"}<Icon name="arrow" /></button></footer>
				</section>
			</main>
			{isIntro && <div className={styles.introTrack}>{STAGES.map((s, i) => <button key={s.name} aria-pressed={stage === i} onClick={() => { setStoryboard(true); inspectFrame(i); }}><span>0{i + 1}</span>{s.name}</button>)}<div className={styles.trackFill} style={{ transform: `scaleX(${progress})` }} /></div>}
		</div></div>

		<div className={styles.demoBar} aria-label="原型体验控制"><span className={styles.demoLabel}><i />交互原型 <small>· 合成数据</small></span><button onClick={replay}>首次进入</button><button onClick={() => { setStoryboard(!storyboard); if (!storyboard) inspectFrame(0); else finishIntro(); }} aria-pressed={storyboard}>四幕分镜</button><button onClick={() => { finishIntro(); setToast("分享直达：无需播放片头，直接读到这句话。"); }}>分享直达</button><button onClick={() => setPhone(!phone)} aria-pressed={phone} className={styles.previewButton}><Icon name="phone" />{phone ? "桌面预览" : "手机预览"}</button>{storyboard && <div className={styles.framePicker}>{STAGES.map((s, i) => <button key={i} onClick={() => inspectFrame(i)} aria-pressed={Math.abs(progress - s.at) < 0.01}>0{i + 1} {s.name}</button>)}</div>}</div>
		<div className={styles.toast} role="status" aria-live="polite" data-visible={!!toast}>{toast}</div>

		{dialog && <Modal title={{ share: "分享", write: "写下愿望", recover: "找回那一张", echo: "愿望的回响", notify: "接收回响", private: "私密愿望" }[dialog]} onClose={() => setDialog(null)}>
			{dialog === "share" && <><p className={styles.eyebrow}>{shareAll ? (mode === "voices" ? "金句墙 / VOICES" : "许愿树 / WISHES") : `${city} · ${current.author}`}</p><h2>{shareAll ? "把这片山河，分享给一个朋友。" : current.text}</h2><p>{current.mine ? "新写的愿望只存在本次体验中，复制的是许愿树入口。" : "朋友打开链接，会直接看到内容。"}</p><label className={styles.field}>分享链接<input readOnly value={shareUrl} onFocus={e => e.target.select()} /></label><button className={styles.primary} onClick={async () => { try { await navigator.clipboard.writeText(shareUrl); setCopied(true); } catch { setToast("请选中上方链接复制。"); } }}><Icon name={copied ? "check" : "share"} />{copied ? "链接已复制" : "复制链接"}</button><small className={styles.demoNote}>本地原型链接，仅在能访问此开发服务的设备上打开。</small></>}
			{dialog === "write" && <form onSubmit={submitWish}><h2>下一次，<br />你希望我们一起做什么？</h2><label className={styles.field}>我的愿望<textarea required maxLength={500} rows={3} value={draft} onChange={e => setDraft(e.target.value)} placeholder="比如，和女生一起做一个小作品…" /><small>{draft.length} / 500</small></label><label className={styles.field}>愿望发生的城市<select value={draftCity} onChange={e => setDraftCity(e.target.value as City)}>{CITIES.map(c => <option key={c.name}>{c.name}</option>)}</select></label><fieldset><legend>谁可以看见</legend><label><input type="radio" name="visibility" value="public" checked={visibility === "public"} onChange={e => setVisibility(e.target.value)} />公开</label><label><input type="radio" name="visibility" value="private" checked={visibility === "private"} onChange={e => setVisibility(e.target.value)} />私密</label></fieldset><p className={styles.help}>{visibility === "public" ? "所有人可见，包括未参加过活动的人。" : "仅自己可见，不会挂到公开许愿树。"}</p>{visibility === "public" && <fieldset><legend>如何署名</legend><label><input type="radio" name="identity" checked={identity === "anonymous"} onChange={() => setIdentity("anonymous")} />匿名 · 林**</label><label><input type="radio" name="identity" checked={identity === "display"} onChange={() => setIdentity("display")} />展示名 · 小林</label></fieldset>}<button className={styles.primary} type="submit"><Icon name="write" />{visibility === "public" ? "挂上许愿树" : "留给自己"}</button><small className={styles.demoNote}>原型演示：模拟已认领校友，刷新后本次填写的内容清空。</small></form>}
			{dialog === "private" && <><p className={styles.eyebrow}>只留给自己</p><h2>{draft}</h2><p>这份愿望不会出现在公开地图上。</p><button className={styles.primary} onClick={() => { setDialog(null); setDraft(""); }}>回到许愿树</button><small className={styles.demoNote}>这是私密状态演示，未写入任何账户或数据库。</small></>}
			{dialog === "echo" && <><p className={styles.echoBadge}>愿望有了回响</p><h2>{current.echo}</h2><p>从零做出你的第一个网页，和一群相信可能的人一起。</p><blockquote className={styles.echoOriginal}>{current.text}</blockquote><p>你的期待，正在成为一次新的相聚。</p><button className={styles.primary} onClick={() => setToast("报名入口示意：正式版本会进入真实活动详情。本次未提交报名。")}>查看活动与报名 <Icon name="arrow" /></button><small className={styles.demoNote}>合成活动示例。加入期待不等于报名，原型不会创建真实活动。</small></>}
			{dialog === "notify" && <><p className={styles.eyebrow}>让期待有一个回音</p><h2>有新进展时，<br />告诉你。</h2><p>正式版本中，登录并授权后可以接收这份愿望的活动或进展提醒。</p><button className={styles.primary} onClick={() => { setNotified(prev => new Set([...prev, current.id])); setDialog(null); setToast("提醒已选择（演示）。原型不会发送真实通知。"); }}>体验接收提醒</button><button className={styles.secondary} onClick={() => setDialog(null)}>暂时不用</button><small className={styles.demoNote}>暂不接收，也可以继续阅读、期待和分享。</small></>}
			{dialog === "recover" && <><p className={styles.eyebrow}>2012 — 2018 / 你也写过吗</p><h2>{recoveryNext ? "那年的你，值得被找回。" : "找回你的那一张。"}</h2>{recoveryNext ? <><p>正式版本会通过报名信息核验身份，再带你回到自己的时光胶囊。</p><button className={styles.primary} onClick={() => setDialog(null)}>继续听听她们的声音</button><small className={styles.demoNote}>本次仅演示入口，没有查询名册或提交个人信息。</small></> : <><p>如果你参加过 Rails Girls 或 Girls Coding Day，也许这里有你当年的声音。</p><label className={styles.field}>当年报名的城市<select defaultValue={city}>{CITIES.map(c => <option key={c.name}>{c.name}</option>)}</select></label><button className={styles.primary} onClick={() => setRecoveryNext(true)}>看看如何找回 <Icon name="arrow" /></button></>}</>}
		</Modal>}
	</div>;
}
