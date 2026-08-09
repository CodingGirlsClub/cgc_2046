import type { MiniProgramApi } from '@/domain/models'
import { RealMiniProgramApi } from './real'

export const api: MiniProgramApi = new RealMiniProgramApi()
