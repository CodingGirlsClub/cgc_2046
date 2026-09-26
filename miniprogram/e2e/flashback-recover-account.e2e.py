#!/usr/bin/env python3
"""#932 小程序内找回·邮箱（CGC_E2E_MOCK=true 构建 + WeChatIDE 模拟器）。

已登录但没匹配到档案（当年用别的号码报名）：闪念间首页「用当年报名的邮箱找回」→ 手机号不开放
（就地提示填邮箱，不发起）→ 邮箱发找回邮件 → 找回邮件里的链接贴回来 → 认不出的链接 / 别人的
档案各有明确提示（不合并）→ 已收到邮件可直接贴链接 → 绑到当前账号 → 长廊进入参与态。
mock 约定：链接里取 fb_ token，fb_other… = 档案属于另一个账号，用过的 token 再贴 = 已用过。
合成数据，不导出 storage / 凭证。报告写 /tmp。
"""
import importlib.util, json, time
from pathlib import Path
spec = importlib.util.spec_from_file_location('native', Path(__file__).with_name('wish-writing.e2e.py'))
a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a)
a.REPORT = Path('/tmp/cgc-flashback-recover-account-report.json')
C = 'flashback-corridor'
# 每次运行换一个 token：mock 的已认领集合是模块态，同一会话重跑不互相污染
LINK = 'https://example.com/zh-CN/flashback/enter?token=fb_e2e_recover_' + str(int(time.time()))
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
    flag({'flashback_unclaimed': '1', 'flashback_claim_miss': '1', 'flashback_claim_fail': '0', 'flashback_recovery_fail_after_claim': '0', 'platform_identity': '0'})
    a.evaluate('wx.removeStorageSync("cgc.flashback_token"); return true')
    a.call('automation_navigate', action='reLaunch', url='/pages/login/index')
    a.tap('login', 'loginButton'); time.sleep(0.8); a.tap('login', 'dialogPrimary'); time.sleep(1.5)
    corridor()
    a.check('已登录未匹配：首页给出邮箱找回入口（不提手机号）', text('recoveryTitle') == '暂时还没找到你的那一张' and text('recoverOther') == '没找到？用当年报名的邮箱找回 →')

    open_sheet()
    a.check('打开找回面板：只要邮箱', count('recoverSheet') == 1 and '手机' not in text('recoverBody'))
    fill('recoverInput', '13900000011'); tap('recoverSubmit'); time.sleep(1)
    a.check('手机号不开放：就地提示填邮箱，停在这一步（不发码、不出验证码框）', text('recoverError') == '请填写当年报名用的邮箱。' and count('recoverCodeInput') == 0 and count('recoverInput') == 1)

    fill('recoverInput', 'old@example.com'); tap('recoverSubmit'); time.sleep(1)
    a.check('邮箱：同形提示已发找回邮件，进入贴链接这步（不要验证码）', count('recoverCodeInput') == 0 and count('recoverLinkInput') == 1 and '找回邮件已经发出' in text('recoverBody'))
    fill('recoverLinkInput', '随便一段话'); tap('recoverSubmit'); time.sleep(1)
    a.check('认不出的链接：中文提示去复制完整链接', text('recoverError') == '没认出这条链接。请复制找回邮件里的完整链接再粘贴。')
    fill('recoverLinkInput', 'https://example.com/flashback/enter?token=fb_other_account'); tap('recoverSubmit'); time.sleep(1)
    a.check('档案已属于另一个账号：明确提示，不合并', '另一个账号' in text('recoverError'))
    tap('recoverCancel'); time.sleep(0.5)
    a.check('关闭面板', count('recoverSheet') == 0)

    # 已收到邮件（比如切出去看邮件后小程序被回收）：不必再发一封，直接贴链接
    open_sheet()
    tap('recoverPasteEntry'); time.sleep(0.5)
    a.check('已收到邮件：直接进贴链接这步', count('recoverLinkInput') == 1 and text('recoverBody') == '打开找回邮件，复制里面的链接，粘贴到下面。')
    fill('recoverLinkInput', '邮件里的链接：' + LINK); tap('recoverSubmit'); time.sleep(1)
    a.check('贴对链接：绑到当前账号', text('recoverBody') == '找到了你的 1 张卡，已经绑到你现在登录的账号。')
    tap('recoverSubmit'); time.sleep(2.5)
    if count('shutterBtn'): tap('shutterBtn')
    a.check('长廊进入参与态（个人卡在，公开首页消失）', count('cardDock') == 1 and count('recoveryTitle') == 0)

    flag({'flashback_unclaimed': '0', 'flashback_claim_miss': '0'})
    print('Completed ' + str(len(a.checks)) + ' native checks. ' + str(a.REPORT), flush=True)
