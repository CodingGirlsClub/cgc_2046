import { act, renderHook, waitFor } from '@testing-library/react';
import { StrictMode } from 'react';
import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest';
import { useMiniWebLogin } from './use-mini-web-login';
const { mutate, query } = vi.hoisted(() => ({ mutate: vi.fn(), query: vi.fn() }));
vi.mock('@/lib/apollo-client', () => ({ client: { mutate, query } }));
const request = { requestId: 'abcdefghijklmnopqrstuv', status: 'PENDING', expiresAt: '2099-01-01T00:00:00Z', qrDataUrl: 'data:image/png;base64,AAAA', pollIntervalSeconds: 3 };
describe('mini-program browser handoff', () => {
  beforeEach(() => { sessionStorage.clear(); vi.clearAllMocks(); mutate.mockResolvedValue({ data: { wechatMiniWebLoginStart: request } }); query.mockResolvedValue({ data: { wechatMiniWebLoginStatus: { ...request, sessionEstablished: false } } }); });
  afterEach(() => vi.useRealTimers());
  it('starts once and polling does not sign in before approval', async () => {
    const done = vi.fn(); const { result, unmount } = renderHook(() => useMiniWebLogin(done));
    await waitFor(() => expect(result.current.phase).toBe('ready'));
    expect(mutate).toHaveBeenCalledTimes(1); expect(done).not.toHaveBeenCalled();
    expect(JSON.parse(sessionStorage.getItem('cgc.miniWebLogin')!)).toEqual({ requestId: request.requestId, mode: 'QR' });
    unmount();
  });
  it('resumes the original request after returning from WeChat instead of creating another', async () => {
    sessionStorage.setItem('cgc.miniWebLogin', JSON.stringify({ requestId: request.requestId, mode: 'LINK' }));
    query.mockResolvedValue({ data: { wechatMiniWebLoginStatus: { ...request, status: 'CONSUMED', sessionEstablished: true } } });
    const done = vi.fn(); renderHook(() => useMiniWebLogin(done));
    await waitFor(() => expect(done).toHaveBeenCalledOnce());
    expect(mutate).not.toHaveBeenCalled(); expect(sessionStorage.getItem('cgc.miniWebLogin')).toBeNull();
  });
  it('consumed request without the matching session requires a new scan', async () => {
    sessionStorage.setItem('cgc.miniWebLogin', JSON.stringify({ requestId: request.requestId, mode: 'QR' }));
    query.mockResolvedValue({ data: { wechatMiniWebLoginStatus: { ...request, status: 'CONSUMED', sessionEstablished: false } } });
    const done = vi.fn(); const { result } = renderHook(() => useMiniWebLogin(done));
    await waitFor(() => expect(result.current.phase).toBe('error'));
    expect(done).not.toHaveBeenCalled(); expect(mutate).not.toHaveBeenCalled();
  });
  it('approved request is consumed once and cancellation prevents subsequent polling', async () => {
    query.mockResolvedValue({ data: { wechatMiniWebLoginStatus: { ...request, status: 'APPROVED' } } });
    mutate.mockImplementation(({ mutation }: { mutation: { definitions: { name: { value: string } }[] } }) => Promise.resolve({ data: mutation.definitions[0].name.value === 'WechatMiniWebLoginStart' ? { wechatMiniWebLoginStart: request } : { wechatMiniWebLoginConsume: { id: 'user-1', status: 'CONSUMED' } } }));
    const done = vi.fn(); renderHook(() => useMiniWebLogin(done));
    await waitFor(() => expect(done).toHaveBeenCalledOnce()); expect(mutate).toHaveBeenCalledTimes(2);
  });
  it('StrictMode does not rotate the proof twice', async () => {
    const { result } = renderHook(() => useMiniWebLogin(vi.fn()), { wrapper: StrictMode });
    await waitFor(() => expect(result.current.phase).toBe('ready'));
    expect(mutate).toHaveBeenCalledTimes(1);
  });
  it('late approval after cancellation cannot issue a consumption request', async () => {
    let resolveStatus!: (value: unknown) => void;
    query.mockReturnValue(new Promise(resolve => { resolveStatus = resolve; }));
    const done = vi.fn(); const { result } = renderHook(() => useMiniWebLogin(done));
    await waitFor(() => expect(query).toHaveBeenCalledOnce());
    mutate.mockResolvedValue({ data: { wechatMiniWebLoginCancel: { status: 'CANCELLED' } } });
    await act(async () => { await result.current.cancel(); });
    await act(async () => { resolveStatus({ data: { wechatMiniWebLoginStatus: { ...request, status: 'APPROVED' } } }); });
    expect(done).not.toHaveBeenCalled(); expect(mutate).toHaveBeenCalledTimes(2);
    expect(result.current.phase).toBe('cancelled');
  });
  it('does not claim cancellation when consumption won the race', async () => {
    const { result } = renderHook(() => useMiniWebLogin(vi.fn()));
    await waitFor(() => expect(result.current.phase).toBe('ready'));
    mutate.mockResolvedValue({ data: { wechatMiniWebLoginCancel: { status: 'CONSUMED' } } });
    await act(async () => { await result.current.cancel(); });
    expect(result.current.phase).toBe('error');
    expect(result.current.error).toBe('mini_web_login_consumed');
  });
  it('can complete a fresh login while the previous status request is hung', async () => {
    const next = { ...request, requestId: 'bcdefghijklmnopqrstuvw' };
    query.mockReturnValueOnce(new Promise(() => {})).mockResolvedValue({ data: { wechatMiniWebLoginStatus: { status: 'APPROVED', expiresAt: next.expiresAt } } });
    mutate.mockResolvedValueOnce({ data: { wechatMiniWebLoginStart: request } })
      .mockResolvedValueOnce({ data: { wechatMiniWebLoginCancel: { status: 'CANCELLED' } } })
      .mockResolvedValueOnce({ data: { wechatMiniWebLoginStart: next } })
      .mockResolvedValueOnce({ data: { wechatMiniWebLoginConsume: { id: 'user-1', status: 'CONSUMED' } } });
    const done = vi.fn(); const { result, unmount } = renderHook(() => useMiniWebLogin(done));
    await waitFor(() => expect(query).toHaveBeenCalledOnce());
    await act(async () => { await result.current.cancel(); });
    act(() => result.current.restart());
    try { await waitFor(() => expect(done).toHaveBeenCalledOnce()); }
    finally { unmount(); }
  });
  it.each(['network failure', 'already consumed'])('ignores an old cancellation result: %s', async (outcome) => {
    const next = { ...request, requestId: 'bcdefghijklmnopqrstuvw' };
    let resolveCancel!: (value: unknown) => void;
    let rejectCancel!: (reason: Error) => void;
    query.mockResolvedValue({ data: { wechatMiniWebLoginStatus: { status: 'PENDING', expiresAt: request.expiresAt } } });
    mutate.mockResolvedValueOnce({ data: { wechatMiniWebLoginStart: request } })
      .mockImplementationOnce(() => new Promise((resolve, reject) => { resolveCancel = resolve; rejectCancel = reject; }))
      .mockResolvedValueOnce({ data: { wechatMiniWebLoginStart: next } });
    const { result, unmount } = renderHook(() => useMiniWebLogin(vi.fn()));
    await waitFor(() => expect(result.current.phase).toBe('ready'));
    let cancellation!: Promise<void>;
    act(() => { cancellation = result.current.cancel(); });
    act(() => result.current.restart());
    await waitFor(() => expect(result.current.request?.requestId).toBe(next.requestId));
    await act(async () => {
      if (outcome === 'network failure') rejectCancel(new Error('network'));
      else resolveCancel({ data: { wechatMiniWebLoginCancel: { status: 'CONSUMED' } } });
      await cancellation;
    });
    try { expect(result.current.phase).toBe('ready'); expect(result.current.error).toBeNull(); }
    finally { unmount(); }
  });
  it('recovers from a timed-out status request and releases timers on unmount', async () => {
    vi.useFakeTimers();
    query.mockImplementationOnce(({ context }) => new Promise((_, reject) => {
      context.fetchOptions.signal.addEventListener('abort', () => reject(new Error('timeout')), { once: true });
    })).mockResolvedValue({ data: { wechatMiniWebLoginStatus: { status: 'CONSUMED', sessionEstablished: true } } });
    const done = vi.fn();
    let hook!: ReturnType<typeof renderHook<ReturnType<typeof useMiniWebLogin>, unknown>>;
    await act(async () => { hook = renderHook(() => useMiniWebLogin(done)); });
    await act(async () => { await vi.advanceTimersByTimeAsync(15000); });
    expect(hook.result.current.error).toBe('network');
    await act(async () => { await vi.advanceTimersByTimeAsync(3000); });
    expect(done).toHaveBeenCalledOnce();
    hook.unmount();
    expect(vi.getTimerCount()).toBe(0);
  });
  it('a hung first start times out and can be retried without duplicate StrictMode starts', async () => {
    vi.useFakeTimers();
    mutate.mockImplementationOnce(({ context }) => new Promise((_, reject) => {
      context?.fetchOptions.signal.addEventListener('abort', () => reject(new Error('timeout')), { once: true });
    })).mockResolvedValue({ data: { wechatMiniWebLoginStart: request } });
    let hook!: ReturnType<typeof renderHook<ReturnType<typeof useMiniWebLogin>, unknown>>;
    await act(async () => { hook = renderHook(() => useMiniWebLogin(vi.fn()), { wrapper: StrictMode }); });
    expect(mutate).toHaveBeenCalledOnce();
    await act(async () => { await vi.advanceTimersByTimeAsync(15000); });
    expect(hook.result.current.phase).toBe('error');
    await act(async () => { hook.result.current.restart(); });
    expect(hook.result.current.phase).toBe('ready');
    expect(mutate).toHaveBeenCalledTimes(2);
    hook.unmount();
    expect(vi.getTimerCount()).toBe(0);
  });
  it('aborts an unfinished start on real unmount before another instance can receive a proof', async () => {
    let aborted = false;
    mutate.mockImplementationOnce(({ context }) => new Promise((_, reject) => {
      context.fetchOptions.signal.addEventListener('abort', () => { aborted = true; reject(new Error('aborted')); }, { once: true });
    })).mockResolvedValue({ data: { wechatMiniWebLoginStart: request } });
    const first = renderHook(() => useMiniWebLogin(vi.fn()));
    await waitFor(() => expect(mutate).toHaveBeenCalledOnce());
    await act(async () => { first.unmount(); });
    expect(aborted).toBe(true);
    const next = renderHook(() => useMiniWebLogin(vi.fn()));
    await waitFor(() => expect(next.result.current.phase).toBe('ready'));
    next.unmount();
  });
  it('does not report cancellation until confirmed and bounds an unknown cancellation result', async () => {
    vi.useFakeTimers();
    mutate.mockResolvedValueOnce({ data: { wechatMiniWebLoginStart: request } })
      .mockImplementationOnce(({ context }) => new Promise((_, reject) => {
        context?.fetchOptions.signal.addEventListener('abort', () => reject(new Error('timeout')), { once: true });
      }));
    let hook!: ReturnType<typeof renderHook<ReturnType<typeof useMiniWebLogin>, unknown>>;
    await act(async () => { hook = renderHook(() => useMiniWebLogin(vi.fn())); });
    let cancellation!: Promise<void>;
    act(() => { cancellation = hook.result.current.cancel(); });
    try {
      expect(hook.result.current.phase).toBe('cancelling');
      await act(async () => { await vi.advanceTimersByTimeAsync(15000); await cancellation; });
      expect(hook.result.current.phase).toBe('error');
      expect(hook.result.current.error).toBe('mini_web_login_failed');
    } finally { hook.unmount(); }
    expect(vi.getTimerCount()).toBe(0);
  });
});
