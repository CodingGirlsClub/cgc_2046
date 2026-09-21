import geo from "./china-geo.json";
import riverData from "./rivers.json";
import { CITIES } from "./data";

type Point = number[];
type Shape = { geometry: { type: string; coordinates: unknown }; properties: { adcode: number | string } };
// One deterministic projection for polygons, city positions and connection paths.
export function project(p: Point): [number, number] {
	return [45 + (p[0] - 73) * 14, 42 + (54 - p[1]) * 17];
}
function inset(p: Point): [number, number] { return [822 + (p[0] - 107) * 7.5, 503 + (25 - p[1]) * 7.5]; }
function ringsToPath(rings: Point[][], projection: typeof project) {
	return rings.map(ring => ring.map((p, i) => `${i ? "L" : "M"}${projection(p).map(n => n.toFixed(2)).join(",")}`).join("") + "Z").join("");
}
const main: string[] = [];
const sea: string[] = [];
for (const feature of geo.features as Shape[]) {
	const polygons = (feature.geometry.type === "Polygon" ? [feature.geometry.coordinates] : feature.geometry.coordinates) as Point[][][];
	for (const rings of polygons) {
		const southern = feature.properties.adcode === "100000_JD" || Math.max(...rings[0].map(p => p[1])) < 18;
		(southern ? sea : main).push(ringsToPath(rings, southern ? inset : project));
	}
}
export const LAND = main.join("");
export const ISLANDS = sea.join("");
export const RIVERS = riverData.features.flatMap(feature => {
	const lines = (feature.geometry.type === "LineString" ? [feature.geometry.coordinates] : feature.geometry.coordinates) as Point[][];
	return lines.map(line => line.map((point, index) => `${index ? "L" : "M"}${project(point).map(n => n.toFixed(2)).join(",")}`).join(""));
});
export const CITY_POINTS = Object.fromEntries(CITIES.map(c => [c.name, project([c.lng, c.lat])])) as Record<string, [number, number]>;

function curve(a: [number, number], b: [number, number], bend = 24) {
	return `M${a[0]},${a[1]} C${a[0] + bend},${(a[1] + b[1]) / 2} ${b[0] - bend},${(a[1] + b[1]) / 2} ${b[0]},${b[1]}`;
}
// Propagation is an illustrative network, not an asserted history or a river.
const pairs = [["成都", "北京"], ["成都", "广州"], ["北京", "上海"], ["广州", "杭州"], ["上海", "杭州"]];
export const CONNECTIONS = pairs.map(([a, b], i) => ({ d: curve(CITY_POINTS[a], CITY_POINTS[b], i % 2 ? -70 : 60), from: a, to: b, start: i * 0.055 }));
