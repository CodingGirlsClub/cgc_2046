"use client";

import { useEffect, useId, useRef, useState, type CSSProperties } from "react";
import { useTranslations } from "next-intl";
import terrain from "./terrain.png";
import { ISLANDS, LAND, RIVERS, cityPoint, connectionPath } from "./geography";
import styles from "./voices.module.css";

export type CitySpec = { name: string; lng: number; lat: number };

/**
 * 山河地图（R2/R3/R4）：青绿山水底（terrain 位图按真实多边形裁切）+
 * 金色连接（声音的传播示意，非真实河道）+ 城市光点。
 *
 * 开场四幕由 `progress`（0..1）驱动：源起（起点亮）→ 流向远方（金线生长）
 * → 山河渐醒（日光从已点亮区域扩散）→ 天光满树（全白昼）。遮罩在 SVG
 * mask 里做，progress 按墙钟推进（弱机掉帧不拖长）。
 */
export default function MapScene({
	cities,
	city,
	progress,
	onCity,
	pulse,
}: {
	cities: CitySpec[];
	city: string;
	progress: number;
	onCity: (city: string) => void;
	pulse: number;
}) {
	const t = useTranslations("flashback.voices");
	const uid = useId().replace(/:/g, "");
	const plot = useRef<HTMLDivElement>(null);
	const [width, setWidth] = useState(1000);
	useEffect(() => {
		const observer = new ResizeObserver(([entry]) => setWidth(entry.contentRect.width));
		if (plot.current) observer.observe(plot.current);
		return () => observer.disconnect();
	}, []);
	const complete = progress >= 1;
	const points = cities.map((c) => ({ ...c, point: cityPoint(c.lng, c.lat) }));
	// 起点示意：第一座城（数据序）作为光路源头（R4：传播起点与顺序为示意）
	const origin = points[0]?.point ?? [500, 360];
	const connections = points.slice(1).map((c, i) => ({
		...connectionPath(origin, c.point, i),
		to: c.name,
	}));
	// Layout labels in screen pixels; geographic anchors never move.
	const labels: { x: number; y: number; width: number }[] = [];
	const placed = new Map<string, { dx: number; dy: number; width: number }>();
	[...points].sort((a, b) => a.point[1] - b.point[1]).forEach((c) => {
		const x = c.point[0] * width / 1000;
		const y = c.point[1] * width / 1000;
		const labelWidth = Math.max(44, c.name.length * 14 + 16);
		const candidates = [
			[14 + labelWidth / 2, 0], [-14 - labelWidth / 2, 0],
			[14 + labelWidth / 2, -44], [14 + labelWidth / 2, 44],
			[-14 - labelWidth / 2, -44], [-14 - labelWidth / 2, 44],
		];
		let position = { x, y, width: labelWidth };
		for (let row = 0; row < points.length + 1; row++) {
			let found = false;
			for (const [dx, dy] of candidates) {
				const next = { x: Math.max(labelWidth / 2, Math.min(width - labelWidth / 2, x + dx)), y: y + dy + row * 48, width: labelWidth };
				if (labels.every(l => Math.abs(l.x - next.x) >= (l.width + labelWidth) / 2 + 4 || Math.abs(l.y - next.y) >= 44)) {
					position = next;
					found = true;
					break;
				}
			}
			if (found) break;
		}
		labels.push(position);
		placed.set(c.name, { dx: position.x - x, dy: position.y - y, width: labelWidth });
	});
	const daylight = Math.max(0, (progress - 0.36) / 0.64);

	return (
		<div ref={plot} className={styles.mapPlot} data-testid="map" data-city={city} data-progress={progress.toFixed(2)}>
			<svg viewBox="0 0 1000 720" className={styles.mapSvg} aria-label={t("mapAria")} role="img">
				<defs>
					<clipPath id={`${uid}-land`}>
						<path d={LAND} />
					</clipPath>
					<filter id={`${uid}-soft`} x="-100%" y="-100%" width="300%" height="300%">
						<feGaussianBlur stdDeviation="16" />
					</filter>
					<filter id={`${uid}-glow`} x="-100%" y="-100%" width="300%" height="300%">
						<feGaussianBlur stdDeviation="4" />
					</filter>
					<mask id={`${uid}-dawn`} maskUnits="userSpaceOnUse" x="0" y="0" width="1000" height="720">
						<rect width="1000" height="720" fill={complete ? "white" : "black"} />
						{!complete && (
							<g filter={`url(#${uid}-soft)`}>
								<circle cx={origin[0]} cy={origin[1]} r={daylight * daylight * 1050} fill="white" />
								{connections.map((c, i) => (
									<path
										key={i}
										d={c.d}
										fill="none"
										stroke="white"
										strokeLinecap="round"
										strokeWidth={Math.max(0, (progress - 0.28 - c.start) * 410)}
										pathLength="1"
										strokeDasharray="1"
										strokeDashoffset={1 - Math.min(1, Math.max(0, (progress - 0.18 - c.start) * 3))}
									/>
								))}
							</g>
						)}
					</mask>
				</defs>
				<g opacity={1 - daylight}>
					<path d={LAND} fill="#172a2a" stroke="#81978b" strokeWidth="0.8" />
					<image
						href={terrain.src}
						width="1000"
						height="720"
						preserveAspectRatio="xMidYMid slice"
						clipPath={`url(#${uid}-land)`}
						opacity="0.12"
					/>
				</g>
				<g mask={`url(#${uid}-dawn)`}>
					<path d={LAND} fill="#dbe1cf" stroke="#7d9280" strokeWidth="1.1" />
					<image
						href={terrain.src}
						width="1000"
						height="720"
						preserveAspectRatio="xMidYMid slice"
						clipPath={`url(#${uid}-land)`}
					/>
					<path d={LAND} fill="none" stroke="#617e6b" strokeWidth="0.65" opacity="0.32" />
					<g clipPath={`url(#${uid}-land)`} fill="none" stroke="#4f8a7c" strokeWidth="2" opacity="0.88">
						{RIVERS.map((d, i) => (
							<path key={i} d={d} />
						))}
					</g>
					<rect x="817" y="498" width="147" height="179" rx="2" fill="#f7f4ea" stroke="#839581" strokeWidth="0.8" />
					<path d={ISLANDS} fill="#9eaf93" stroke="#6c897b" strokeWidth="0.9" />
					<text x="890" y="698" textAnchor="middle" fill="#526b60" fontSize="15" fontFamily="serif">
						{t("islandsLabel")}
					</text>
				</g>
				<g fill="none" strokeLinecap="round">
					{connections.map((c, i) => {
						const amount = Math.min(1, Math.max(0, (progress - 0.08 - c.start) * 3));
						return (
							<g key={i}>
								<path
									d={c.d}
									stroke="#efb83f"
									strokeWidth="13"
									opacity={complete ? 0.68 : 0.75}
									filter={`url(#${uid}-glow)`}
									pathLength="1"
									strokeDasharray="1"
									strokeDashoffset={1 - amount}
								/>
								<path
									d={c.d}
									stroke="#d7a23e"
									strokeWidth="4"
									pathLength="1"
									strokeDasharray="1"
									strokeDashoffset={1 - amount}
								/>
								<path
									d={c.d}
									stroke="#fff6cf"
									strokeWidth="1.6"
									opacity="1"
									pathLength="1"
									strokeDasharray="1"
									strokeDashoffset={1 - amount}
								/>
							</g>
						);
					})}
				</g>
				{!complete && (
					<g>
						<circle cx={origin[0]} cy={origin[1]} r="15" fill="#f6d28b" opacity="0.3" filter={`url(#${uid}-glow)`} />
						<circle cx={origin[0]} cy={origin[1]} r="4" fill="#ffecbe" />
						<text x={origin[0] - 20} y={origin[1] + 37} textAnchor="end" fill="#e6dbc0" fontSize="15">
							{t("originNote")}
						</text>
					</g>
				)}
			</svg>
			{points.map((c, i) => {
				const active = c.name === city;
				const label = placed.get(c.name)!;
				const visible = complete || progress > 0.12 + i * 0.07;
				return (
					<button
						key={c.name}
						type="button"
						className={`${styles.mapPin} ${active ? styles.selectedPin : ""} ${!complete ? styles.nightPin : ""}`}
						style={{ left: `calc(${c.point[0] / 10}% + ${label.dx}px)`, top: `calc(${c.point[1] / 7.2}% + ${label.dy}px)`, opacity: visible ? 1 : 0.25, width: label.width, "--anchor-x": `${-label.dx}px`, "--anchor-y": `${-label.dy}px`, "--leader-length": `${Math.hypot(label.dx, label.dy)}px`, "--leader-angle": `${Math.atan2(label.dy, label.dx)}rad` } as CSSProperties}
						onClick={() => onCity(c.name)}
						aria-label={c.name}
						aria-pressed={active}
					>
						<span className={styles.pinLeader} aria-hidden="true" />
						<span className={styles.pinDot} aria-hidden="true" />
						{active && pulse > 0 && <span key={pulse} className={styles.pinPulse} />}
						<span className={styles.pinLabel}>{c.name}</span>
					</button>
				);
			})}
		</div>
	);
}
