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
});
