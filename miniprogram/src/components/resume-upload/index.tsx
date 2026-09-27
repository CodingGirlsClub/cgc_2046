import { Button, Text, View } from '@tarojs/components'
import Taro from '@tarojs/taro'
import { useState } from 'react'
import { api } from '@/api'
import { chooseResumeTempFile } from '@/platform'
import type { ResumeFileInput, ResumeFileSelection, ResumeProfileSummary } from '@/domain/models'
import {
  RESUME_FILE_EXTENSIONS,
  hasResumeFile,
  resumeContentTypeFor,
  resumeFileError,
  resumeFileSizeText
} from '@/domain/recruitment'
import styles from './index.module.css'

/**
 * 简历文件选择上传控件（R20/R9；小程序侧唯一的文件入口）。
 *
 * 路径 = 选文件（微信「从聊天记录选择文件」/ 小红书原生文件选择——两端原生 API
 * 字段名不同，已在 `platform/index.ts` 的 `chooseResumeTempFile` 归一为
 * `{ name, path, size }`，advisor-plans/010）→
 * 本地前置校验（扩展名 / ≤5MB）→ **先建档再上传**（U2 契约：档案不存在时上传会被
 * resume_profile_not_found 拒，故 ensureProfile 先跑）→ 读本地文件为 base64 → U2
 * 单入口 `uploadResumeFile`。二次选择覆盖同一档案（一人一档）。
 *
 * 判据（扩展名白名单 / 大小上限 / 文案）全部在 domain/recruitment.ts，本组件只做
 * 调起与状态——魔数与 declared MIME 的一致性由后端判（客户端不复刻，见 domain 注释）。
 *
 * 平台面以参数注入（`ResumePickerTaro`）：小程序无页面级测试，选择/读取/上传三步
 * 的编排用假 Taro 在 tests/volunteer-apply.test.ts 里钉住。
 */

/** 本控件用到的平台方法（真机传 Taro + chooseResumeTempFile；测试注入假实现） */
export interface ResumePickerTaro {
  /** 已归一的文件选择（见 platform/index.ts chooseResumeTempFile）；取消/不支持 → null */
  chooseFile: (extension: string[]) => Promise<{ name: string; path: string; size: number } | null>
  getFileSystemManager: () => {
    readFileSync: (filePath: string, encoding?: 'base64') => string | ArrayBuffer
  }
  /**
   * ArrayBuffer → base64（小红书兜底：xhs 模拟器 3.133.1 实测 2026-09-27，
   * `readFileSync(path, 'base64')` 抛 `fsReadFileSync fail: Invalid argument`——
   * 小红书不支持 base64 编码参数，只能 `readFileSync(path)` 拿 ArrayBuffer 后
   * 在 JS 里转 base64）。微信 `readFileSync(path, 'base64')` 直接可用，不走此路。
   */
  arrayBufferToBase64: (buffer: ArrayBuffer) => string
  showToast: (option: { title: string; icon: 'none' | 'success' }) => unknown
}

/**
 * 选择本地简历文件 + 前置校验。
 *
 * 取消 / 不支持（`chooseResumeTempFile` 已吞掉这两种情形）→ null（静默）；校验
 * 不过 → toast 提示并 null；通过 → 带同族 MIME 的选择结果（尚未上传）。
 */
export async function chooseResumeFile(taro: ResumePickerTaro): Promise<ResumeFileSelection | null> {
  const file = await taro.chooseFile([...RESUME_FILE_EXTENSIONS])
  if (!file) return null

  const invalid = resumeFileError(file)
  if (invalid) {
    taro.showToast({ title: invalid, icon: 'none' })
    return null
  }

  // resumeFileError 已保证扩展名在白名单内 → MIME 必有值（非空断言仅此处）
  const contentType = resumeContentTypeFor(file.name) as string
  return { name: file.name, path: file.path, size: file.size, contentType }
}

/**
 * 读本地临时文件为 base64（U2 请求体字段）。
 *
 * 先试 `readFileSync(path, 'base64')`（微信路径，直接拿字符串）；小红书不支持
 * base64 编码参数会抛错——回退到 `readFileSync(path)`（ArrayBuffer）再用
 * `arrayBufferToBase64` 转换（xhs 模拟器 3.133.1 实测 2026-09-27）。两条路都读不到
 * 内容 → 抛可读错误。
 */
export function readResumeBase64(taro: ResumePickerTaro, path: string): string {
  const fsm = taro.getFileSystemManager()
  try {
    const data = fsm.readFileSync(path, 'base64')
    if (typeof data === 'string' && data !== '') return data
  } catch {
    // 小红书：base64 编码参数不支持，落到下面的 ArrayBuffer 兜底
  }
  const buffer = fsm.readFileSync(path)
  if (buffer instanceof ArrayBuffer) return taro.arrayBufferToBase64(buffer)
  throw new Error('简历文件读取失败，请重新选择。')
}

/**
 * 选择 → 校验 → 建档 → 读 base64 → 上传的完整编排（一个用户手势内）。
 * 返回新档案；取消/校验不过 → null（已提示或用户放弃）；网络/业务错误上抛给页面。
 */
export async function pickAndUploadResume(options: {
  taro: ResumePickerTaro
  /** 建档（后端要求先建档再上传；页面注入 = upsert 当前表单值） */
  ensureProfile: () => Promise<void>
  upload: (input: ResumeFileInput) => Promise<ResumeProfileSummary>
}): Promise<ResumeProfileSummary | null> {
  const file = await chooseResumeFile(options.taro)
  if (!file) return null
  // 先读本地文件再建档：读失败（临时文件被清理）不必在服务端留下一次白写的 upsert
  const contentBase64 = readResumeBase64(options.taro, file.path)
  await options.ensureProfile()
  return options.upload({ fileName: file.name, contentType: file.contentType, contentBase64 })
}

interface Props {
  profile: ResumeProfileSummary | null
  /** 上传前的建档动作（页面的 upsert；闭包应读取当前表单值） */
  ensureProfile: () => Promise<void>
  onUploaded: (profile: ResumeProfileSummary) => void
  onError: (message: string) => void
}

export function ResumeUpload({ profile, ensureProfile, onUploaded, onError }: Props) {
  const [uploading, setUploading] = useState(false)
  const uploaded = hasResumeFile(profile)

  const pick = async () => {
    if (uploading) return
    setUploading(true)
    try {
      const next = await pickAndUploadResume({
        taro: {
          chooseFile: chooseResumeTempFile,
          getFileSystemManager: Taro.getFileSystemManager,
          arrayBufferToBase64: Taro.arrayBufferToBase64,
          showToast: Taro.showToast
        },
        ensureProfile,
        upload: (input) => api.uploadResumeFile(input)
      })
      if (next) {
        onUploaded(next)
        Taro.showToast({ title: '简历已上传', icon: 'success' })
      }
    } catch (reason) {
      onError(reason instanceof Error ? reason.message : '简历上传失败，请重试。')
    } finally {
      setUploading(false)
    }
  }

  return (
    <View className={styles.wrap} data-testid='resume-upload'>
      <Text className={styles.label}>简历文件（PDF / Word，不超过 5MB）</Text>
      {uploaded ? (
        <Text className={styles.file} data-testid='resume-file-name'>
          已上传：{profile?.fileName}
          {profile?.fileSize != null ? `（${resumeFileSizeText(profile.fileSize)}）` : ''}
        </Text>
      ) : (
        <Text className={styles.hint}>还没有简历文件——上传一次，后续批次不用重传。</Text>
      )}
      <Button
        className={styles.button}
        size='mini'
        loading={uploading}
        disabled={uploading}
        data-testid='resume-pick'
        onClick={pick}
      >
        {uploading ? '上传中…' : uploaded ? '重新上传' : '选择文件'}
      </Button>
      <Text className={styles.note}>从聊天记录里的文件中选择；仅招募团队可见（PIPL）。</Text>
    </View>
  )
}
