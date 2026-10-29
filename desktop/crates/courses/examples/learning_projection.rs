//! Story 4.6 的 CLI HITL：真实后端 courseLearningDetail → 学习投影模型。
//! 用法：CGC_TOKEN=<jwt> CGC_COURSE_ID=<id> cargo run -p cgc-courses --example learning_projection

use cgc_courses::catalog::{CoursesApi, HttpCoursesApi};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let token = std::env::var("CGC_TOKEN")?;
    let course_id = std::env::var("CGC_COURSE_ID")?;
    let api = HttpCoursesApi::from_env();
    let projection = api.get_learning_projection(Some(&token), &course_id)?;
    println!("title: {}", projection.title);
    println!(
        "revision={:?} stale={} run={:?}",
        projection.revision_number,
        projection.stale_revision,
        projection.run.as_ref().map(|run| run.status.clone())
    );
    if let Some(progress) = &projection.progress {
        println!(
            "progress: {}/{} complete={}",
            progress.mastered_required, progress.total_required, progress.complete
        );
    }
    if let Some(next) = &projection.next_action {
        println!("next[{}]: {}", next.kind, next.reason);
    }
    for objective in &projection.objectives {
        println!(
            "objective {}：{}（{}）",
            objective.id, objective.title, objective.mastery
        );
    }
    println!("review_queue: {}", projection.review_queue.len());
    Ok(())
}
