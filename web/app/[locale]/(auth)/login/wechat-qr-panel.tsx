'use client';
import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { client } from '@/lib/apollo-client';
import { useMiniWebLogin } from './use-mini-web-login';
import { navigateAfterLogin } from './use-auth-submit';
import styles from './wechat-qr-panel.module.css';

/** Small-program authorization replaces the current OAuth launch surface. Legacy callbacks stay routable. */
export default function WechatQrPanel() {
  const t = useTranslations('auth.miniWeb');
  const router = useRouter();
  const { request, phase, error, mode, restart, cancel } = useMiniWebLogin(() => {
    // Navigation reloads authenticated views even if a stale mounted query cannot refetch.
    const navigate = () => navigateAfterLogin(router, new URLSearchParams(window.location.search).get('next'));
    void client.resetStore().then(navigate, navigate);
  });
  const busy = phase === 'loading' || phase === 'confirming' || phase === 'cancelling';
  const terminal = ['expired', 'cancelled', 'error'].includes(phase);
  const [countdown, setCountdown] = useState<{ deadline: string; seconds: number } | null>(null);
  const deadline = request?.expiresAt;
  useEffect(() => {
    if (!deadline || phase !== 'ready') return;
    const timer = setInterval(() => setCountdown({ deadline, seconds: Math.max(0, Math.ceil((Date.parse(deadline) - Date.now()) / 1000)) }), 1000);
    return () => clearInterval(timer);
  }, [deadline, phase]);
  return (
    <div className='auth-wechat-panel' aria-busy={busy}>
      <p className='auth-wechat-hint' role='status' aria-live='polite'>
        {phase === 'loading' ? t('loading') : phase === 'confirming' ? t('confirming') : phase === 'cancelling' ? t('cancelling') : phase === 'done' ? t('done') : phase === 'expired' ? t('expired') : phase === 'cancelled' ? t('cancelled') : request && !request.qrDataUrl && !request.launchUrl ? t('restored') : mode === 'QR' ? t('scan') : t('return')}
      </p>
      {!terminal && phase !== 'done' && mode === 'QR' && request?.qrDataUrl && (
        // Server-generated image is bounded and the data URL never contains a login credential.
        // eslint-disable-next-line @next/next/no-img-element
        <img className='auth-wechat-qr' src={request.qrDataUrl} alt={t('qrAlt')} width={200} height={200} />
      )}
      {!terminal && phase === 'ready' && mode === 'LINK' && request?.launchUrl && <a className={styles.launch} href={request.launchUrl} referrerPolicy='no-referrer'>{t('open')}</a>}
      {!terminal && (phase === 'ready' || phase === 'confirming') && mode === 'LINK' && <p className='auth-wechat-hint'>{t('returnHint')}</p>}
      {phase === 'ready' && countdown && countdown.deadline === deadline && <p className='auth-wechat-hint' aria-live='off'>{t('expiresIn', { seconds: countdown.seconds })}</p>}
      {error && <p className='auth-alert' role='alert'>{error === 'network' ? t('network') : error === 'mini_web_login_account_conflict' ? t('accountConflict') : error === 'mini_web_login_consumed' ? t('alreadyUsed') : error === 'rate_limited' ? t('rateLimited') : t('unavailable')}</p>}
      {phase !== 'done' && <button type='button' className={`auth-sms-send ${styles.control}`} disabled={busy} onClick={() => restart()}>{t('restart')}</button>}
      {!terminal && phase === 'ready' && <>
        <button type='button' className={`auth-inline-link ${styles.control}`} onClick={() => restart(mode === 'QR' ? 'LINK' : 'QR')}>{mode === 'QR' ? t('switchToLink') : t('switchToQr')}</button>
        <button type='button' className={`auth-inline-link ${styles.control}`} onClick={() => void cancel()}>{t('cancel')}</button>
      </>}
    </div>
  );
}
