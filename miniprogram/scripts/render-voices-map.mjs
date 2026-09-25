// Run with: node scripts/render-voices-map.mjs
// Builds the code-native map render source. Capture it at 700x504 in a browser
// to regenerate src/assets/flashback/mountain-map.png. Geography/terrain source:
// web/app/[locale]/flashback/voices. Gold connections are rendered at runtime.
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
const html = `<!doctype html><meta charset="utf-8"><style>html,body{margin:0;width:700px;height:504px;overflow:hidden;background:#efefe2}svg{width:700px;height:504px}</style><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 720"><defs><clipPath id="land"><path d="${land.join('')}"/></clipPath></defs><path d="${land.join('')}" fill="#d8ddcb"/><image href="data:image/png;base64,${texture}" width="1000" height="720" preserveAspectRatio="xMidYMid slice" clip-path="url(#land)"/><path d="${land.join('')}" fill="none" stroke="#718675" opacity=".55"/><g fill="none" stroke="#64988d" stroke-width="2.5" opacity=".7">${rivers.map(d=>`<path d="${d}"/>`).join('')}</g><rect x="817" y="498" width="147" height="179" fill="#f6f4e9" stroke="#9aa592"/><path d="${sea.join('')}" fill="#829c83"/></svg>`
const output = process.argv[2] || '/tmp/cgc-mountain-map.html'
writeFileSync(output,html)
console.log(output)
