import geo from "./china-geo.json";
import riverData from "./rivers.json";

/**
 * 山河地图地理层（R2/R3/R4）：统一投影——多边形、城市点位、连接路径共用
 * 同一 `project`，保证「地图上的城市」与「阅读区内容」始终指向同一地点。
 *
 * 合规（KTD6）：china-geo.json 为 DataV GeoAtlas 100000_full（35 feature，
 * 含 `100000_JD` 南海诸岛插图——**必须保留**，删除即地图合规事故）；
 * rivers.json 为 Natural Earth 长江/黄河节选（青绿河道层，与金色连接分层——
 * 金线是「声音与愿望的连接」示意，不是真实河道，R4）。
 */

export type CityPoint = [number, number];

type Point = number[];
type Shape = { geometry: { type: string; coordinates: unknown }; properties: { adcode: number | string } };

// One deterministic projection for polygons, city positions and connection paths.
export function project(p: Point): CityPoint {
	return [45 + (p[0] - 73) * 14, 42 + (54 - p[1]) * 17];
}

function inset(p: Point): CityPoint {
	return [822 + (p[0] - 107) * 7.5, 503 + (25 - p[1]) * 7.5];
}

function ringsToPath(rings: Point[][], projection: typeof project) {
	return rings
		.map(
			(ring) =>
				ring.map((p, i) => `${i ? "L" : "M"}${projection(p).map((n) => n.toFixed(2)).join(",")}`).join("") +
				"Z",
		)
		.join("");
}

const main: string[] = [];
const sea: string[] = [];
for (const feature of geo.features as Shape[]) {
	const polygons = (
		feature.geometry.type === "Polygon" ? [feature.geometry.coordinates] : feature.geometry.coordinates
	) as Point[][][];
	for (const rings of polygons) {
		const southern = feature.properties.adcode === "100000_JD" || Math.max(...rings[0].map((p) => p[1])) < 18;
		(southern ? sea : main).push(ringsToPath(rings, southern ? inset : project));
	}
}

export const LAND = main.join("");
export const ISLANDS = sea.join("");

export const RIVERS = riverData.features.flatMap((feature) => {
	const lines = (
		feature.geometry.type === "LineString" ? [feature.geometry.coordinates] : feature.geometry.coordinates
	) as Point[][];
	return lines.map(
		(line) => line.map((point, index) => `${index ? "L" : "M"}${project(point).map((n) => n.toFixed(2)).join(",")}`).join(""),
	);
});

/** 城市经纬度 → 投影点位（城市清单由页面按数据动态给出，此处只做投影） */
export function cityPoint(lng: number, lat: number): CityPoint {
	return project([lng, lat]);
}

function curve(a: CityPoint, b: CityPoint, bend = 24) {
	return `M${a[0]},${a[1]} C${a[0] + bend},${(a[1] + b[1]) / 2} ${b[0] - bend},${(a[1] + b[1]) / 2} ${b[0]},${b[1]}`;
}

/**
 * 金色连接（R4 示意网络，非史实）：开场动画的光路沿这些路径传播。
 * 城市集合动态（数据驱动），连接在渲染时按城市点位生成——见 map-scene。
 */
export function connectionPath(a: CityPoint, b: CityPoint, index: number) {
	return { d: curve(a, b, index % 2 ? -70 : 60), start: index * 0.055 };
}
