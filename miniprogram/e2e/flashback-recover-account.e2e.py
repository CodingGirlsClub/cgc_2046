#!/usr/bin/env python3
"""#932 小程序内找回（CGC_E2E_MOCK=true 构建 + WeChatIDE 模拟器）。

已登录但没匹配到档案（当年用别的号码报名）：闪念间首页「当年用的是别的手机号或邮箱？」→
邮箱走找回邮件说明；手机号发码 → 错码提示 → 号码属于另一个账号明确提示（不合并）→
正确验证码绑到当前账号 → 长廊进入参与态。mock 约定：码 123456 通过，13900000099 = 别人的号码。
合成数据，不导出 storage / 凭证。报告写 /tmp。
"""
import importlib.util, json, time
from pathlib import Path
spec = importlib.util.spec_from_file_location('native', Path(__file__).with_name('wish-writing.e2e.py'))
a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a)
a.REPORT = Path('/tmp/cgc-flashback-recover-account-report.json')
C = 'flashback-corridor'
# FlashbackGuest / FlashbackRecover 只被长廊引用：样式打进长廊页 wxss
def count(name):
    return a.evaluate('return new Promise(r=>wx.createSelectorQuery().selectAll(' + json.dumps(a.cls(C, name)) + ').boundingClientRect().exec(x=>r(x[0].length)))')
def text(name): return a.call('automation_element_action', selector=a.cls(C, name), action='text')
def tap(name): return a.call('automation_element_action', selector=a.cls(C, name), action='tap')
def fill(name, value): return a.call('automation_element_action', selector=a.cls(C, name), action='input', value=value)
def flag(values): a.evaluate(''.join('wx.setStorageSync(' + json.dumps('cgc.e2e.' + k) + ',' + json.dumps(v) + ');' for k, v in values.items()) + 'return true')
def corridor():
    a.call('automation_navigate', action='reLaunch', url='/pages/' + C + '/index'); time.sleep(2)
def open_sheet():
    tap('recoverOther'); time.sleep(0.8)

if __name__ == '__main__':
    # 已登录、库内未匹配
    flag({'flashback_unclaimed': '1', 'flashback_claim_miss': '1', 'flashback_claim_fail': '0', 'flashback_recovery_fail_after_claim': '0'})
    a.evaluate('wx.removeStorageSync("cgc.flashback_token"); return true')
    a.call('automation_navigate', action='reLaunch', url='/pages/login/index')
    a.tap('login', 'loginButton'); a.tap('login', 'dialogPrimary'); time.sleep(1.5)
    corridor()
    a.check('已登录未匹配：首页给出「别的号码找回」入口', text('recoveryTitle') == '暂时还没找到你的那一张' and text('recoverOther') == '当年用的是别的手机号或邮箱？在这里找回 →')

    open_sheet()
    a.check('打开找回面板', count('recoverSheet') == 1)
    fill('recoverInput', 'old@example.com'); tap('recoverSubmit'); time.sleep(1)
    a.check('邮箱：不要验证码，说明去邮件里的网页入口收好（同形返回，不泄露有没有档案）', count('recoverCodeInput') == 0 and '找回邮件已经发出' in text('recoverBody'))
    tap('recoverCancel'); time.sleep(0.5)
    a.check('关闭面板', count('recoverSheet') == 0)

    open_sheet()
    fill('recoverInput', '13900000099'); tap('recoverSubmit'); time.sleep(1)
    a.check('手机号：进入验证码步骤', count('recoverCodeInput') == 1)
    fill('recoverCodeInput', '123456'); tap('recoverSubmit'); time.sleep(1)
    a.check('号码已属于另一个账号：明确提示，不合并', '另一个账号' in text('recoverError'))
    tap('recoverCancel'); time.sleep(0.5)

    open_sheet()
    fill('recoverInput', '13900000011'); tap('recoverSubmit'); time.sleep(1)
    fill('recoverCodeInput', '000000'); tap('recoverSubmit'); time.sleep(1)
    a.check('错码：中文提示', text('recoverError') == '验证码不对或已过期，请重试。')
    fill('recoverCodeInput', '123456'); tap('recoverSubmit'); time.sleep(1)
    a.check('验证通过：绑到当前账号', text('recoverBody') == '找到了你的 1 张卡，已经绑到你现在登录的账号。')
    tap('recoverSubmit'); time.sleep(2.5)
    if count('shutterBtn'): tap('shutterBtn')
    a.check('长廊进入参与态（个人卡在，公开首页消失）', count('cardDock') == 1 and count('recoveryTitle') == 0)

    flag({'flashback_unclaimed': '0', 'flashback_claim_miss': '0'})
    print('Completed ' + str(len(a.checks)) + ' native checks. ' + str(a.REPORT), flush=True)
