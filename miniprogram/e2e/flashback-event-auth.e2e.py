#!/usr/bin/env python3
"""场次页登录死循环回归（CGC_E2E_MOCK=true 构建 + 已登录的 WeChatIDE 模拟器）。

旧行为：已登录但库里没匹配到档案的用户进场次页，看到「你也在这一场吗？登录后
我们帮你找你的那一张」+ 登录按钮 → 登录 → 回跳仍未匹配 → 又要登录……每圈都消耗
「IP + 微信」登录限流额度（与订阅授权共用），几圈后 Too many requests。
未登录访客从深链进场次页则落错误页。

合成账号与 mock 开关，不导出 storage / 凭证。报告写 /tmp。
"""
import importlib.util, json, re
from pathlib import Path
spec = importlib.util.spec_from_file_location('native', Path(__file__).with_name('wish-writing.e2e.py'))
a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a)
a.REPORT = Path('/tmp/cgc-flashback-event-auth-report.json')
E = 'flashback-event'
KEY = '2014-01-11-bj'
URL = '/pages/' + E + '/index?key=' + KEY
css = (a.PROJECT/'dist/weapp/common.wxss').read_text() + (a.PROJECT/'dist/weapp/pages'/E/'index.wxss').read_text()
def cls(name):
    values = set(re.findall(r'\.[\w-]+__' + re.escape(name) + r'___[\w-]+', css)); assert len(values) == 1, (name, values); return values.pop()
def count(name): return a.evaluate('return new Promise(resolve=>wx.createSelectorQuery().selectAll(' + json.dumps(cls(name)) + ').boundingClientRect().exec(r=>resolve(r[0].length)))')
def text(name): return a.call('automation_element_action', selector=cls(name), action='text')
def route(): return a.evaluate('return getCurrentPages().slice(-1)[0].route')
def flag(values):
    a.evaluate(''.join('wx.setStorageSync(' + json.dumps('cgc.e2e.' + k) + ',' + json.dumps(v) + ');' for k, v in values.items()) + 'return true')
def sign_out():
    a.evaluate('wx.removeStorageSync("cgc.flashback_token"); return true')
    a.call('automation_navigate', action='reLaunch', url='/pages/profile/index')
    if a.evaluate('return new Promise(resolve=>wx.createSelectorQuery().selectAll(' + json.dumps(a.cls('profile', 'logout')) + ').boundingClientRect().exec(r=>resolve(r[0].length)))'):
        a.tap('profile', 'logout')

LOGIN_GUIDE = '你也在这一场吗？登录后我们帮你找你的那一张。'
LOGIN_CTA = '微信一键登录，找回你的那一张 →'
if __name__ == '__main__':
    flag({'flashback_unclaimed': '0', 'flashback_claim_miss': '0', 'flashback_claim_fail': '0', 'flashback_recovery_fail_after_claim': '0', 'flashback_capsule_fail_next': '0'})
    sign_out()
    a.call('automation_navigate', action='reLaunch', url=URL)
    a.check('未登录深链进场次页给登录引导而非错误页', count('guideText') == 1 and text('guideText') == LOGIN_GUIDE)
    a.check('未登录只有一个登录入口', count('cta') == 1 and text('cta') == LOGIN_CTA)

    # 已登录、库内未匹配：登录一次后，场次页不得再索要登录
    flag({'flashback_unclaimed': '1', 'flashback_claim_miss': '1'})
    a.call('automation_element_action', selector=cls('cta'), action='tap')
    a.check('点登录入口进入登录页', route() == 'pages/login/index')
    a.tap('login', 'loginButton'); a.tap('login', 'dialogPrimary')
    a.check('登录后回到同一场次页', route() == 'pages/' + E + '/index')
    a.check('已登录未匹配不再出现登录引导', count('guideText') == 1 and text('guideText') != LOGIN_GUIDE)
    a.check('已登录未匹配没有任何登录按钮（死循环入口已移除）', count('cta') == 0)
    a.call('automation_navigate', action='reLaunch', url=URL)
    a.check('重进场次页仍不索要登录', count('cta') == 0 and text('guideText') != LOGIN_GUIDE)

    # 匹配请求失败 ≠ 未匹配 ≠ 未登录：落可重试错误态
    flag({'flashback_claim_miss': '0', 'flashback_claim_fail': '1'})
    a.call('automation_navigate', action='reLaunch', url=URL)
    a.check('匹配请求失败落可重试错误态而非登录引导', count('retry') == 1 and count('guideText') == 0)
    flag({'flashback_claim_fail': '0'})
    a.call('automation_element_action', selector=cls('retry'), action='tap')
    a.check('重试后自动认领进入本场名册', count('cell') == 6)
    a.check('参与态找回 CTA 是回长廊而非登录', text('cta') == '你也在这一场？找回你的那一张 →')

    flag({'flashback_unclaimed': '0', 'flashback_claim_miss': '0'})
    print('Completed ' + str(len(a.checks)) + ' native checks. ' + str(a.REPORT), flush=True)
