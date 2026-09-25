#!/usr/bin/env python3
"""3A recovery acceptance in a fresh signed-out CGC_E2E_MOCK=true simulator.
Uses synthetic accounts and fault flags only. No screenshots or notifications.
"""
import importlib.util, json, re
from pathlib import Path
spec=importlib.util.spec_from_file_location('native',Path(__file__).with_name('wish-writing.e2e.py'))
a=importlib.util.module_from_spec(spec);spec.loader.exec_module(a)
a.REPORT=Path('/tmp/cgc-recover-3a-native-report.json')
C='flashback-corridor'
css=(a.PROJECT/'dist/weapp/common.wxss').read_text()+(a.PROJECT/'dist/weapp/pages'/C/'index.wxss').read_text()
def cls(name):
 values=set(re.findall(r'\.[\w-]+__'+re.escape(name)+r'___[\w-]+',css));assert len(values)==1,(name,values);return values.pop()
def text(name): return a.call('automation_element_action',selector=cls(name),action='text')
def tap(name): return a.call('automation_element_action',selector=cls(name),action='tap')
def count(name): return a.evaluate('return new Promise(resolve=>wx.createSelectorQuery().selectAll('+json.dumps(cls(name))+').boundingClientRect().exec(r=>resolve(r[0].length)))')
def flag(values):
 a.evaluate(''.join('wx.setStorageSync('+json.dumps('cgc.e2e.'+key)+','+json.dumps(value)+');' for key,value in values.items())+'return true')
def return_to_corridor():
 a.call('automation_navigate',action='switchTab',url='/pages/discover/index')
 a.call('automation_navigate',action='switchTab',url='/pages/'+C+'/index')
def login():
 tap('recoverButton');a.tap('login','loginButton');a.tap('login','dialogPrimary')
def dismiss_shutter():
 if count('shutterBtn'): tap('shutterBtn')
if __name__=='__main__':
 a.call('automation_navigate',action='reLaunch',url='/pages/'+C+'/index')
 a.check('未登录保留找回入口',text('recoverButton')=='找回你的那一张 →')
 tap('recoverButton');a.call('automation_navigate',action='navigateBack')
 a.check('取消登录回公开首页',text('recoveryTitle')=='你也在那些年里吗？')
 flag({'flashback_unclaimed':'1','flashback_claim_miss':'1','flashback_claim_fail':'0','flashback_recovery_fail_after_claim':'0','flashback_capsule_fail_next':'0'})
 login()
 a.check('登录未匹配给出准确说明',text('recoveryTitle')=='暂时还没找到你的那一张')
 a.check('未匹配提供写愿望而非重复登录',text('recoverButton')=='写下我的愿望 →')
 a.check('无档案仍能浏览公开金句',count('quoteOpen')==1 and count('cardDock')==0)
 tap('recoverButton')
 a.check('无档案账号可直接写愿望',a.element('flashback-wish-write','title')=='写下我的愿望')
 a.call('automation_navigate',action='navigateBack')
 flag({'flashback_claim_miss':'0','flashback_claim_fail':'1'})
 return_to_corridor()
 a.check('匹配请求失败与未匹配区分',text('recoveryTitle')=='暂时没能完成查找')
 tap('recoverButton')
 a.check('重试仍失败时保留可重试状态',text('recoverButton')=='重新查找 ↻')
 flag({'flashback_claim_fail':'0','flashback_recovery_fail_after_claim':'1'})
 tap('recoverButton')
 a.check('认领成功但读取失败仍是错误态',text('recoveryTitle')=='暂时没能完成查找')
 tap('recoverButton');dismiss_shutter()
 a.check('读取重试成功进入个人长廊',text('miniCardName')=='王小明')
 return_to_corridor()
 a.check('同一账号返回不重复播放快门',count('shutterBtn')==0)
 a.check('已绑定账号回访进入原长廊',count('cardDock')==1 and count('guestPage')==0)
 a.tap(C,'cityPin')
 a.check('同账号切换城市不重复快门',count('shutterBtn')==0 and count('cardDock')==1)
 a.call('automation_navigate',action='switchTab',url='/pages/profile/index');a.tap('profile','logout')
 a.call('automation_navigate',action='switchTab',url='/pages/'+C+'/index')
 a.check('退出后没有旧个人卡和私密弹层',count('cardDock')==0 and count('wishModal')==0 and text('recoverButton')=='找回你的那一张 →')
 flag({'flashback_unclaimed':'1','flashback_claim_miss':'0'})
 login();dismiss_shutter()
 a.check('首次自动匹配并认领后进入长廊',text('miniCardName')=='王小明')
 # Leave the newly designed signed-in, unmatched state for owner acceptance.
 flag({'flashback_unclaimed':'1','flashback_claim_miss':'1'})
 return_to_corridor()
 a.check('验收窗口停在已登录未匹配首页',text('recoveryTitle')=='暂时还没找到你的那一张')
 print('Completed '+str(len(a.checks))+' native checks. '+str(a.REPORT),flush=True)
