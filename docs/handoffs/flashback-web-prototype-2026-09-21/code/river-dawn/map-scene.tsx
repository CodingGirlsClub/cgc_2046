"use client";

import { useId } from "react";
import terrain from "./terrain.png";
import { CITIES, type City, type Mode } from "./data";
import { CITY_POINTS, CONNECTIONS, ISLANDS, LAND, RIVERS } from "./geography";
import styles from "./river.module.css";

export default function MapScene({ city, mode, progress, onCity, pulse, selectedWish, onRead }: {
	city: City; mode: Mode; progress: number; onCity: (city: City) => void; pulse: number; selectedWish?: string; onRead: () => void;
}) {
	const uid = useId().replace(/:/g, "");
	const complete = progress >= 1;
	const [sx, sy] = CITY_POINTS["成都"];
	const east = city === "杭州" ? "杭州" : "上海";
	const pins = CITIES.filter(c => c.name !== "杭州" && c.name !== "上海").map(c => c.name).concat(east);
	const daylight = Math.max(0, (progress - 0.36) / 0.64);
	return <div className={styles.mapPlot} data-testid="map" data-city={city} data-progress={progress.toFixed(2)}>
		<svg viewBox="0 0 1000 720" className={styles.mapSvg} aria-label="中国城市地图，青绿山水与金色连接" role="img">
			<defs>
				<clipPath id={`${uid}-land`}><path d={LAND} /></clipPath>
				<filter id={`${uid}-soft`} x="-100%" y="-100%" width="300%" height="300%"><feGaussianBlur stdDeviation="16" /></filter>
				<filter id={`${uid}-glow`} x="-100%" y="-100%" width="300%" height="300%"><feGaussianBlur stdDeviation="4" /></filter>
				<mask id={`${uid}-dawn`} maskUnits="userSpaceOnUse" x="0" y="0" width="1000" height="720">
					<rect width="1000" height="720" fill={complete ? "white" : "black"} />
					{!complete && <g filter={`url(#${uid}-soft)`}>
						<circle cx={sx} cy={sy} r={daylight * daylight * 1050} fill="white" />
						{CONNECTIONS.map((c, i) => <path key={i} d={c.d} fill="none" stroke="white" strokeLinecap="round"
							strokeWidth={Math.max(0, (progress - 0.28 - c.start) * 410)} pathLength="1"
							strokeDasharray="1" strokeDashoffset={1 - Math.min(1, Math.max(0, (progress - 0.18 - c.start) * 3))} />)}
					</g>}
				</mask>
			</defs>
			<g opacity={1 - daylight}>
				<path d={LAND} fill="#172a2a" stroke="#81978b" strokeWidth="0.8" />
				<image href={terrain.src} width="1000" height="720" preserveAspectRatio="xMidYMid slice" clipPath={`url(#${uid}-land)`} opacity="0.12" />
			</g>
			<g mask={`url(#${uid}-dawn)`}>
				<path d={LAND} fill="#dbe1cf" stroke="#7d9280" strokeWidth="1.1" />
				<image href={terrain.src} width="1000" height="720" preserveAspectRatio="xMidYMid slice" clipPath={`url(#${uid}-land)`} />
				<path d={LAND} fill="none" stroke="#617e6b" strokeWidth="0.65" opacity="0.32" />
				<g clipPath={`url(#${uid}-land)`} fill="none" stroke="#609789" strokeWidth="1.8" opacity="0.72">{RIVERS.map((d, i) => <path key={i} d={d} />)}</g>
				<rect x="817" y="498" width="147" height="179" rx="2" fill="#f7f4ea" stroke="#839581" strokeWidth="0.8" />
				<path d={ISLANDS} fill="#9eaf93" stroke="#6c897b" strokeWidth="0.9" />
				<text x="890" y="698" textAnchor="middle" fill="#526b60" fontSize="15" fontFamily="serif">南海诸岛</text>
			</g>
			<g fill="none" strokeLinecap="round">
				{CONNECTIONS.map((c, i) => {
					const amount = Math.min(1, Math.max(0, (progress - 0.08 - c.start) * 3));
					return <g key={i}>
						<path d={c.d} stroke="#e3b65b" strokeWidth="10" opacity={complete ? 0.25 : 0.55} filter={`url(#${uid}-glow)`} pathLength="1" strokeDasharray="1" strokeDashoffset={1 - amount} />
						<path d={c.d} stroke={complete ? "#b98b3f" : "#e9c16e"} strokeWidth="2.1" pathLength="1" strokeDasharray="1" strokeDashoffset={1 - amount} />
						<path d={c.d} stroke="#fff2c9" strokeWidth="0.65" opacity="0.9" pathLength="1" strokeDasharray="1" strokeDashoffset={1 - amount} />
					</g>;
				})}
			</g>
			{!complete && <g><circle cx={sx} cy={sy} r="15" fill="#f6d28b" opacity="0.3" filter={`url(#${uid}-glow)`} /><circle cx={sx} cy={sy} r="4" fill="#ffecbe" />
				<text x={sx - 20} y={sy + 37} textAnchor="end" fill="#e6dbc0" fontSize="15">起点示意</text></g>}
		</svg>
		{complete && mode === "wishes" && selectedWish && <button className={styles.wishSlip} style={{ left: `${CITY_POINTS[city][0] / 10}%`, top: `${CITY_POINTS[city][1] / 7.2}%` }} onClick={onRead} aria-label="阅读选中的愿望"><span>{selectedWish}</span></button>}
		{pins.map((name, i) => {
			const [x, y] = CITY_POINTS[name];
			const active = name === city;
			const visible = complete || progress > 0.12 + i * 0.07;
			return <button key={name} className={`${styles.mapPin} ${active ? styles.selectedPin : ""} ${!complete ? styles.nightPin : ""}`}
				style={{ left: `${x / 10}%`, top: `${y / 7.2}%`, opacity: visible ? 1 : 0.25 }}
				onClick={() => onCity(name === "上海" && city === "上海" ? "杭州" : name === "杭州" ? "上海" : name)}
				aria-label={name === east ? "浏览上海或杭州，点击切换" : `浏览${name}`} aria-pressed={active}>
				<span className={styles.pinDot} />{active && pulse > 0 && <span key={pulse} className={styles.pinPulse} />}
				<span className={styles.pinLabel}>{name}{name === east && <small> / {name === "上海" ? "杭州" : "上海"}</small>}</span>
			</button>;
		})}
	</div>;
}
