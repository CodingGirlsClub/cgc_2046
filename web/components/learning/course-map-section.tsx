"use client";

/**
 * 公开课程地图区块(U8,R10):挂在 /courses/[slug] 公开详情页。
 *
 * - 行 = issue key + 标题 + kind 标签 chip + goal 一行(Linear 行密度);
 * - 匿名只读;**无 checklist**(公开页职责是「承诺你会变成什么样」,
 *   评分细则不泄底——courseMap 查询本身即 goal-only 契约);
 * - 无教研产出(未 save_course_content)时整块不渲染。
 */

import { useEffect, useState } from "react";
import { client } from "@/lib/apollo-client";
import { COURSE_MAP, type CourseMap } from "@/lib/graphql/events";
import { IssueKindChip } from "@/components/learning/issue-bits";

export default function CourseMapSection({ slug }: { slug: string }) {
  const [map, setMap] = useState<CourseMap | null>(null);
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    if (!slug) return;
    let cancelled = false;

    client
      .query({ query: COURSE_MAP, variables: { slug } })
      .then(({ data }) => {
        if (!cancelled) setMap(data?.courseMap ?? null);
      })
      .catch(() => {
        // 地图是增益面:失败不阻塞报名主流程,静默不渲染
        if (!cancelled) setMap(null);
      })
      .finally(() => {
        if (!cancelled) setLoaded(true);
      });

    return () => {
      cancelled = true;
    };
  }, [slug]);

  if (!loaded || !map || map.issues.length === 0) return null;

  return (
    <section
      aria-labelledby="course-map-heading"
      className="join-card !p-8"
      data-testid="course-map"
    >
      <h2 id="course-map-heading" className="text-lg font-semibold">
        课程地图
      </h2>
      <p className="mt-1 text-[13px] text-ink-3">
        完成全部学习单元后,你将具备:{map.goals.join(" / ")}
      </p>
      <ul className="mt-4 divide-y divide-line" data-testid="course-map-issues">
        {map.issues.map((issue) => (
          <li
            key={issue.id}
            className="flex items-start gap-3 py-2.5"
            data-testid="course-map-issue"
          >
            <span className="min-w-14 pt-0.5 font-mono text-[12px] text-ink-3">
              {issue.key}
            </span>
            <div className="min-w-0 flex-1">
              <p className="flex flex-wrap items-center gap-2 text-sm font-medium text-ink">
                {issue.title}
                <IssueKindChip kind={issue.kind} />
              </p>
              {issue.goal ? (
                <p className="mt-0.5 truncate text-[13px] text-ink-3">
                  {issue.goal}
                </p>
              ) : null}
            </div>
          </li>
        ))}
      </ul>
    </section>
  );
}
