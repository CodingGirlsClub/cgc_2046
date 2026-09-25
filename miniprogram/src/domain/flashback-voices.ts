/** Public wall DTO: never derive it from a personal capsule or raw answers. */
export interface PublicVoice {
  quoteId: string
  text: string
  attribution: string
  city: string | null
  year: number | null
  likeCount: number
  likedByViewer: boolean
  level: string
  publicSlug: string | null
}
export interface VoiceCity { name: string; lngLat: number[] }
export function selectVoice(voices: PublicVoice[], id: string | null): PublicVoice | null {
  return id ? voices.find(voice => voice.quoteId === id) ?? null : voices[0] ?? null
}
export function moveVoice(voices: PublicVoice[], id: string | null, delta: number): string | null {
  if (!voices.length) return null
  const index = Math.max(0, voices.findIndex(voice => voice.quoteId === id))
  return voices[(index + delta + voices.length) % voices.length].quoteId
}
export function mergeVoices(current: PublicVoice[], next: PublicVoice[]): PublicVoice[] {
  const seen = new Set(current.map(voice => voice.quoteId))
  return [...current, ...next.filter(voice => { if (seen.has(voice.quoteId)) return false; seen.add(voice.quoteId); return true })]
}
export function voiceShare(voice: PublicVoice | null) {
  const query = voice ? `quoteId=${encodeURIComponent(voice.quoteId)}` : ''
  return {
    title: voice ? `闪念间 · ${voice.text.slice(0, 45)}` : '闪念间 · 听听那些年的声音',
    path: `/pages/flashback-voices/index${query ? `?${query}` : ''}`,
    query
  }
}
export function voiceMapPoint(city: VoiceCity) {
  const [lng, lat] = city.lngLat
  if (!Number.isFinite(lng) || !Number.isFinite(lat)) return null
  const left = (45 + (lng - 73) * 14) / 10
  const top = (42 + (54 - lat) * 17) / 7.2
  return left >= 0 && left <= 100 && top >= 0 && top <= 100 ? { left, top } : null
}
