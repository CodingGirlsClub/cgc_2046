#!/usr/bin/env python3
"""
derive_cities.py — 一次性脚本（KTD11 G18 用户拍板 DataV 上游）
从 DataV GeoAtlas 各省 *_full 派 china_cities.json。

不在 CI 跑；产出的 china_cities.json 入库随版本发布。
使用：cd backend && python3 priv/scripts/derive_cities.py
"""

import hashlib
import json
import re
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

from pypinyin import Style, lazy_pinyin

PROVINCE_ADCODES = [
    110000, 120000, 130000, 140000, 150000, 210000, 220000, 230000,
    310000, 320000, 330000, 340000, 350000, 360000, 370000,
    410000, 420000, 430000, 440000, 450000, 460000,
    500000, 510000, 520000, 530000, 540000,
    610000, 620000, 630000, 640000, 650000,
]

# 港澳台在 DataV 顶级行政区划里是行政区类别，手工补三条短名映射。
HK_MO_TW = [
    {"adcode": 810000, "shortName": "香港", "fullName": "香港特别行政区",
     "pinyin": "xianggang", "center": [114.173355, 22.320048], "parentAdcode": 100000},
    {"adcode": 820000, "shortName": "澳门", "fullName": "澳门特别行政区",
     "pinyin": "aomen",     "center": [113.549090, 22.198951], "parentAdcode": 100000},
    {"adcode": 710000, "shortName": "台北", "fullName": "台湾省台北市",
     "pinyin": "taibei",    "center": [121.509062, 25.044332], "parentAdcode": 100000},
]

MUNICIPALITIES = {
    110000: ("北京", "北京市", [116.405285, 39.904989]),
    120000: ("天津", "天津市", [117.190182, 39.125596]),
    310000: ("上海", "上海市", [121.472644, 31.231706]),
    500000: ("重庆", "重庆市", [106.504962, 29.533155]),
}

# 长名后缀按「match 后剩余的字数 ≥ 2」从长到短依序匹配；选第一个会保留核心段。
# 既含全国常见三字四字自治州，也含两字市的「市／地区／盟」。
SUFFIXES = [
    "布依族苗族自治州", "苗族侗族自治州",
    "土家族苗族自治州", "藏族羌族自治州", "蒙古族藏族自治州", "哈尼族彝族自治州",
    "傣族景颇族自治州", "傈僳族自治州", "壮族苗族自治州", "傣族佤族自治州",
    "哈萨克自治州", "柯尔克孜自治州", "朝鲜族自治州", "回族自治州",
    "藏族自治州", "彝族自治州", "白族自治州", "蒙古族自治州", "蒙古自治州",
    "回族自治州", "特别行政区",
    "自治州", "自治区", "地区", "盟", "市", "州",
]


def to_pinyin(name: str) -> str:
    """中文 → 全拼（不带调），民族语地名转写按 pypinyin 默认表。"""
    return "".join(lazy_pinyin(name, style=Style.NORMAL))


def short_name_of(full: str) -> str:
    for suf in SUFFIXES:
        if full.endswith(suf) and len(full) > len(suf):
            stripped = full[: -len(suf)]
            # 至少剩 2 字（如「湘西」保留；「长春市」不能变「长」）
            if len(stripped) >= 2:
                return stripped
    return full


def fetch_province(adcode: int) -> list[dict]:
    url = f"https://geo.datav.aliyun.com/areas_v3/bound/{adcode}_full.json"
    with urllib.request.urlopen(url, timeout=30) as resp:
        data = json.loads(resp.read())
    rows = []
    for f in data["features"]:
        p = f["properties"]
        if p.get("level") != "city":
            continue
        short = short_name_of(p["name"])
        rows.append(
            {
                "adcode": p["adcode"],
                "shortName": short,
                "fullName": p["name"],
                "pinyin": to_pinyin(short),
                "fullPinyin": to_pinyin(p["name"]),
                "center": p.get("center"),
                "parentAdcode": adcode,
            }
        )
    return rows


def main() -> None:
    out_path = Path(__file__).resolve().parent.parent / "flashback" / "china_cities.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)

    rows: list[dict] = []
    with ThreadPoolExecutor(max_workers=6) as pool:
        futures = {pool.submit(fetch_province, adcode): adcode for adcode in PROVINCE_ADCODES}
        for fut in as_completed(futures):
            rows.extend(fut.result())

    for adcode, (short, full, center) in MUNICIPALITIES.items():
        rows.append(
            {
                "adcode": adcode,
                "shortName": short,
                "fullName": full,
                "pinyin": to_pinyin(short),
                "fullPinyin": to_pinyin(full),
                "center": center,
                "parentAdcode": 100000,
            }
        )
    for r in HK_MO_TW:
        r["fullPinyin"] = to_pinyin(r["fullName"])
    rows.extend(HK_MO_TW)

    dedup: dict[int, dict] = {}
    for r in rows:
        dedup[r["adcode"]] = r
    cities = sorted(dedup.values(), key=lambda r: r["adcode"])

    cities_md5 = hashlib.md5(
        json.dumps(cities, sort_keys=True, ensure_ascii=False).encode("utf-8")
    ).hexdigest()

    payload = {
        "metadata": {
            "source": "https://geo.datav.aliyun.com/areas_v3/bound/{adcode}_full.json",
            "fetchedAt": datetime.now(timezone.utc).isoformat(),
            "provinceAdcodesFetched": PROVINCE_ADCODES,
            "version": "v1",
            "citiesMd5": cities_md5,
            "cityCount": len(cities),
            "notes": (
                "省级 *_full 中 level=city 的 features + 4 直辖市 + 港澳台顶级映射；"
                "pinyin 由 pypinyin 离线派生，写进 JSON，backend 不再依赖拼音 hex。"
            ),
        },
        "cities": cities,
    }

    out_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2))
    print(f"wrote {len(cities)} cities → {out_path}")
    print(f"cities_md5={cities_md5}")


if __name__ == "__main__":
    main()
