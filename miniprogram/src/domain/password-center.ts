/**
 * 小程序密码中心纯逻辑：页面只渲染与调起，判据与文案下沉到这里
 * （小程序没有页面渲染测试，见 miniprogram/AGENTS.md「页面逻辑一律下沉 domain」）。
 */

/** 与 ash_authentication 注册内置的 `min_length: 8` 对齐（R6）。 */
export const PASSWORD_MIN_LENGTH = 8

export type PasswordFormError = 'required' | 'too_short' | 'mismatch'

/** 设置/重设密码的前端预检；返回 null 表示可提交。 */
export function validateNewPassword(password: string, confirmation: string): PasswordFormError | null {
  if (!password) return 'required'
  if (password.length < PASSWORD_MIN_LENGTH) return 'too_short'
  if (password !== confirmation) return 'mismatch'
  return null
}

export function passwordFormErrorCopy(error: PasswordFormError): string {
  switch (error) {
    case 'required':
      return '请输入新密码'
    case 'too_short':
      return `密码至少 ${PASSWORD_MIN_LENGTH} 位`
    case 'mismatch':
      return '两次输入的密码不一致'
  }
}

/**
 * 提交失败文案：后端密码长度校验是英文 Ash 消息，不直接进 UI。
 * 其余失败统一兜底，避免把 infra 错误原样展示。
 */
export function passwordSubmitErrorCopy(message?: string | null): string {
  if (message && /at least|min_length|length/i.test(message)) {
    return `密码至少 ${PASSWORD_MIN_LENGTH} 位`
  }
  return '设置失败，请稍后重试'
}

/** 账号标识：掩码手机号优先；缺失时明确说明，避免用户猜 Web 该输什么。 */
export function accountIdentifier(phone: string | null): string {
  return phone ? `手机号 ${phone}` : '账号未绑定手机号'
}

/**
 * R4：登录响应明确说「还没设过密码」时才提示可选步骤。
 * undefined（旧后端 / mock 缺字段）不提示，避免误弹。
 */
export function shouldPromptPasswordSetup(session: { hasPassword?: boolean }): boolean {
  return session.hasPassword === false
}

export type PasswordCenterMode = 'set' | 'reset'

/** 密码页全部可视状态；页面只做 dispatch，不进任何渲染测试。 */
export interface PasswordCenterState {
  password: string
  confirmation: string
  error: string
  done: boolean
  busy: boolean
  mode: PasswordCenterMode
  /** 成功后 +1：Taro Input 非受控，靠 key 重建清空旧值。 */
  formKey: number
}

export const initialPasswordCenterState: PasswordCenterState = {
  password: '',
  confirmation: '',
  error: '',
  done: false,
  busy: false,
  mode: 'set',
  formKey: 0
}

export type PasswordCenterAction =
  | { type: 'password_changed'; value: string }
  | { type: 'confirmation_changed'; value: string }
  | { type: 'reset_requested' }
  | { type: 'submit_started' }
  | { type: 'submit_failed'; message: string }
  | { type: 'submit_succeeded' }
  | { type: 'load_failed'; message: string }

/**
 * 密码页状态转移（miniprogram/AGENTS.md：页面状态机必须是纯函数并有
 * node --test 覆盖，因为小程序没有页面渲染测试）。
 */
export function reducePasswordCenter(
  state: PasswordCenterState,
  action: PasswordCenterAction
): PasswordCenterState {
  switch (action.type) {
    case 'password_changed':
      return { ...state, password: action.value }
    case 'confirmation_changed':
      return { ...state, confirmation: action.value }
    case 'reset_requested':
      return { ...state, mode: 'reset', error: '', done: false }
    case 'submit_started':
      return { ...state, busy: true, error: '', done: false }
    case 'submit_failed':
      return { ...state, busy: false, error: action.message, done: false }
    case 'submit_succeeded':
      return {
        ...state,
        busy: false,
        error: '',
        done: true,
        password: '',
        confirmation: '',
        formKey: state.formKey + 1
      }
    case 'load_failed':
      return { ...state, error: action.message }
  }
}
