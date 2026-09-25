#!/usr/bin/env python3
"""2B native checks against a CGC_E2E_MOCK=true build. No screenshots or sends.
Run: python e2e/wish-tree.e2e.py (fresh, signed-out simulator session).
The existing mock wish w-1 is the public share fixture; pw-1 is private.
"""
import importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location('wish_acceptance', Path(__file__).with_name('wish-writing.e2e.py'))
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)
a.REPORT = Path('/tmp/cgc-wishes-2b-native-report.json')
P='flashback-wishes'
def common(name):
    css=(a.PROJECT/'dist/weapp/common.wxss').read_text()
    values=set(a.re.findall(r'\.[\w-]+__'+name+r'___[\w-]+',css))
    assert len(values)==1,(name,values)
    return values.pop()
def tap_common(name): return a.call('automation_element_action',selector=common(name),action='tap')
if __name__=='__main__':
    # Reset the dedicated mock fixture only; real wishes and drafts are untouched.
    a.evaluate('wx.removeStorageSync("cgc.e2e.flashback_mock_state");return true')
    a.call('automation_navigate',action='reLaunch',url='/pages/flashback-wishes/index?wishId=w-1')
    a.check('公开分享直达指定愿望',a.element(P,'content')=='一起出一本书:《她们的第一行代码》')
    a.check('单愿分享指向独立页',a.evaluate('return getCurrentPages().slice(-1)[0].onShareAppMessage({from:"button",target:{dataset:{scope:"wish"}}}).path')=='/pages/flashback-wishes/index?wishId=w-1')
    a.check('整树分享不带单条 id',a.evaluate('return getCurrentPages().slice(-1)[0].onShareAppMessage({from:"button",target:{dataset:{scope:"tree"}}}).path')=='/pages/flashback-wishes/index')
    a.tap(P,'expect')
    a.check('匿名期待无需登录',a.element(P,'expect')=='已期待 · 取消')
    a.tap(P,'expect')
    a.check('期待可取消',a.element(P,'expect')=='我也期待')
    a.tap(P,'next')
    a.check('逐条浏览切换内容',a.element(P,'content')=='开一门 Rust 系统课')
    a.tap(P,'echoFilter')
    a.check('回响筛选仍展示有效愿望',bool(a.element(P,'content')))
    a.call('automation_navigate',action='reLaunch',url='/pages/flashback-wishes/index?city=深圳')
    a.check('无内容城市显示空态',a.element(P,'stateTitle')=='这里，等着新的愿望。')
    a.call('automation_navigate',action='reLaunch',url='/pages/flashback-wishes/index?wishId=pw-1')
    a.check('私密分享不泄露正文',a.element(P,'stateTitle')=='这个愿望，目前无法查看。')
    a.call('automation_navigate',action='reLaunch',url='/pages/flashback-wishes/index?city=北京')
    a.tap(P,'voicesTab')
    a.check('切到金句墙保留城市',a.call('automation_element_action',selector=common('activeChip'),action='text')=='北京')
    a.tap('flashback-voices','wishesTab')
    a.check('切回许愿树保留城市',a.call('automation_element_action',selector=common('activeChip'),action='text')=='北京')
    a.tap(P,'contribute')
    a.check('出力先登录',a.evaluate('return getCurrentPages().slice(-1)[0].route')=='pages/login/index')
    a.tap('login','loginButton');a.tap('login','dialogPrimary')
    a.check('登录回到同一愿望',a.element(P,'content')=='一起出一本书:《她们的第一行代码》')
    a.tap(P,'contribute');tap_common('endorseChip');tap_common('endorseNotify');tap_common('endorseSubmit')
    a.check('现有出力流程在独立树中可用',a.element(P,'contribute')=='已出力 · 取消')
    a.tap(P,'writeWish')
    a.check('写愿望入口接入 2A',a.element('flashback-wish-write','title')=='写下我的愿望')
    print(f'Completed {len(a.checks)} native checks. {a.REPORT}',flush=True)
