//! Story 4.10：课程阅读 e2e（Fake 驱动）——目录→详情→阅读→学习投影→待复习事件键。
//! 真机/真实后端样本回归登记在 epic-7。

use std::sync::Arc;

use cgc_courses::catalog::{
    learning_context, CourseCatalogService, CoursesApi, CoursesListState, FakeCoursesApi,
};
use cgc_courses::content::CourseContentService;
use cgc_courses::projection::{LearningProjectionService, ProjectionState};

fn fake_api() -> Arc<dyn CoursesApi> {
    Arc::new(FakeCoursesApi::with_seed(15))
}

#[test]
fn catalog_to_detail_to_reading_to_projection() {
    let api = fake_api();

    // 1. 目录（第一页）
    let page = api
        .list_courses(None, None, None, 10)
        .expect("step 1: list courses");
    assert_eq!(page.items.len(), 10, "step 1: page size");
    assert!(page.next_cursor.is_some(), "step 1: has next page");

    // 2. 选一门已报名课程（fake 偶数 index 已报名）
    let course = page
        .items
        .iter()
        .find(|course| course.id == "crs-000")
        .expect("step 2: enrolled course");
    let detail = api
        .get_course(None, &course.id)
        .expect("step 2: course detail");
    assert_eq!(
        detail.enrollment_status.as_deref(),
        Some("confirmed"),
        "step 2: enrolled"
    );

    // 3. 学习上下文（4.8 契约）
    let context =
        learning_context(Some("u-1".to_string()), &detail).expect("step 3: learning context");
    assert_eq!(context.course_id, course.id, "step 3: context course");
    assert!(!context.course_revision_id.is_empty(), "step 3: revision");

    // 4. 正文
    let content = api
        .get_course_content(None, &course.id)
        .expect("step 4: course content");
    assert!(!content.document.is_empty(), "step 4: content not empty");
    assert_eq!(content.course_id, course.id, "step 4: content course");
    let markdown = content
        .document
        .issues
        .iter()
        .flat_map(|issue| {
            issue
                .story_materials
                .iter()
                .chain(issue.objective_materials.iter())
        })
        .filter_map(|material| material.body.as_deref())
        .collect::<String>();
    assert!(
        markdown.contains("bold"),
        "step 4: readable markdown material"
    );
    assert!(markdown.contains("fn main"), "step 4: code block material");

    // 5. 学习投影（4.6）
    let projection = api
        .get_learning_projection(None, &course.id)
        .expect("step 5: learning projection");
    assert_eq!(projection.course_id, course.id, "step 5: projection course");
    assert!(projection.progress.is_some(), "step 5: progress present");
    assert!(
        projection.next_action.is_some(),
        "step 5: next action present"
    );
    assert!(
        projection
            .objectives
            .iter()
            .any(|objective| objective.required),
        "step 5: required objective"
    );

    // 6. 待复习事件键（4.11）：fake 队列为空 → None；非空投影由单测覆盖。
    assert!(
        projection.review_dedup_key("u-1").is_none(),
        "step 6: empty review queue has no dedup key"
    );
}

#[test]
fn services_feed_learning_page_states() {
    let api = fake_api();

    let mut catalog = CourseCatalogService::new(api.clone());
    catalog.begin_first_load();
    let page = api
        .list_courses(None, None, None, 10)
        .expect("step 1: list");
    catalog.adopt_page(page);
    assert!(
        matches!(catalog.state(), CoursesListState::Ready),
        "step 1: catalog ready"
    );

    let course_id = catalog
        .items()
        .first()
        .expect("step 2: first course")
        .id
        .clone();
    let mut content = CourseContentService::new(api.clone());
    content.begin_load(&course_id);
    content.adopt(
        api.get_course_content(None, &course_id)
            .expect("step 3: content"),
    );
    assert!(
        !matches!(
            content.state(),
            cgc_courses::content::CourseContentState::Loading
        ),
        "step 3: content loaded"
    );

    let mut projection = LearningProjectionService::new(api.clone());
    projection.begin_load(&course_id);
    projection.adopt(
        api.get_learning_projection(None, &course_id)
            .expect("step 4: projection"),
    );
    assert!(
        matches!(projection.state(), ProjectionState::Ready),
        "step 4: projection ready"
    );
    assert!(
        projection.projection().is_some(),
        "step 4: projection stored"
    );
}

#[test]
fn unenrolled_course_fails_reading_closed() {
    let api = fake_api();
    // fake 奇数 index 未报名 / 无正文
    let content = api.get_course_content(None, "crs-001");
    assert!(
        matches!(content, Err(cgc_courses::catalog::CoursesError::NotFound)),
        "step 1: unenrolled content not found"
    );
    let projection = api.get_learning_projection(None, "crs-001");
    assert!(
        projection.is_ok(),
        "step 2: fake projection is permissive; backend enforces membership"
    );
}
