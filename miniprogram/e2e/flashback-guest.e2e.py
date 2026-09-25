#!/usr/bin/env python3
"""Visitor landing checks against WeChatIDE and a real backend.
Run signed out after building weapp, with at least two distinct public quotes. Does not capture screenshots or credentials.
"""
import importlib.util,json,re
from pathlib import Path
base=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('native',base/'e2e/wish-writing.e2e.py');a=importlib.util.module_from_spec(spec);spec.loader.exec_module(a)
css=(base/'dist/weapp/common.wxss').read_text()+(base/'dist/weapp/pages/flashback-corridor/index.wxss').read_text()
def cls(name):
 matches=set(re.findall(r'\.[\w-]+__'+name+r'___[\w-]+',css));assert len(matches)==1,(name,matches);return matches.pop()
a.call('automation_navigate',action='switchTab',url='/pages/flashback-corridor/index')
body=a.call('automation_element_action',selector=cls('guestPage'),action='text')
assert '有些话，' in body and '找回你的那一张' in body and '未来 · 许愿树' not in body,body
for entry,target in [('voicesPortal','pages/flashback-voices/index'),('wishesPortal','pages/flashback-wishes/index'),('recoverButton','pages/login/index')]:
 a.call('automation_element_action',selector=cls(entry),action='tap')
 assert a.evaluate('return getCurrentPages().slice(-1)[0].route')==target
 a.call('automation_navigate',action='navigateBack')
 print('PASS '+entry,flush=True)
selectors=[cls(x) for x in ['guestPage','quoteCard','portals','voicesPortal','wishesPortal','recovery','gathering']]
geo=a.evaluate('return new Promise(resolve=>{var q=wx.createSelectorQuery();'+''.join('q.select('+json.dumps(s)+').boundingClientRect();' for s in selectors)+'q.exec(resolve)})')
page,card,portals,left,right,recovery,gathering=geo
assert all(item['left']>=0 and item['right']<=page['right'] for item in geo),geo
assert card['bottom']<=portals['top'] and portals['bottom']<=recovery['top'] and recovery['bottom']<=gathering['top'],geo
assert abs(left['width']-right['width'])<1,geo
assert a.evaluate('return new Promise(resolve=>wx.createSelectorQuery().selectAll('+json.dumps(a.cls('flashback-corridor','wishCard'))+').boundingClientRect().exec(r=>resolve(r[0].length)))')==0
Path('/tmp/cgc-guest-native-report.json').write_text(json.dumps({'routes':True,'noWishFeed':True,'noOverflow':True,'geometry':geo},ensure_ascii=False,indent=2))
a.call('automation_element_action',selector=cls('quoteOpen'),action='tap')
assert a.evaluate('return getCurrentPages().slice(-1)[0].route')=='pages/flashback-voices/index'
a.call('automation_navigate',action='navigateBack')
a.call('automation_element_action',selector=cls('gathering'),action='tap')
assert a.evaluate('return getCurrentPages().slice(-1)[0].route')=='pages/discover/index'
a.call('automation_navigate',action='switchTab',url='/pages/flashback-corridor/index')
a.evaluate('wx.pageScrollTo({scrollTop:0,duration:0});return true')
print('PASS guest structure, geometry, quote deep link and discover entry',flush=True)

previous = a.call('automation_element_action',selector=cls('quoteOpen'),action='text')
for _ in range(2):
 a.call('automation_navigate',action='switchTab',url='/pages/discover/index')
 a.call('automation_navigate',action='switchTab',url='/pages/flashback-corridor/index')
 current = a.call('automation_element_action',selector=cls('quoteOpen'),action='text')
 assert current != previous, 'Guest re-entry must choose another available quote'
 previous = current
print('PASS random guest re-entry without consecutive repeats',flush=True)
