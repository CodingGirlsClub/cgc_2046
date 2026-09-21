import { FlashbackNotBoundError, type MiniProgramApi } from '@/domain/models'
import { RealMiniProgramApi, SessionExpiredError } from './real'

export const api: MiniProgramApi = new RealMiniProgramApi()
export { FlashbackNotBoundError, SessionExpiredError }
