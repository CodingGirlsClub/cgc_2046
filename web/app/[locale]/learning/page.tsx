"use client";

import { useQuery } from "@apollo/client/react";
import { Link } from "@/i18n/navigation";
import SitePage from "@/components/site-page";
import LearningTab from "@/components/learning/learning-tab";
import { MY_LEARNING_RUNS } from "@/lib/graphql/participations";
import { useTranslations } from "next-intl";

export default function LearningHomePage() {
  const { data, loading, error } = useQuery(MY_LEARNING_RUNS);
  const t = useTranslations("learningHome");
  return (
    <SitePage>
      <main className="learning-home">
        <div className="learning-home__eyebrow">{t("eyebrow")}</div>
        <div className="learning-home__heading">
          <div>
            <h1>{t("title")}</h1>
            <p>{t("subtitle")}</p>
          </div>
          <Link href="/courses" className="learning-home__catalog-link">{t("catalog")} <span>↗</span></Link>
        </div>
        <section className="learning-home__surface" aria-label={t("courses")}>
          {loading ? <p className="learning-home__state">{t("loading")}</p> : null}
          {error ? <p className="learning-home__state learning-home__state--error">{t("error")}</p> : null}
          {!loading && !error ? <LearningTab runs={data?.myLearningRuns ?? []} /> : null}
        </section>
      </main>
    </SitePage>
  );
}
