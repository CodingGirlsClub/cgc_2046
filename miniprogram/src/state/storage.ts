export const STORAGE_KEYS = {
  lastEnrollment: 'cgc.last_enrollment',
  pendingScene: 'cgc.pending_scene',
  // 首程链接身份（KTD2）：深链读入后落 storage 会话持有，链接作废/失效即清——
  // 与 web 端 sessionStorage 'flashback.token' 同语义的 mp 侧载体
  flashbackToken: 'cgc.flashback_token',
  // 金句授权引导已推标记(一次性:欢迎落地/寄出落定首次触发后置位)
  flashbackLicenseNudge: 'cgc.flashback_license_nudge_done'
} as const
