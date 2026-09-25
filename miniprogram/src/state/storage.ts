export const STORAGE_KEYS = {
  flashbackLastGuestQuote: 'cgc.flashback_last_guest_quote',
  lastEnrollment: 'cgc.last_enrollment',
  pendingScene: 'cgc.pending_scene',
  // 首程链接身份（KTD2）：深链读入后落 storage 会话持有，链接作废/失效即清——
  // 与 web 端 sessionStorage 'flashback.token' 同语义的 mp 侧载体
  flashbackToken: 'cgc.flashback_token',
  // 金句授权引导已推标记(一次性:欢迎落地/寄出落定首次触发后置位)
  flashbackLicenseNudge: 'cgc.flashback_license_nudge_done',
  // 相册开放告知已读标记（#933 一次性：开放前就寄出的人第一次回到长廊时告知可见范围变了）
  flashbackAlbumNotice: 'cgc.flashback_album_notice_done'
} as const
