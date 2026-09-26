#!/usr/bin/env python3
# CGC_E2E_MOCK=true 构建（复用 wish-writing 的 mock transport）。
"""3C WeChatIDE acceptance. Mock consent outcomes, real UI lifecycle/navigation.
No real authorization or outgoing notifications. Backend publish/provider leg is
covered by WishEchoesTest against the isolated database and captured HTTP client.
"""
import importlib.util, json, re, time
from pathlib import Path
spec=importlib.util.spec_from_file_location('native',Path(__file__).with_name('wish-writing.e2e.py'))
a=importlib.util.module_from_spec(spec);spec.loader.exec_module(a)
a.REPORT=Path('/tmp/cgc-3c-native-report.json')
W='flashback-wishes'
def cls(name):
    css=(a.PROJECT/'dist/weapp/pages'/W/'index.wxss').read_text()+(a.PROJECT/'dist/weapp/common.wxss').read_text()
    matches=set(re.findall(r'\.[\w-]+__'+re.escape(name)+r'___[\w-]+',css))
    assert len(matches)==1,(name,matches)
    return matches.pop()
def text(name): return a.call('automation_element_action',selector=cls(name),action='text')
def tap(name): return a.call('automation_element_action',selector=cls(name),action='tap')
def count(name): return a.evaluate('return new Promise(r=>wx.createSelectorQuery().selectAll('+json.dumps(cls(name))+').boundingClientRect().exec(v=>r(v[0].length)))')
def flags(mode):
    a.evaluate('wx.setStorageSync("cgc.e2e.wish-reminder-result",'+json.dumps(mode)+');wx.setStorageSync("cgc.e2e.wish_reminder_grant_fail",'+json.dumps('1' if mode=='grant-error' else '0')+');return true')
def open_form():
    a.call('automation_navigate',action='reLaunch',url='/pages/'+W+'/index?wishId=w-1')
    if '已出力' in a.element(W,'contribute'):
        a.call('automation_wx_api',action='mock',method='showModal',result='{"confirm":true,"cancel":false}')
        try: a.tap(W,'contribute')
        finally: a.call('automation_wx_api',action='restore',method='showModal')
    a.tap(W,'contribute')
    if a.evaluate('return getCurrentPages().slice(-1)[0].route')=='pages/login/index':
        a.tap('login','loginButton');a.tap('login','dialogPrimary');a.tap(W,'contribute')
    tap('endorseChip')
if __name__=='__main__':
    a.evaluate('wx.removeStorageSync("cgc.auth_token");return true')
    a.call('simulator_open_page',page='pages/'+W+'/index',query='wishId=w-1')
    time.sleep(2)
    # Snapshot only synthetic content, never export credentials or account storage.
    a.evaluate('globalThis.__echoTestBackup=wx.getStorageSync("cgc.e2e.flashback_mock_state");wx.removeStorageSync("cgc.e2e.flashback_mock_state");return true')
    try:
        for mode, copy in [('accepted','订阅授权已记录'),('off','未开启提醒'),('denied','暂未授权'),('error','提醒未能开启'),('grant-error','提醒未能开启')]:
            flags(mode);open_form()
            if mode=='off': tap('endorseNotify')
            tap('endorseSubmit')
            a.check(mode+' 出力保存并准确反馈提醒结果',copy in text('receiptCopy') and '出力已保存' in text('receiptCopy'))
            a.check(mode+' 保存后不能重复提交',count('endorseSubmit')==0)
            if mode in ['denied','error','grant-error']:
                a.check(mode+' 提供单独重试订阅',count('reminderRetry')==1)
                flags('accepted');tap('reminderRetry')
                a.check(mode+' 重试后可完成且不重复出力','订阅授权已记录' in text('receiptCopy') and a.evaluate('var s=JSON.parse(wx.getStorageSync("cgc.e2e.flashback_mock_state"));return s.endorsedWishIds.filter(x=>x==="w-1").length===1'))
            else: a.check(mode+' 不多次询问授权',count('reminderRetry')==0)
            tap('receiptDone')
            a.check(mode+' 完成后页面显示已出力','已出力' in a.element(W,'contribute'))
        a.call('automation_navigate',action='switchTab',url='/pages/discover/index')
        a.evaluate('getApp().onShow({path:"pages/flashback-wishes/index",query:{wishId:"w-1"},scene:1014});return true')
        a.check('通知入口直达对应愿望',a.element(W,'content')=='一起出一本书:《她们的第一行代码》')
        a.check('落页显示最新已更正回响','签约了' in text('echoBody') and count('correctedBadge')==1)
        tap('toggleRow');a.check('可展开查看历次回响',count('echoBody')==2)
        a.evaluate('var k="cgc.e2e.flashback_mock_state",s=JSON.parse(wx.getStorageSync(k));s.wishes.find(w=>w.id==="w-1").echoes.forEach(e=>e.status="revoked");wx.setStorageSync(k,JSON.stringify(s));return true')
        a.call('automation_navigate',action='reLaunch',url='/pages/'+W+'/index?wishId=w-1')
        a.check('重进后不展示已撤回回响',count('echoBody')==0)
    finally:
        a.evaluate('var k="cgc.e2e.flashback_mock_state";if(globalThis.__echoTestBackup)wx.setStorageSync(k,globalThis.__echoTestBackup);else wx.removeStorageSync(k);delete globalThis.__echoTestBackup;wx.removeStorageSync("cgc.e2e.wish-reminder-result");wx.removeStorageSync("cgc.e2e.wish_reminder_grant_fail");return true')
    a.call('automation_navigate',action='reLaunch',url='/pages/'+W+'/index?wishId=w-1')
    print('Completed '+str(len(a.checks))+' native checks. '+str(a.REPORT),flush=True)
