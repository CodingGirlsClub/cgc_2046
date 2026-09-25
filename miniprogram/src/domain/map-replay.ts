import { voiceMapPoint, type VoiceCity } from './flashback-voices.ts'

/** Connections are a visual metaphor, not historical travel or real river routes. */
export const MAP_REPLAY_MS = 4200
const ORIGIN_MS = 200
const PROPAGATION_MS = MAP_REPLAY_MS - ORIGIN_MS - 600
const clamp = (n: number, low: number, high: number) => Math.max(low, Math.min(high, n))
const radians = (n: number) => n * Math.PI / 180
function distanceKm(a: VoiceCity, b: VoiceCity): number {
  const [lng1, lat1] = a.lngLat.map(radians), [lng2, lat2] = b.lngLat.map(radians)
  const h = Math.sin((lat2-lat1)/2)**2 + Math.cos(lat1)*Math.cos(lat2)*Math.sin((lng2-lng1)/2)**2
  return 12742 * Math.asin(Math.sqrt(clamp(h, 0, 1)))
}
export function buildMapReplay(input: VoiceCity[], selected: string | null) {
  const sorted = input.filter(c => c.name && voiceMapPoint(c)).slice().sort((a,b) =>
    a.name < b.name ? -1 : a.name > b.name ? 1 : a.lngLat[0]-b.lngLat[0] || a.lngLat[1]-b.lngLat[1])
  const nodes = sorted.filter((c,i) => !i || c.name !== sorted[i-1].name)
    .map(c => ({ ...c, ...voiceMapPoint(c)!, arrival: ORIGIN_MS }))
  const originIndex = Math.max(0, nodes.findIndex(c => c.name === selected))
  const connected = new Set<number>()
  const best = nodes.map(() => Infinity)
  const parent = nodes.map(() => -1)
  const rawArrival = nodes.map(() => 0)
  const branches: { from: number; to: number; start: number; end: number }[] = []
  if (nodes.length) best[originIndex] = 0
  // Prim, O(n²). Canonical name order makes equal-distance choices repeatable.
  while (connected.size < nodes.length) {
    let next = -1
    for (let i=0; i<nodes.length; i++) if (!connected.has(i) && (next<0 || best[i]<best[next])) next=i
    connected.add(next)
    const from = parent[next]
    if (from >= 0) {
      const duration = clamp(250 + best[next] * .6, 250, 700)
      rawArrival[next] = rawArrival[from] + duration
      branches.push({ from, to: next, start: rawArrival[from], end: rawArrival[next] })
    }
    for (let i=0; i<nodes.length; i++) if (!connected.has(i)) {
      const distance = distanceKm(nodes[next], nodes[i])
      if (distance < best[i]) { best[i] = distance; parent[i] = next }
    }
  }
  // Scale the longest root-to-leaf path, not each edge independently. Children
  // always depart at their parent's arrival, and separate branches run together.
  const scale = PROPAGATION_MS / Math.max(1, ...rawArrival)
  for (let i=0; i<nodes.length; i++) nodes[i].arrival = ORIGIN_MS + rawArrival[i]*scale
  const edges = branches.map(edge => ({ from: nodes[edge.from].name, to: nodes[edge.to].name,
    start: ORIGIN_MS + edge.start*scale, end: ORIGIN_MS + edge.end*scale }))
  const segments = branches.flatMap((branch, route) => {
    const a = nodes[branch.from], b = nodes[branch.to], edge = edges[route]
    const from = [a.left*10, a.top*7.2], to = [b.left*10, b.top*7.2]
    const dx = to[0]-from[0], dy = to[1]-from[1], length = Math.hypot(dx,dy)
    const bend = Math.min(45, length*.12) * (route%2 ? -1 : 1)
    const normal = [-dy/Math.max(1,length)*bend, dx/Math.max(1,length)*bend]
    const control = (t: number) => [clamp(from[0]+dx*t+normal[0],0,1000), clamp(from[1]+dy*t+normal[1],0,720)]
    const first = control(1/3), second = control(2/3)
    const point = (t: number) => [0,1].map(k => (1-t)**3*from[k]+3*(1-t)**2*t*first[k]+3*(1-t)*t*t*second[k]+t**3*to[k])
    const steps = clamp(Math.ceil(length/20),4,20)
    return Array.from({ length: steps }, (_, i) => {
      const p=point(i/steps), q=point((i+1)/steps)
      return { left:p[0]/10, top:p[1]/7.2, width:Math.hypot(q[0]-p[0],q[1]-p[1])*.75+1,
        angle:Math.atan2(q[1]-p[1],q[0]-p[0])*180/Math.PI,
        delay:edge.start+(edge.end-edge.start)*i/steps, duration:(edge.end-edge.start)/steps }
    })
  })
  return { origin: nodes[originIndex]?.name ?? null, cities: nodes, edges, segments }
}
