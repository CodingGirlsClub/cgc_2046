// Builds the code-native map render source. Capture it at 700x504 in a browser
// to regenerate src/assets/flashback/voices-map.png. Geography/terrain source:
// web/app/[locale]/flashback/voices; gold connections are illustrative, not rivers.
import { readFileSync, writeFileSync } from 'node:fs'
const source = new URL('../../web/app/[locale]/flashback/voices/', import.meta.url)
const read = name => JSON.parse(readFileSync(new URL(name, source)))
const project = ([lng, lat]) => [45 + (lng - 73) * 14, 42 + (54 - lat) * 17]
const inset = ([lng, lat]) => [822 + (lng - 107) * 7.5, 503 + (25 - lat) * 7.5]
const path = (rings, projection) => rings.map(ring => ring.map((p, i) => `${i ? 'L' : 'M'}${projection(p).map(v => v.toFixed(2))}`).join('') + 'Z').join('')
const land = [], sea = []
for (const f of read('china-geo.json').features) {
  const polygons = f.geometry.type === 'Polygon' ? [f.geometry.coordinates] : f.geometry.coordinates
  for (const rings of polygons) {
    const southern = f.properties.adcode === '100000_JD' || Math.max(...rings[0].map(p => p[1])) < 18
    ;(southern ? sea : land).push(path(rings, southern ? inset : project))
  }
}
const rivers = read('rivers.json').features.flatMap(f => (f.geometry.type === 'LineString' ? [f.geometry.coordinates] : f.geometry.coordinates).map(line => line.map((p,i) => `${i?'L':'M'}${project(p)}`).join('')))
const texture = readFileSync(new URL('terrain.png', source)).toString('base64')
const points = [[116.4,39.9],[121.5,31.2],[120.2,30.3],[104.1,30.7],[113.3,23.1]].map(project)
const connections = [[0,1],[1,2],[2,4],[4,3],[3,0],[3,1]].map(([a,b]) => { const p=points[a],q=points[b]; return `M${p} C${p[0]-70},${(p[1]+q[1])/2} ${q[0]+50},${(p[1]+q[1])/2} ${q}` })
const html = `<!doctype html><meta charset="utf-8"><style>html,body{margin:0;width:700px;height:504px;overflow:hidden;background:#efefe2}svg{width:700px;height:504px}</style><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 720"><defs><clipPath id="land"><path d="${land.join('')}"/></clipPath><filter id="glow"><feGaussianBlur stdDeviation="5"/></filter></defs><path d="${land.join('')}" fill="#d8ddcb"/><image href="data:image/png;base64,${texture}" width="1000" height="720" preserveAspectRatio="xMidYMid slice" clip-path="url(#land)"/><path d="${land.join('')}" fill="none" stroke="#718675" opacity=".55"/><g fill="none" stroke="#64988d" stroke-width="2.5" opacity=".7">${rivers.map(d=>`<path d="${d}"/>`).join('')}</g><rect x="817" y="498" width="147" height="179" fill="#f6f4e9" stroke="#9aa592"/><path d="${sea.join('')}" fill="#829c83"/>${connections.map(d=>`<path d="${d}" fill="none" stroke="#edb64e" stroke-width="11" filter="url(#glow)" opacity=".65"/><path d="${d}" fill="none" stroke="#d5a03e" stroke-width="3"/><path d="${d}" fill="none" stroke="#fff5cb" stroke-width="1.5"/>`).join('')}</svg>`
const output = process.argv[2] || '/tmp/cgc-voices-map.html'
writeFileSync(output,html)
console.log(output)
