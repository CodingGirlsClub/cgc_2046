#!/usr/bin/env python3
# CGC_E2E_MOCK=true 构建（复用 wish-writing 的 mock transport）。
"""3B native share landing acceptance; synthetic mock build, no actual chat sends.
Cold entry uses DevTools compilation. Warm entry invokes the real App onShow.
"""
import importlib.util, json, time
from pathlib import Path
spec = importlib.util.spec_from_file_location('native', Path(__file__).with_name('wish-writing.e2e.py'))
a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a)
a.REPORT = Path('/tmp/cgc-3b-native-report.json')
V = 'flashback-voices'; W = 'flashback-wishes'
def route(page): return 'pages/' + page + '/index'
def stack(): return a.evaluate('return getCurrentPages().map(p=>({route:p.route,options:p.options}))')
def share(scope):
    return a.evaluate('return getCurrentPages().slice(-1)[0].onShareAppMessage('+json.dumps({'from':'button','target':{'dataset':{'scope':scope}}})+')')
def warm(page, query):
    a.evaluate('getApp().onShow('+json.dumps({'path':route(page),'query':query,'scene':1007})+');return true')
def cold(page, query=''):
    a.call('simulator_open_page', page=route(page), query=query, scene=1007)
    time.sleep(2)
def current(page, text): return a.element(page, 'quote' if page == V else 'content') == text
def logout():
    a.call('automation_navigate',action='switchTab',url='/pages/profile/index')
    selector=a.cls('profile','logout')
    found=a.evaluate('return new Promise(r=>wx.createSelectorQuery().selectAll('+json.dumps(selector)+').boundingClientRect().exec(v=>r(v[0].length)))')
    if found: a.tap('profile','logout')
if __name__ == '__main__':
    logout()
    # A recompiled mock has no server session. Remove only its synthetic auth cache.
    a.evaluate('wx.removeStorageSync("cgc.auth_token");wx.removeStorageSync("cgc.active_user_id");return true')
    for page, key, first, second, scope, whole, expected in [
        (V,'quoteId','voice-beijing','voice-quiet','quote','wall','学会的第一件事，是允许自己从零开始。'),
        (W,'wishId','w-2','w-1','wish','tree','一起出一本书:《她们的第一行代码》')
    ]:
        cold(page,key+'='+first)
        a.check(page+' 冷启动不叠重复页',len(stack())==1 and stack()[0]['options'].get(key)==first)
        payload=share(scope)
        a.check(page+' 单条分享只带公开定位',payload['path']=='/'+route(page)+'?'+key+'='+first and bool(payload['title']) and bool(payload['imageUrl']))
        a.check(page+' 整体分享不夹带定位',share(whole)['path']=='/'+route(page))
        warm(page,{key:second})
        a.check(page+' 热启动切换到指定内容',current(page,expected) and stack()[-1]['options'].get(key)==second)
        before=len(stack());warm(page,{key:second})
        a.check(page+' 相同分享不重复入栈',len(stack())==before)
        warm(page,{})
        a.check(page+' 整体热入口清除旧定位',not stack()[-1]['options'].get(key))
        a.call('automation_navigate',action='reLaunch',url='/'+route(page)+'?'+key+'=withdrawn-fixture')
        a.check(page+' 撤回链接明确告知',('收回' in a.element(page,'stateTitle')) if page==V else ('无法查看' in a.element(page,'stateTitle')))
        a.check(page+' 撤回后不再分享旧内容',share(scope)['path']=='/'+route(page))
        a.tap(page,'primary' if page==V else 'allTree')
        a.check(page+' 撤回后仍可继续浏览',bool(a.element(page,'quote' if page==V else 'content')))
    a.call('automation_navigate',action='reLaunch',url='/'+route(W)+'?wishId=w-1')
    a.tap(W,'contribute')
    a.check('公开愿望出力才要求登录',stack()[-1]['route']=='pages/login/index')
    a.call('automation_navigate',action='navigateBack')
    a.check('取消登录仍回到原愿望',current(W,'一起出一本书:《她们的第一行代码》'))
    a.tap(W,'contribute');a.tap('login','loginButton');a.tap('login','dialogPrimary')
    a.check('登录成功回原分享愿望',current(W,'一起出一本书:《她们的第一行代码》') and stack()[-1]['options']['wishId']=='w-1')
    logout()
    a.call('automation_navigate',action='reLaunch',url='/'+route(V)+'?quoteId=voice-beijing')
    a.tap(V,'future');a.tap(W,'writeWish')
    a.check('访客由金句到许愿树后可直接写愿望',a.element('flashback-wish-write','title')=='写下我的愿望')
    a.call('automation_navigate',action='navigateBack')
    print('Completed '+str(len(a.checks))+' native checks. '+str(a.REPORT),flush=True)
