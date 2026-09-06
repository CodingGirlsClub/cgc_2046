"use client";

import { useQuery } from "@apollo/client/react";
import { Link } from "@/i18n/navigation";
import SitePage from "@/components/site-page";
import LearningTab from "@/components/learning/learning-tab";
import { MY_LEARNING_RUNS } from "@/lib/graphql/participations";

export default function LearningHomePage() {
  const { data, loading, error } = useQuery(MY_LEARNING_RUNS);
  return (
    <SitePage>
      <main className="learning-home">
        <div className="learning-home__eyebrow">我的学习</div>
        <div className="learning-home__heading">
          <div>
            <h1>继续你的课程</h1>
            <p>从上次停下的地方继续，按目标掌握每一章内容。</p>
          </div>
          <Link href="/courses" className="learning-home__catalog-link">发现课程 <span>↗</span></Link>
        </div>
        <section className="learning-home__surface" aria-label="我的课程">
          {loading ? <p className="learning-home__state">正在加载课程…</p> : null}
          {error ? <p className="learning-home__state learning-home__state--error">课程加载失败，请刷新重试。</p> : null}
          {!loading && !error ? <LearningTab runs={data?.myLearningRuns ?? []} /> : null}
        </section>
      </main>
    </SitePage>
  );
}
