/** Public, synthetic voices for deterministic simulator acceptance only. */
const samples = [
  ['voice-beijing', '北京', '我想成为一个，敢说「我不会，但我可以学」的人。', '王** · 2014 · 北京', 32],
  ['voice-chengdu', '成都', '如果能和一群女生，一起做出自己的作品，那应该很酷。', '陈** · 2015 · 成都', 21],
  ['voice-hangzhou', '杭州', '希望下一次介绍自己，不只说我喜欢什么，也能说我做出了什么。', '周** · 2016 · 杭州', 47],
  ['voice-shanghai', '上海', '原来我不是一个人，在这条路上慢慢摸索。', '许** · 2014 · 上海', 18],
  ['voice-guangzhou', '广州', '我想把脑海里的小点子，变成别人也能用的东西。', '林** · 2017 · 广州', 26],
  ['voice-quiet', '北京', '学会的第一件事，是允许自己从零开始。', '赵** · 2018 · 北京', 0]
] as const
const votes = new Map<string, Set<string>>()
export function mockVoicesRequest(document: string, variables: object): unknown | undefined {
  const vars = variables as { quoteId?: string; city?: string | null; voterKey?: string; liked?: boolean }
  const mapped = samples.map(([quoteId, city, text, attribution, count]) => ({
    quoteId, city, text, attribution, year: Number(attribution.split(' · ')[1]),
    likeCount: count + (votes.get(quoteId)?.size ?? 0),
    likedByViewer: votes.get(quoteId)?.has(vars.voterKey ?? '') ?? false,
    level: 'anonymous', publicSlug: null
  }))
  if (document.includes('query FlashbackVoiceCities')) return { flashbackVoiceCities: [
    { name: '北京', pinyin: 'beijing', fullName: '北京市', lngLat: [116.407, 39.904] },
    { name: '成都', pinyin: 'chengdu', fullName: '成都市', lngLat: [104.066, 30.572] },
    { name: '广州', pinyin: 'guangzhou', fullName: '广州市', lngLat: [113.264, 23.129] },
    { name: '杭州', pinyin: 'hangzhou', fullName: '杭州市', lngLat: [120.155, 30.274] },
    { name: '上海', pinyin: 'shanghai', fullName: '上海市', lngLat: [121.474, 31.23] }
  ] }
  if (document.includes('query FlashbackVoices(')) {
    const storage = (globalThis as unknown as { wx?: { getStorageSync: (key: string) => unknown; removeStorageSync: (key: string) => void } }).wx
    if (storage?.getStorageSync('cgc.e2e.voices.fail-next-read')) {
      storage.removeStorageSync('cgc.e2e.voices.fail-next-read')
      return { errors: [{ message: '网络中断（验收场景），请重试' }] }
    }
    if (vars.city === '网络故障') return { errors: [{ message: '金句暂时无法加载，请重试' }] }
    return { flashbackPublicQuotes: mapped.slice(0, 5).filter(voice => !vars.city || voice.city === vars.city) }
  }
  if (document.includes('query FlashbackVoice(')) return { flashbackPublicQuote: mapped.find(voice => voice.quoteId === vars.quoteId) ?? null }
  if (document.includes('query FlashbackRandomVoices(')) return { flashbackRandomQuotes: [...mapped].reverse() }
  if (document.includes('mutation FlashbackLikeVoice(')) {
    const sample = samples.find(voice => voice[0] === vars.quoteId)
    if (!sample) return { errors: [{ message: '这句话已经收回', code: 'flashback_quote_not_found' }] }
    const voters = votes.get(sample[0]) ?? new Set<string>()
    if (vars.liked) voters.add(vars.voterKey ?? '')
    else voters.delete(vars.voterKey ?? '')
    votes.set(sample[0], voters)
    return { flashbackLikeQuote: { likeCount: sample[4] + voters.size } }
  }
  return undefined
}
