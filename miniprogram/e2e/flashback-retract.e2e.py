#!/usr/bin/env python3
"""#931 撤下与删除档案 + #933 相册开放告知（CGC_E2E_MOCK=true 构建 + 已登录的 WeChatIDE 模拟器）。

登录账号（会话腿，无 token）：长廊寄出 → 卡片页撤下（系统确认框 mock 为确认）→
撤下入口消失 → 相册开放告知只对「开放前就寄出」的人出现一次 →
删除档案两步确认（错词不提交、DELETE 才提交）→ 终态 → 回长廊落「没找到」。
合成数据，不导出 storage / 凭证。报告写 /tmp。
"""
import importlib.util, json, re, time
from pathlib import Path
spec = importlib.util.spec_from_file_location('native', Path(__file__).with_name('wish-writing.e2e.py'))
a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a)
a.REPORT = Path('/tmp/cgc-flashback-retract-report.json')
TODAY, COR = 'flashback-today', 'flashback-corridor'
# 只被一个页面引用的组件，样式会打进该页 wxss 而非 common.wxss——三处合并查
common = ''.join((a.PROJECT/'dist/weapp'/f).read_text() for f in ['common.wxss', 'pages/flashback-today/index.wxss', 'pages/flashback-corridor/index.wxss'])
def page_cls(page, name): return a.cls(page, name)
def comp_cls(name):
    values = set(re.findall(r'\.index-module__' + re.escape(name) + r'___[\w-]+', common)); assert len(values) == 1, (name, values); return values.pop()
def count(sel): return a.evaluate('return new Promise(r=>wx.createSelectorQuery().selectAll(' + json.dumps(sel) + ').boundingClientRect().exec(x=>r(x[0].length)))')
def text(sel): return a.call('automation_element_action', selector=sel, action='text')
def tap(sel): return a.call('automation_element_action', selector=sel, action='tap')
def route(): return a.evaluate('return getCurrentPages().slice(-1)[0].route')
def corridor():
    a.call('automation_navigate', action='reLaunch', url='/pages/' + COR + '/index'); time.sleep(2)
    shutter = page_cls(COR, 'shutterBtn')
    if count(shutter): tap(shutter)
def forget_notice(): a.evaluate('wx.removeStorageSync("cgc.flashback_album_notice_done"); return true')
def flag(values): a.evaluate(''.join('wx.setStorageSync(' + json.dumps('cgc.e2e.' + k) + ',' + json.dumps(v) + ');' for k, v in values.items()) + 'return true')

if __name__ == '__main__':
    flag({'flashback_unclaimed': '0', 'flashback_claim_miss': '0', 'flashback_claim_fail': '0'})
    a.evaluate('wx.removeStorageSync("cgc.flashback_token"); return true')
    a.call('automation_navigate', action='reLaunch', url='/pages/login/index')
    a.tap('login', 'loginButton'); a.tap('login', 'dialogPrimary'); time.sleep(1.5)

    # 登录账号（无 token）寄出：修复前后端只认 token，这一步在真后端必然失败
    a.call('automation_navigate', action='reLaunch', url='/pages/' + COR + '/index'); time.sleep(2)
    shutter = page_cls(COR, 'shutterBtn')
    if count(shutter): tap(shutter)
    tap(page_cls(COR, 'dockSend')); time.sleep(1.5)
    a.call('automation_navigate', action='reLaunch', url='/pages/' + TODAY + '/index'); time.sleep(1.5)
    retract, delete = page_cls(TODAY, 'retractLink'), page_cls(TODAY, 'deleteLink')
    a.check('已寄出 → 卡片页出现「撤下这张卡」', count(retract) == 1 and text(retract) == '撤下这张卡')
    a.check('删除入口始终可达', count(delete) == 1 and text(delete) == '删除我的档案')

    a.call('automation_wx_api', action='mock', method='showModal', result='{"confirm":true,"cancel":false}')
    try: tap(retract); time.sleep(1.5)
    finally: a.call('automation_wx_api', action='restore', method='showModal')
    a.check('确认撤下后撤下入口消失（回到未寄出态）', count(retract) == 0)

    # #933 一次性告知：此时已撤下 = 未寄出
    notice = page_cls(COR, 'albumNotice')
    forget_notice(); corridor()
    a.check('未寄出进长廊 → 没有相册开放告知', count(notice) == 0)
    tap(page_cls(COR, 'dockSend')); time.sleep(1.5)
    a.check('本次寄出后也不告知（寄出前已读到新的可见范围文案）', count(notice) == 0)
    forget_notice(); corridor()
    a.check('开放前就寄出（已寄出且未告知）→ 长廊出现告知', count(notice) == 1 and '登录的人' in text(page_cls(COR, 'albumNoticeText')))
    tap(page_cls(COR, 'albumNoticeOk')); time.sleep(0.5)
    a.check('点「知道了」告知消失', count(notice) == 0)
    corridor()
    a.check('再回长廊不再出现（一次性）', count(notice) == 0)
    a.call('automation_navigate', action='reLaunch', url='/pages/' + TODAY + '/index'); time.sleep(1.5)

    tap(delete); time.sleep(1.2)
    sheet, submit, box = comp_cls('deleteSheet'), comp_cls('deleteSubmit'), comp_cls('deleteInput')
    a.check('删除面板打开', count(sheet) == 1)
    facts = comp_cls('deleteFact')
    a.check('摘要列出档案名', count(facts) == 2 and '档案：王小明' in text(facts))
    a.call('automation_element_action', selector=box, action='input', value='delete'); tap(submit); time.sleep(1)
    a.check('确认词不对（小写）不提交', count(sheet) == 1 and text(comp_cls('deleteTitle')) == '删除我的档案')
    a.call('automation_element_action', selector=box, action='input', value='DELETE'); tap(submit); time.sleep(1.5)
    a.check('DELETE 提交后进入终态', text(comp_cls('deleteTitle')) == '你的档案已清除')
    tap(comp_cls('deleteBack')); time.sleep(2.5)
    a.check('回到闪念间 Tab', route() == 'pages/' + COR + '/index')
    title = comp_cls('recoveryTitle')
    a.check('档案已删除 → 长廊落「没找到」', count(title) == 1 and text(title) == '暂时还没找到你的那一张')

    flag({'flashback_unclaimed': '0', 'flashback_claim_miss': '0'})
    print('Completed ' + str(len(a.checks)) + ' native checks. ' + str(a.REPORT), flush=True)
