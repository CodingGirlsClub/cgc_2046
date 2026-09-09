"use client";

import { useQuery } from "@apollo/client/react";
import { Link } from "@/i18n/navigation";
import SitePage from "@/components/site-page";
import LearningTab, {
  coursesWithoutRuns,
} from "@/components/learning/learning-tab";
import { MY_ENROLLMENTS, MY_LEARNING_RUNS } from "@/lib/graphql/participations";
import { useTranslations } from "next-intl";

/** 兜底入口（P1-6）的报名拉取页大小：只用于「confirmed 无 run 课程」入口补齐 */
const FALLBACK_ENROLLMENT_PAGE = 100;

export default function LearningHomePage() {
  const { data, loading, error } = useQuery(MY_LEARNING_RUNS);
  // confirmed 报名但 learning run 未种出的课程（内容授权不依赖 run）也要有
  // 内容入口，否则空态把已报名学员挡在课程外
  const { data: enrollData } = useQuery(MY_ENROLLMENTS, {
    variables: { first: FALLBACK_ENROLLMENT_PAGE },
  });
  const t = useTranslations("learningHome");
  const runs = data?.myLearningRuns ?? [];
  const extraCourses = coursesWithoutRuns(
    runs,
    enrollData?.myEnrollments?.results ?? [],
  );
  return (
    <SitePage>
      <main className="learning-home">
        <div className="learning-home__eyebrow">{t("eyebrow")}</div>
        <div className="learning-home__heading">
          <div>
            <h1>{t("title")}</h1>
            <p>{t("subtitle")}</p>
          </div>
          <div className="flex items-center gap-4">
            <Link href="/participations" className="learning-home__catalog-link">{t("myParticipations")} <span>↗</span></Link>
            <Link href="/courses" className="learning-home__catalog-link">{t("catalog")} <span>↗</span></Link>
          </div>
        </div>
        <section className="learning-home__surface" aria-label={t("courses")}>
          {loading ? <p className="learning-home__state">{t("loading")}</p> : null}
          {error ? <p className="learning-home__state learning-home__state--error">{t("error")}</p> : null}
          {!loading && !error ? (
            <LearningTab runs={runs} extraCourses={extraCourses} />
          ) : null}
        </section>
      </main>
    </SitePage>
  );
}
