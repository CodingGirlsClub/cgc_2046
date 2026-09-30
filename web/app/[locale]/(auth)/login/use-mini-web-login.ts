'use client';
import { useEffect, useRef, useState } from 'react';
import { client } from '@/lib/apollo-client';
import { MINI_WEB_START, MINI_WEB_STATUS, MINI_WEB_CONSUME, MINI_WEB_CANCEL, type MiniWebRequest } from '@/lib/graphql/mini-web-login';

type Mode = 'QR' | 'LINK';
type Phase = 'loading' | 'ready' | 'confirming' | 'cancelled' | 'expired' | 'error' | 'done';
const STORAGE = 'cgc.miniWebLogin';
function readSaved(): { requestId: string; mode: Mode } | null {
  try {
    const saved = JSON.parse(sessionStorage.getItem(STORAGE) ?? 'null');
    return /^[A-Za-z0-9_-]{22}$/.test(saved?.requestId ?? '') && ['QR', 'LINK'].includes(saved?.mode) ? saved : null;
  } catch { return null; }
}
function remember(value: { requestId: string; mode: Mode } | null) {
  try { if (value) sessionStorage.setItem(STORAGE, JSON.stringify(value)); else sessionStorage.removeItem(STORAGE); }
  catch { /* Cookie remains authoritative; disabled sessionStorage only prevents page-reload recovery. */ }
}
function errorCode(error: unknown): string | null {
  const errors = (error as { errors?: Array<{ code?: string; extensions?: { code?: string } }> })?.errors;
  return errors?.[0]?.extensions?.code ?? errors?.[0]?.code ?? null;
}

export function useMiniWebLogin(onDone: () => void) {
  const [seed] = useState(readSaved);
  const [selection, setSelection] = useState<{ mode: Mode; iteration: number }>(() => ({
    mode: seed?.mode ?? (typeof navigator !== 'undefined' && /Android|iPhone|iPad/i.test(navigator.userAgent) ? 'LINK' : 'QR'), iteration: 0,
  }));
  const [request, setRequest] = useState<MiniWebRequest | null>(seed ? { requestId: seed.requestId, status: 'PENDING' } : null);
  const [phase, setPhase] = useState<Phase>('loading');
  const [error, setError] = useState<string | null>(null);
  const doneRef = useRef(onDone);
  const busyPoll = useRef(false);
  const startRef = useRef<{ key: string; promise: Promise<MiniWebRequest> } | null>(null);
  useEffect(() => { doneRef.current = onDone; }, [onDone]);

  useEffect(() => {
    if (selection.iteration === 0 && seed) return;
    let disposed = false;
    const key = `${selection.mode}:${selection.iteration}`;
    // React StrictMode re-subscribes to this promise; it must not issue a second browser proof.
    if (startRef.current?.key !== key) {
      const promise = client.mutate<{ wechatMiniWebLoginStart: MiniWebRequest }>({ mutation: MINI_WEB_START, variables: { mode: selection.mode }, fetchPolicy: 'no-cache' })
        .then(({ data }) => { if (!data?.wechatMiniWebLoginStart) throw new Error('Missing login request'); return data.wechatMiniWebLoginStart; });
      startRef.current = { key, promise };
    }
    void startRef.current.promise.then(result => {
      if (disposed) return;
      remember({ requestId: result.requestId, mode: selection.mode });
      setRequest(result); setPhase('ready'); setError(null);
    }).catch(reason => { if (!disposed) { setError(errorCode(reason) ?? 'mini_web_login_unavailable'); setPhase('error'); } });
    return () => { disposed = true; };
  }, [selection, seed]);

  const requestId = request?.requestId;
  useEffect(() => {
    if (!requestId) return;
    let disposed = false;
    let terminal = false;
    let failures = 0;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const finish = () => {
      terminal = true; remember(null); setPhase('done'); doneRef.current();
    };
    const schedule = (delay: number) => {
      clearTimeout(timer);
      if (!disposed && !terminal && document.visibilityState !== 'hidden') timer = setTimeout(() => void poll(), delay);
    };
    const poll = async () => {
      if (disposed || terminal || document.visibilityState === 'hidden') return;
      if (busyPoll.current) { schedule(3000); return; }
      busyPoll.current = true;
      let delay = 3000;
      try {
        const { data } = await client.query<{ wechatMiniWebLoginStatus: MiniWebRequest }>({ query: MINI_WEB_STATUS, variables: { requestId }, fetchPolicy: 'no-cache' });
        if (disposed) return;
        const status = data?.wechatMiniWebLoginStatus;
        if (!status) throw new Error('Missing status');
        setRequest(previous => previous ? { ...previous, ...status } : previous);
        failures = 0; setError(null);
        if (status.status === 'CONSUMED') {
          terminal = true;
          if (status.sessionEstablished) finish();
          else { setError('mini_web_login_consumed'); setPhase('error'); }
        } else if (status.status === 'CANCELLED' || status.status === 'EXPIRED') {
          terminal = true; remember(null); setPhase(status.status === 'EXPIRED' ? 'expired' : 'cancelled');
        } else if (status.status === 'APPROVED') {
          setPhase('confirming');
          const result = await client.mutate<{ wechatMiniWebLoginConsume: { id: string; status: string } }>({ mutation: MINI_WEB_CONSUME, variables: { requestId }, fetchPolicy: 'no-cache' });
          if (disposed) return;
          if (result.data?.wechatMiniWebLoginConsume?.id) finish(); else throw new Error('Missing session');
        } else setPhase('ready');
      } catch (reason) {
        if (disposed) return;
        const code = errorCode(reason);
        if (code && code !== 'rate_limited' && code !== 'mini_web_login_consumed' && code !== 'mini_web_login_failed') {
          terminal = true; setPhase('error'); setError(code);
        } else {
          failures++; delay = code === 'rate_limited' ? 60000 : Math.min(3000 * 2 ** (failures - 1), 15000);
          setPhase('ready');
          setError(code ?? 'network');
        }
      } finally { busyPoll.current = false; schedule(delay); }
    };
    const resume = () => { clearTimeout(timer); if (document.visibilityState !== 'hidden') void poll(); };
    document.addEventListener('visibilitychange', resume); window.addEventListener('pageshow', resume);
    void poll();
    return () => { disposed = true; clearTimeout(timer); document.removeEventListener('visibilitychange', resume); window.removeEventListener('pageshow', resume); };
  }, [requestId]);

  // A server outage must not keep polling beyond the request lifetime.
  useEffect(() => {
    if (!requestId || ['done', 'cancelled', 'expired', 'error'].includes(phase)) return;
    const timer = setTimeout(() => { setRequest(null); setPhase('expired'); remember(null); }, request?.expiresAt ? Math.min(600000, Math.max(0, Date.parse(request.expiresAt) - Date.now())) : 600000);
    return () => clearTimeout(timer);
  }, [requestId, request?.expiresAt, phase]);

  const restart = (mode: Mode = selection.mode) => {
    if (phase === 'loading' || phase === 'confirming') return;
    remember(null); setRequest(null); setError(null); setPhase('loading');
    setSelection(previous => ({ mode, iteration: previous.iteration + 1 }));
  };
  const cancel = async () => {
    if (!requestId) return;
    // Stop the effect before cancelling so a late status response cannot initiate consumption.
    setRequest(null); remember(null); setPhase('cancelled');
    try {
      const result = await client.mutate<{ wechatMiniWebLoginCancel: { status: string } }>({ mutation: MINI_WEB_CANCEL, variables: { requestId }, fetchPolicy: 'no-cache' });
      if (result.data?.wechatMiniWebLoginCancel?.status === 'CONSUMED') {
        setError('mini_web_login_consumed'); setPhase('error');
      } else if (result.data?.wechatMiniWebLoginCancel?.status !== 'CANCELLED') {
        setError('mini_web_login_failed'); setPhase('error');
      }
    }
    catch { setError('mini_web_login_failed'); setPhase('error'); }
  };
  return { request, phase, error, mode: selection.mode, restart, cancel };
}
