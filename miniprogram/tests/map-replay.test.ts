import test from 'node:test'
import assert from 'node:assert/strict'
import { MAP_REPLAY_MS, buildMapReplay } from '../src/domain/map-replay.ts'
const cities = [
  { name: 'A', lngLat: [100, 30] }, { name: 'B', lngLat: [101, 30] },
  { name: 'C', lngLat: [102, 30] }, { name: 'D', lngLat: [101, 31] }
]
test('从选中城市生长，接到最近的已连接城市，形成分支而不是固定路线', () => {
  const plan = buildMapReplay(cities, 'A')
  assert.equal(plan.origin, 'A')
  assert.deepEqual(plan.edges.map(e => [e.from, e.to]), [['A','B'], ['B','C'], ['B','D']])
  const arrivals = new Map(plan.cities.map(c => [c.name, c.arrival]))
  for (const edge of plan.edges) {
    assert.equal(edge.start, arrivals.get(edge.from))
    assert.equal(edge.end, arrivals.get(edge.to))
    assert.ok(edge.end > edge.start)
    assert.ok(edge.end <= MAP_REPLAY_MS - 600)
  }
})
test('同样数据和起点得到同一路线，输入排序不影响；换起点重新定向', () => {
  assert.deepEqual(buildMapReplay(cities, 'A'), buildMapReplay([...cities].reverse(), 'A'))
  const other = buildMapReplay(cities, 'C')
  assert.equal(other.origin, 'C')
  assert.equal(other.edges[0].from, 'C')
})
test('30 城生成 29 条连接，无孤立点或循环；光路在画布内且完整到达', () => {
  const rows = Array.from({ length: 30 }, (_, i) => ({ name: `城市${i}`, lngLat: [100+i%6*2, 25+Math.floor(i/6)*2] }))
  const plan = buildMapReplay(rows, '城市0')
  assert.equal(plan.edges.length, 29)
  const connected = new Set([plan.origin])
  for (const e of plan.edges) {
    assert.ok(connected.has(e.from)); assert.ok(!connected.has(e.to)); connected.add(e.to)
  }
  assert.equal(connected.size, 30)
  assert.ok(plan.segments.length < 400)
  for (const s of plan.segments) {
    assert.ok(s.left >= 0 && s.left <= 100 && s.top >= 0 && s.top <= 100)
    assert.ok(s.width > 0 && Number.isFinite(s.angle))
    assert.ok(s.delay + s.duration <= MAP_REPLAY_MS - 600 + .001)
  }
})
test('空列表、单城市、未知起点和无效坐标不制造虚构城市或固定路线', () => {
  assert.equal(buildMapReplay([], null).origin, null)
  assert.deepEqual(buildMapReplay([], null).segments, [])
  assert.equal(buildMapReplay(cities, '不存在').origin, 'A')
  const one = buildMapReplay([cities[0], cities[0], {name:'无效',lngLat:[NaN,0]}, {name:'界外',lngLat:[0,0]}], 'A')
  assert.equal(one.cities.length, 1)
  assert.deepEqual(one.edges, [])
})
