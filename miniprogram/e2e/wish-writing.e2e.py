#!/usr/bin/env python3
"""2A native acceptance. Run after CGC_E2E_MOCK=true taro build --type weapp
in a fresh WeChatIDE project session (signed out). Uses synthetic content only;
never exports storage, credentials, or screenshots. Report goes to /tmp.
"""
import json, os, re, subprocess, time
from pathlib import Path
PROJECT = Path(__file__).resolve().parents[1]
CLIENT = os.environ.get('CGC_WECHATIDE_CLIENT', 'Codex')
REPORT = Path('/tmp/cgc-wishes-2a-native-report.json')
checks = []
def call(tool, **args):
    command = ['wechatide', '-c', CLIENT, tool, '--project', str(PROJECT)]
    for key, value in args.items(): command += ['--'+key.replace('_','-'), str(value)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=45)
    value = json.loads(result.stdout)
    if not value.get('ok'): raise RuntimeError(value)
    time.sleep(1.2)  # WeChatIDE rate limit: 60 requests/minute.
    value = value.get('result')
    while isinstance(value, dict) and 'result' in value: value = value['result']
    return value

def cls(page, name):
    css = (PROJECT/'dist/weapp/pages'/page/'index.wxss').read_text()
    values = set(re.findall(r'\.[\w-]+__'+re.escape(name)+r'___[\w-]+', css))
    assert len(values)==1, (page,name,values)
    return values.pop()
def element(page,name,action='text',**args): return call('automation_element_action', selector=cls(page,name), action=action, **args)
def tap(page,name): return element(page,name,'tap')
def evaluate(js): return call('automation_evaluate',fn_source='function(){'+js+'}')
def check(name, ok):
    checks.append({'check':name,'pass':bool(ok)})
    REPORT.write_text(json.dumps(checks,ensure_ascii=False,indent=2))
    print(('PASS ' if ok else 'FAIL ')+name,flush=True)
    assert ok,name
W='flashback-wish-write'; M='flashback-my-wishes'; L='login'
if __name__ == '__main__':
    call('automation_navigate',action='reLaunch',url='/pages/flashback-wish-write/index')
    check('无档案游客可直接进入写愿望页',element(W,'title')=='写下我的愿望')
    element(W,'contentInput','input',value='合成验收：和新朋友一起做一个小作品。')
    element(W,'cityInput','input',value='成都')
    tap(W,'submit')
    check('提交时才进入登录',evaluate('return getCurrentPages().slice(-1)[0].route')=='pages/login/index')
    evaluate('wx.navigateBack(); return true')
    check('取消登录保留草稿',evaluate('return wx.getStorageSync("cgc.wish-draft.guest").content')=='合成验收：和新朋友一起做一个小作品。')
    tap(W,'submit'); tap(L,'loginButton'); tap(L,'dialogPrimary')
    check('登录后返回写愿望页',element(W,'title')=='写下我的愿望')
    check('登录后草稿转入当前账号且游客副本移除',evaluate('var d=wx.getStorageSync("cgc.wish-draft."+wx.getStorageSync("cgc.active_user_id"));return !!d && d.content==="合成验收：和新朋友一起做一个小作品。" && !wx.getStorageSync("cgc.wish-draft.guest")'))
    tap(W,'submit')
    check('创建后进入我的愿望',element(M,'title')=='我的愿望')
    check('公开提交反馈准确',element(M,'status')=='已保存 · 已公开')
    quota = element(M,'quota')
    call('automation_wx_api',action='mock',method='showModal',result='{"confirm":false,"cancel":true}')
    tap(M,'deleteWish')
    check('取消删除仍可见',element(M,'status')=='已保存 · 已公开')
    call('automation_wx_api',action='mock',method='showModal',result='{"confirm":true,"cancel":false}')
    try: tap(M,'deleteWish')
    finally: call('automation_wx_api',action='restore',method='showModal')
    check('删除不退还额度',element(M,'quota')==quota)
    check('删除后成功草稿未恢复',evaluate('return !wx.getStorageSync("cgc.wish-draft."+wx.getStorageSync("cgc.active_user_id"))'))
    print('Completed '+str(len(checks))+' native checks. '+str(REPORT),flush=True)
