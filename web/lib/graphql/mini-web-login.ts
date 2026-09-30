import { gql } from '@apollo/client';
export type MiniWebStatus = 'PENDING' | 'APPROVED' | 'CONSUMED' | 'CANCELLED' | 'EXPIRED';
export interface MiniWebRequest {
  requestId: string;
  status: MiniWebStatus;
  expiresAt?: string;
  qrDataUrl?: string;
  launchUrl?: string;
  sessionEstablished?: boolean;
}
export const MINI_WEB_START = gql`mutation WechatMiniWebLoginStart($mode: MiniWebLoginMode!) {
  wechatMiniWebLoginStart(mode: $mode) { requestId status expiresAt qrDataUrl launchUrl pollIntervalSeconds }
}`;
export const MINI_WEB_STATUS = gql`query WechatMiniWebLoginStatus($requestId: String!) {
  wechatMiniWebLoginStatus(requestId: $requestId) { status expiresAt sessionEstablished }
}`;
export const MINI_WEB_CONSUME = gql`mutation WechatMiniWebLoginConsume($requestId: String!) {
  wechatMiniWebLoginConsume(requestId: $requestId) { id status }
}`;
export const MINI_WEB_CANCEL = gql`mutation WechatMiniWebLoginCancel($requestId: String!) {
  wechatMiniWebLoginCancel(requestId: $requestId) { status }
}`;
