import Taro from '@tarojs/taro'
import { STORAGE_KEYS } from '@/state/storage'

/**
 * 回访静默登录的开关（#930）。主动退出登录后关掉：下一次登录走手机号（方便换账号——
 * 否则一点登录又回到刚退出的那个账号）；任何一次登录成功后恢复。
 * 登录态自然过期不算主动退出，回访仍一步到位。
 */
export function silentLoginAllowed(): boolean {
  return !Taro.getStorageSync<string>(STORAGE_KEYS.silentLoginOff)
}

export function setSilentLoginAllowed(allowed: boolean): void {
  if (allowed) Taro.removeStorageSync(STORAGE_KEYS.silentLoginOff)
  else Taro.setStorageSync(STORAGE_KEYS.silentLoginOff, '1')
}
