#!/usr/bin/env python3
"""#929 公开卡「找回」与闪念间转发落地（CGC_E2E_MOCK=true 构建 + WeChatIDE 模拟器）。

公开卡（已收回态）点「找回我的闪念间」→ 闪念间 Tab：未登录落公开首页（不再先被告知
「没有找到这张邀请函」），有档案落自己的长廊；长廊 / 首程 / 公开卡的转发 path 都是闪念间 Tab；
不带 token 的首程页只留给失效链接，原文案不变。合成数据，不导出 storage / 凭证。报告写 /tmp。
"""
import importlib.util, json, time
from pathlib import Path
spec = importlib.util.spec_from_file_location('native', Path(__file__).with_name('wish-writing.e2e.py'))
a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a)
a.REPORT = Path('/tmp/cgc-flashback-shared-card-report.json')
S, C, J = 'flashback-shared-card', 'flashback-corridor', 'flashback-journey'
ENTRY = '/pages/flashback-corridor/index'
CLOSED_CARD = '/pages/' + S + '/index?shareId=closed'
NOT_FOUND = '没有找到这张邀请函。检查一下链接，或用网页端「闪念间」凭手机号找回。'

def route(): return a.evaluate('return getCurrentPages().slice(-1)[0].route')
def wait_route(target, timeout=6):
    end = time.time() + timeout
    while time.time() < end and route() != target: time.sleep(0.3)
    return route()
def count(page, name):
    return a.evaluate('return new Promise(r=>wx.createSelectorQuery().selectAll(' + json.dumps(a.cls(page, name)) + ').boundingClientRect().exec(x=>r(x[0].length)))')
def text(page, name): return a.call('automation_element_action', selector=a.cls(page, name), action='text')
def tap(page, name): return a.call('automation_element_action', selector=a.cls(page, name), action='tap')
def share_path(): return a.evaluate('return getCurrentPages().slice(-1)[0].onShareAppMessage({from:"menu"}).path')
def flag(values): a.evaluate(''.join('wx.setStorageSync(' + json.dumps('cgc.e2e.' + k) + ',' + json.dumps(v) + ');' for k, v in values.items()) + 'return true')
def sign_out():
    a.evaluate('wx.removeStorageSync("cgc.flashback_token"); return true')
    a.call('automation_navigate', action='reLaunch', url='/pages/profile/index')
    if a.evaluate('return new Promise(r=>wx.createSelectorQuery().selectAll(' + json.dumps(a.cls('profile', 'logout')) + ').boundingClientRect().exec(x=>r(x[0].length)))'):
        a.tap('profile', 'logout')
def open_closed_card():
    a.call('automation_navigate', action='reLaunch', url=CLOSED_CARD); time.sleep(1.5)

if __name__ == '__main__':
    flag({'flashback_unclaimed': '0', 'flashback_claim_miss': '0', 'flashback_claim_fail': '0'})
    sign_out()

    # 未登录新人：公开卡 → 找回 → 闪念间 Tab 的公开首页
    open_closed_card()
    a.check('公开卡（已收回）落终态', text(S, 'terminalTitle') == '这张卡已经收回')
    a.check('公开卡未开分享时的转发 path = 闪念间 Tab', share_path() == ENTRY)
    tap(S, 'terminalAction')
    a.check('未登录点「找回」→ 闪念间 Tab（不是不带 token 的首程页）', wait_route('pages/' + C + '/index') == 'pages/' + C + '/index')
    time.sleep(1.5)
    a.check('未登录落公开首页的找回区（不出现「邀请函」）', text(C, 'recoveryTitle') == '你也在那些年里吗？')
    a.check('长廊的转发 path = 闪念间 Tab', share_path() == ENTRY)

    # 不带 token 的首程页只留给失效链接：原文案不变，转发同样回闪念间 Tab
    a.call('automation_navigate', action='reLaunch', url='/pages/' + J + '/index'); time.sleep(1.5)
    a.check('无 token 首程页仍是失效态原文案', text(J, 'invalidText') == NOT_FOUND)
    a.check('首程页的转发 path = 闪念间 Tab', share_path() == ENTRY)

    # 有档案的人：同一入口进自己的长廊
    a.call('automation_navigate', action='reLaunch', url='/pages/login/index')
    a.tap('login', 'loginButton'); a.tap('login', 'dialogPrimary'); time.sleep(1.5)
    open_closed_card()
    tap(S, 'terminalAction')
    a.check('有档案点「找回」→ 闪念间 Tab', wait_route('pages/' + C + '/index') == 'pages/' + C + '/index')
    time.sleep(2)
    if count(C, 'shutterBtn'): tap(C, 'shutterBtn')
    a.check('有档案落自己的长廊（个人卡在，不是公开首页）', count(C, 'cardDock') == 1 and count(C, 'recoveryTitle') == 0)

    print('Completed ' + str(len(a.checks)) + ' native checks. ' + str(a.REPORT), flush=True)
