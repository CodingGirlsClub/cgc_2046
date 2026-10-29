#!/usr/bin/env bash
# M0 真实后端冒烟（无 GUI）：用桌面 Bearer token 依次查询
# 工作台 → 场次列表 → 课程列表 → 学习投影，全部成功才算过。
# 用法：CGC_DESKTOP_TOKEN=<jwt> [CGC_API_URL=http://127.0.0.1:4000/api/graphql] bash scripts/verify-m0-backend.sh
set -euo pipefail
: "${CGC_DESKTOP_TOKEN:?需要 CGC_DESKTOP_TOKEN（第一方桌面 Bearer token）}"
API="${CGC_API_URL:-http://127.0.0.1:4000/api/graphql}"
export API CGC_DESKTOP_TOKEN

python3 - <<'PY'
import json, os, sys, urllib.error, urllib.request

api = os.environ["API"]
token = os.environ["CGC_DESKTOP_TOKEN"]

def gql(query, variables=None):
    body = json.dumps({"query": query, "variables": variables or {}}).encode()
    request = urllib.request.Request(
        api,
        data=body,
        headers={"content-type": "application/json", "authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as error:
        sys.exit(f"HTTP {error.code}: {error.read()[:300]!r}")
    if payload.get("errors"):
        sys.exit(f"GraphQL errors: {json.dumps(payload['errors'], ensure_ascii=False)[:500]}")
    return payload["data"]

workspaces = gql("query { meWorkspaces { id slug name canAccess } }")["meWorkspaces"]
workspaces = [workspace for workspace in workspaces if workspace["canAccess"]]
if not workspaces:
    sys.exit("no accessible workspace")
print(f"workspaces: {len(workspaces)} (first: {workspaces[0]['name']})")

events = gql(
    "query($first:Int!,$after:String,$filter:EventFilterInput){"
    " listEvents(first:$first,after:$after,filter:$filter){ count results{ id title status } } }",
    {"first": 5},
)["listEvents"]
if events["count"] <= 0:
    sys.exit("no events")
print(f"events: count={events['count']} first={events['results'][0]['title']}")

courses = gql(
    "query($first:Int!,$after:String,$filter:CourseFilterInput){"
    " listCourses(first:$first,after:$after,filter:$filter){ count results{ id title status } } }",
    {"first": 5},
)["listCourses"]
if courses["count"] <= 0:
    sys.exit("no courses")
course = courses["results"][0]
print(f"courses: count={courses['count']} first={course['title']}")

detail = gql(
    "query($courseId:ID!){ courseLearningDetail(courseId:$courseId){"
    " courseId title revisionNumber progress{ masteredRequired totalRequired complete }"
    " nextAction{ kind reason } } }",
    {"courseId": course["id"]},
)["courseLearningDetail"]
if not detail or detail["courseId"] != course["id"]:
    sys.exit("learning projection missing")
progress = detail.get("progress") or {}
print(
    "projection: "
    f"{detail['title']} revision={detail.get('revisionNumber')} "
    f"mastered={progress.get('masteredRequired')}/{progress.get('totalRequired')}"
)
print("M0 backend smoke OK")
PY
