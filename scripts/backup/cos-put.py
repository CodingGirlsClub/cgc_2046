#!/usr/bin/env python3
"""COS PUT（单文件上传）——零第三方依赖，纯标准库签名。
用法: cos-put.py <本地文件> <COS对象键>
凭证来源: 环境变量 COS_SECRET_ID / COS_SECRET_KEY / COS_BUCKET / COS_REGION
用 XML API + 签名 v1（足够内部定时任务；不做分块——DB dump 量级 <1GB）。
内网 endpoint（同地域免流量费）: cos-internal.<region>.myqcloud.com

服务器安装位置：/usr/local/bin/cos-put.py（root 755）
"""
import hashlib
import hmac
import os
import sys
import time
import urllib.request
from urllib.parse import quote


def q(path: str) -> str:
    return quote(path, safe="/")


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    local, key = sys.argv[1], sys.argv[2]
    sid = os.environ["COS_SECRET_ID"]
    skey = os.environ["COS_SECRET_KEY"]
    bucket = os.environ["COS_BUCKET"]
    region = os.environ["COS_REGION"]
    host = f"{bucket}.cos-internal.{region}.myqcloud.com"
    path = f"/{q(key)}"
    now = int(time.time())
    exp = now + 600
    # 签名（官方算法）：q-sign-algorithm/q-ak/q-key-time/q-header-list/q-url-param-list + HMAC 链
    key_time = f"{now};{exp}"
    sign_key = hmac.new(skey.encode(), key_time.encode(), hashlib.sha1).hexdigest()
    http_string = f"put\n{path}\n\nhost={host}\n"
    sha1ed = hashlib.sha1(http_string.encode()).hexdigest()
    string_to_sign = f"sha1\n{key_time}\n{sha1ed}\n"
    signature = hmac.new(sign_key.encode(), string_to_sign.encode(), hashlib.sha1).hexdigest()
    auth = (
        f"q-sign-algorithm=sha1&q-ak={sid}&q-sign-time={key_time}"
        f"&q-key-time={key_time}&q-header-list=host&q-url-param-list="
        f"&q-signature={signature}"
    )
    with open(local, "rb") as f:
        body = f.read()
    req = urllib.request.Request(
        f"https://{host}{path}", data=body, method="PUT",
        headers={"Host": host, "Authorization": auth},
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        print(f"COS put {key}: HTTP {resp.status}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
