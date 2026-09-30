import { beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, screen } from '@testing-library/react';
import { render } from '@/test-utils';
import WechatQrPanel from './wechat-qr-panel';
const { state, restart, cancel } = vi.hoisted(() => ({ state: { current: {} as Record<string, unknown> }, restart: vi.fn(), cancel: vi.fn() }));
vi.mock('./use-mini-web-login', () => ({ useMiniWebLogin: () => ({ ...state.current, restart, cancel }) }));
vi.mock('next/navigation', async (original) => ({ ...await original<typeof import('next/navigation')>(), useRouter: () => ({ push: vi.fn() }) }));
vi.mock('@apollo/client/react', () => ({ useMutation: () => [vi.fn().mockResolvedValue({ data: { wechatLoginStart: { qrUrl: 'https://example.com', expiresInSeconds: 600 } } }), {}] }));
describe('mini-program login panel', () => {
  beforeEach(() => { vi.clearAllMocks(); state.current = { phase: 'ready', mode: 'QR', error: null, request: { qrDataUrl: 'data:image/png;base64,AAAA' } }; });
  it('shows a mini-program image and explicit confirmation guidance', () => {
    render(<WechatQrPanel />);
    expect(screen.getByRole('img', { name: '微信登录小程序码' })).toBeInTheDocument();
    expect(screen.getByText('使用微信扫码，在小程序中确认登录。')).toBeInTheDocument();
    expect(document.querySelector('iframe')).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: '在手机上打开小程序' })); expect(restart).toHaveBeenCalledWith('LINK');
  });
  it('mobile launch is a direct link ready before the click', () => {
    state.current = { phase: 'ready', mode: 'LINK', request: { launchUrl: 'https://wxaurl.cn/test?cq=wl_test' } };
    render(<WechatQrPanel />);
    expect(screen.getByRole('link', { name: '打开微信小程序登录' })).toHaveAttribute('href', 'https://wxaurl.cn/test?cq=wl_test');
    expect(screen.getByText('确认后，请返回当前浏览器的这个页面。')).toBeInTheDocument();
  });
  it('expiry offers a fresh request rather than SMS binding', () => {
    state.current = { phase: 'expired', mode: 'QR', request: null }; render(<WechatQrPanel />);
    fireEvent.click(screen.getByRole('button', { name: '重新发起登录' })); expect(restart).toHaveBeenCalled();
    expect(screen.queryByText('绑定手机号')).not.toBeInTheDocument();
  });
  it('pending cancellation never claims that authorization has been cancelled', () => {
    state.current = { phase: 'cancelling', mode: 'QR', request: null }; render(<WechatQrPanel />);
    expect(screen.getByRole('status')).toHaveTextContent('正在取消登录，请稍候…');
    expect(screen.getByRole('button', { name: '重新发起登录' })).toBeDisabled();
    expect(screen.queryByText('本次登录已取消。')).not.toBeInTheDocument();
  });
});
