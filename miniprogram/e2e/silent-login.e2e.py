#!/usr/bin/env python3
"""#930 回访静默登录（CGC_E2E_MOCK=true 构建 + WeChatIDE 模拟器）。

点「手机号快捷登录」先试静默登录：本平台已绑定身份 → 不弹协议框、直接回到来处；
主动退出后的下一次 → 走协议框 + 手机号（方便换账号），手机号登录成功后恢复；
本平台没绑定身份 → 照旧协议框。mock 约定：cgc.e2e.platform_identity = '1' 即已绑定。
合成数据，不导出 storage / 凭证。报告写 /tmp。
"""
import importlib.util, json, time
from pathlib import Path
spec = importlib.util.spec_from_file_location('native', Path(__file__).with_name('wish-writing.e2e.py'))
a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a)
a.REPORT = Path('/tmp/cgc-silent-login-report.json')
L, C = 'login', 'flashback-corridor'
RETURN = '/pages/login/index?returnUrl=' + '%2Fpages%2Fflashback-corridor%2Findex'

def route(): return a.evaluate('return getCurrentPages().slice(-1)[0].route')
def wait_route(target, timeout=6):
    end = time.time() + timeout
    while time.time() < end and route() != target: time.sleep(0.3)
    return route()
def count(page, name):
    return a.evaluate('return new Promise(r=>wx.createSelectorQuery().selectAll(' + json.dumps(a.cls(page, name)) + ').boundingClientRect().exec(x=>r(x[0].length)))')
def storage(key): return a.evaluate('return wx.getStorageSync(' + json.dumps(key) + ') || ""')
def set_storage(key, value): a.evaluate('wx.setStorageSync(' + json.dumps(key) + ',' + json.dumps(value) + ');return true')
def sign_out():
    a.call('automation_navigate', action='reLaunch', url='/pages/profile/index')
    if count('profile', 'logout'): a.tap('profile', 'logout')
def open_login():
    a.call('automation_navigate', action='reLaunch', url=RETURN); time.sleep(1)

if __name__ == '__main__':
    # 先正常登录一次（本平台未绑定 → 协议框 + 手机号），再主动退出
    set_storage('cgc.e2e.platform_identity', '0')
    open_login(); a.tap(L, 'loginButton'); time.sleep(0.8); a.tap(L, 'dialogPrimary')
    a.check('首次登录走协议框 + 手机号', wait_route('pages/' + C + '/index') == 'pages/' + C + '/index')
    set_storage('cgc.e2e.platform_identity', '1')

    # 主动退出 → 下一次不静默：点登录弹协议框（可以换账号）
    sign_out()
    a.check('主动退出后静默登录关闭', storage('cgc.silent_login_off') == '1')
    open_login(); a.tap(L, 'loginButton'); time.sleep(0.8)
    a.check('主动退出后的下一次登录：弹协议框，不静默回到刚退出的账号', count(L, 'dialogMask') == 1 and route() == 'pages/login/index')
    a.tap(L, 'dialogPrimary')
    a.check('协议框里走手机号登录，回到来处', wait_route('pages/' + C + '/index') == 'pages/' + C + '/index')
    a.check('手机号登录成功后恢复静默登录', storage('cgc.silent_login_off') == '')

    # 已绑定身份 + 未主动退出：一点即登录，不弹协议框、不走手机号
    open_login(); a.tap(L, 'loginButton')
    a.check('回访静默登录：直接回到来处（没有协议框这一步）', wait_route('pages/' + C + '/index') == 'pages/' + C + '/index')

    # 本平台没绑定身份（首次登录）：照旧协议框
    set_storage('cgc.e2e.platform_identity', '0')
    open_login(); a.tap(L, 'loginButton'); time.sleep(0.8)
    a.check('没有绑定身份：照旧弹协议框', count(L, 'dialogMask') == 1)
    a.tap(L, 'dialogSecondary')
    a.check('不同意 → 留在登录页', count(L, 'dialogMask') == 0 and route() == 'pages/login/index')

    print('Completed ' + str(len(a.checks)) + ' native checks. ' + str(a.REPORT), flush=True)
