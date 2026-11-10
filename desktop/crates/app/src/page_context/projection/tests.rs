use super::*;

#[test]
fn workspace_overview_projection_matches_visible_blocks() {
    use cgc_courses::catalog::CourseSummary;
    use cgc_events::list::EventSummary;
    use cgc_platform::workspace::WorkspaceSummary;

    let workspace = WorkspaceSummary {
        id: "ws-1".into(),
        slug: "beijing".into(),
        name: "Beijing Chapter".into(),
        my_role_names: vec!["learner".into()],
        member_count: Some(42),
        can_access: true,
    };
    let event = |id: &str, title: &str, starts_at: &str| EventSummary {
        id: id.into(),
        title: title.into(),
        status: "open".into(),
        visibility: "public".into(),
        enrollment_policy: "open".into(),
        capacity: None,
        confirmed_count: None,
        enrollment_badge: None,
        registration_deadline: None,
        starts_at: Some(starts_at.into()),
        venue: None,
        pricing_enabled: false,
    };
    let course = |id: &str, title: &str| CourseSummary {
        id: id.into(),
        title: title.into(),
        status: "published".into(),
        workspace_id: Some("ws-1".into()),
        enrollment_badge: None,
        pricing_enabled: false,
        starts_at: None,
        registration_deadline: None,
    };

    let (body, version) = project_workspace_overview(
        &workspace,
        &[
            event("event-1", "Rust Night", "2026-11-02"),
            event("event-2", "Rust Day", "2026-11-09"),
        ],
        &[course("course-1", "Rust Basics")],
        "page:/workspace",
    );
    let PageBody::Ready(body) = body else {
        panic!("workspace overview must have a ready body");
    };
    assert!(body.contains("Beijing Chapter"));
    assert!(body.contains("learner"));
    assert!(body.contains("42"));
    // 概览 UI 真正渲染的两块列表必须出现在投影里。
    assert!(body.contains("本区近期活动"));
    assert!(body.contains("Rust Night"));
    assert!(body.contains("本区课程"));
    assert!(body.contains("Rust Basics"));
    // R7：概览 UI 没有报名块，投影也不得再出现报名行（尤其跨台的）。
    assert!(
        !body.contains("我的课程"),
        "概览不得投影 UI 不存在的课程报名块"
    );
    assert!(!body.contains("我的参与"), "概览不得投影 UI 不存在的参与块");
    assert!(!body.contains("跨台报名"), "概览不得包含任何报名行");

    // 行序抖动（同一批数据换序返回）不应改动 Agent 上下文版本。
    let (_, reordered) = project_workspace_overview(
        &workspace,
        &[
            event("event-2", "Rust Day", "2026-11-09"),
            event("event-1", "Rust Night", "2026-11-02"),
        ],
        &[course("course-1", "Rust Basics")],
        "page:/workspace",
    );
    assert_eq!(version, reordered, "行序抖动不应改 Agent 上下文版本");
}

#[test]
fn course_learning_projection_contains_goals_chapters_and_issue_materials() {
    use cgc_courses::content::{
        CourseChapter, CourseContent, CourseContentDocument, CourseIssue, MaterialKind,
        TypedMaterial,
    };

    let material = TypedMaterial {
        kind: MaterialKind::Markdown,
        title: None,
        body: Some("Ownership rules".into()),
        url: None,
        alt_text: None,
        caption: None,
        provider: None,
        external_id: None,
    };
    let content = CourseContent {
        course_id: "course-1".into(),
        title: "Rust Basics".into(),
        description: Some("Learn Rust".into()),
        revision_number: Some(7),
        published_at: None,
        document: CourseContentDocument {
            goals: vec!["Write safe code".into()],
            chapters: vec![CourseChapter {
                id: Some("chapter-1".into()),
                title: Some("Foundations".into()),
            }],
            issues: vec![CourseIssue {
                id: Some("issue-1".into()),
                title: Some("Ownership".into()),
                story_materials: vec![material],
                ..Default::default()
            }],
        },
    };

    let (body, _) = project_course_learning(&content, "page:/courses/course-1/learn");
    let PageBody::Ready(body) = body else {
        panic!("course learning page must have a ready body");
    };
    assert!(body.contains("Rust Basics"));
    assert!(body.contains("Write safe code"));
    assert!(body.contains("Foundations"));
    assert!(body.contains("Ownership"));
    assert!(body.contains("Ownership rules"));
}

#[test]
fn enrollment_projection_excludes_check_in_code() {
    use cgc_events::enrollments::MyEnrollmentRow;

    let row = MyEnrollmentRow {
        id: "enroll-1".into(),
        workspace_id: "ws-1".into(),
        status: "confirmed".into(),
        target_title: Some("Rust Night".into()),
        starts_at: Some("2026-11-02".into()),
        event_id: Some("event-1".into()),
        course_id: None,
        payment_mode: Some("free".into()),
        check_in_code: Some("SECRET-CODE".into()),
    };
    let (body, _) = project_enrollments(&[row], "page:/events/mine");
    let PageBody::Ready(body) = body else {
        panic!("enrollment list with rows must have a ready body");
    };
    assert!(body.contains("Rust Night"));
    assert!(body.contains("confirmed"));
    assert!(!body.contains("SECRET-CODE"));
}

#[test]
fn learning_run_projection_carries_progress_and_falls_back_to_confirmed_courses() {
    use cgc_events::enrollments::{
        LearningNextAction, LearningProgress, MyEnrollmentRow, MyLearningRunRow,
    };

    let run = MyLearningRunRow {
        run_id: "run-1".into(),
        enrollment_id: "enroll-from-event".into(),
        course_id: "course-1".into(),
        target_title: Some("Rust Basics".into()),
        status: "active".into(),
        stale_revision: true,
        progress: LearningProgress {
            mastered_required: 2,
            total_required: 4,
            complete: false,
        },
        next_action: Some(LearningNextAction {
            kind: "review".into(),
            objective_id: "obj-1".into(),
            reason: "due".into(),
        }),
    };
    // 这条报名不在 myEnrollments 第一页（活动报名且 course_id 为空）也不影响 run 投影。
    let fallback = MyEnrollmentRow {
        id: "enroll-confirmed".into(),
        workspace_id: "ws-1".into(),
        status: "confirmed".into(),
        target_title: Some("Owned course".into()),
        starts_at: None,
        event_id: None,
        course_id: Some("course-2".into()),
        payment_mode: None,
        check_in_code: None,
    };
    let (body, version) =
        project_learning_runs(std::slice::from_ref(&run), &[fallback], "page:/learning");
    let PageBody::Ready(text) = body else {
        panic!("runs must produce a ready body");
    };
    assert!(text.contains("Rust Basics"));
    assert!(text.contains("必修 2/4"));
    assert!(text.contains("课程已更新"));
    assert!(text.contains("下一动作：review"));
    assert!(
        text.contains("Owned course"),
        "confirmed fallback stays visible"
    );

    let mut advanced = run;
    advanced.progress.mastered_required = 3;
    let (_, advanced_version) = project_learning_runs(&[advanced], &[], "page:/learning");
    assert_ne!(
        version, advanced_version,
        "progress changes must change the context version"
    );
}

#[test]
fn course_pages_project_detail_and_catalog_rows() {
    use cgc_courses::catalog::{CourseDetail, CourseSummary};

    let detail = CourseDetail {
        id: "course-1".into(),
        title: "Rust Basics".into(),
        description: Some("Learn ownership".into()),
        status: "published".into(),
        visibility: "public".into(),
        workspace_id: Some("ws-1".into()),
        pricing_enabled: false,
        enrollment_policy: "open".into(),
        available_price_tiers: Vec::new(),
        enrollment_status: Some("confirmed".into()),
        revision_number: Some(7),
    };
    let summary = CourseSummary {
        id: "course-1".into(),
        title: "Rust Basics".into(),
        status: "published".into(),
        workspace_id: Some("ws-1".into()),
        enrollment_badge: None,
        pricing_enabled: false,
        starts_at: Some("2026-11-02".into()),
        registration_deadline: None,
    };

    let (body, _) = project_course_detail(&detail, "page:/courses/course-1");
    let PageBody::Ready(body) = body else {
        panic!("course detail must have a ready body");
    };
    assert!(body.contains("Rust Basics"));
    assert!(body.contains("Learn ownership"));
    assert!(body.contains("confirmed"));

    let (body, version) = project_course_list(&[summary], "page:/courses");
    let PageBody::Ready(body) = body else {
        panic!("course list with rows must have a ready body");
    };
    assert!(body.contains("Rust Basics"));
    assert!(body.contains("2026-11-02"));
    assert_ne!(version, project_course_list(&[], "page:/courses").1);
}

#[test]
fn event_list_projection_contains_visible_rows_and_filter() {
    use cgc_events::list::EventSummary;

    let event = EventSummary {
        id: "event-1".into(),
        title: "Rust Night".into(),
        status: "open".into(),
        visibility: "public".into(),
        enrollment_policy: "open".into(),
        capacity: Some(30),
        confirmed_count: Some(12),
        enrollment_badge: Some("报名中".into()),
        registration_deadline: Some("2026-11-01".into()),
        starts_at: Some("2026-11-02 19:00".into()),
        venue: Some("Shanghai".into()),
        pricing_enabled: false,
    };
    let (body, version) = project_event_list(&[event], "open", "page:/events");
    let PageBody::Ready(body) = body else {
        panic!("event list with rows must have a ready body");
    };
    assert!(body.contains("筛选：open"));
    assert!(body.contains("Rust Night"));
    assert!(body.contains("Shanghai"));
    assert!(body.contains("30"));
    assert_ne!(version, project_event_list(&[], "open", "page:/events").1);
}

#[test]
fn event_detail_projection_contains_visible_page_body_and_versions_it() {
    use cgc_events::detail::EventDetail;

    fn detail(description: &str) -> EventDetail {
        EventDetail {
            id: "event-1".into(),
            title: "Rust Night".into(),
            description: Some(description.into()),
            status: "published".into(),
            visibility: "public".into(),
            enrollment_policy: "open".into(),
            capacity: Some(30),
            confirmed_count: Some(12),
            enrollment_badge: Some("报名中".into()),
            min_age: Some(18),
            registration_deadline: Some("2026-11-01".into()),
            starts_at: Some("2026-11-02 19:00".into()),
            ends_at: Some("2026-11-02 21:00".into()),
            venue: Some("Shanghai".into()),
            pricing_enabled: false,
            available_price_tiers: Vec::new(),
            deposit_enabled: false,
            deposit_amount_cents: None,
        }
    }

    let (body, version) = project_event_detail(&detail("Ownership talk"), "page:/events/event-1");
    let PageBody::Ready(body) = body else {
        panic!("event detail must have a ready body");
    };
    assert!(body.contains("Rust Night"));
    assert!(body.contains("Ownership talk"));
    assert!(body.contains("Shanghai"));
    assert!(body.contains("免费"));
    assert!(body.contains("18"));
    assert_ne!(
        version,
        project_event_detail(&detail("Changed talk"), "page:/events/event-1").1
    );
}

#[test]
fn issue_projection_uses_active_issue_body_and_versions_the_payload() {
    use cgc_courses::content::{
        CourseChecklistItem, CourseIssue, CourseObjective, MaterialKind, TypedMaterial,
    };

    fn material(kind: MaterialKind, body: &str) -> TypedMaterial {
        TypedMaterial {
            kind,
            title: None,
            body: Some(body.into()),
            url: None,
            alt_text: None,
            caption: None,
            provider: None,
            external_id: None,
        }
    }

    let issue = CourseIssue {
        goal: Some("Understand ownership".into()),
        as_a: Some("学习 Rust 的学员".into()),
        given: vec!["读完第一章".into()],
        checklist: vec![CourseChecklistItem {
            id: Some("check-1".into()),
            text: "Explain borrowing".into(),
        }],
        story_materials: vec![material(
            MaterialKind::Markdown,
            "# Ownership\nMemory rules",
        )],
        objectives: vec![CourseObjective {
            id: None,
            title: Some("Practice".into()),
            required: false,
            prereq_ids: Vec::new(),
            activity: None,
            assessment: None,
            rubric: Vec::new(),
            materials: vec![material(MaterialKind::Text, "Move one value")],
        }],
        ..Default::default()
    };

    let (body, version) = project_issue(&issue, Some(7), "issue:course-1:issue-1");
    let PageBody::Ready(body) = body else {
        panic!("issue with content must have a ready body");
    };
    assert!(body.contains("Understand ownership"));
    assert!(body.contains("作为：学习 Rust 的学员"));
    assert!(body.contains("前提：读完第一章"));
    assert!(body.contains("我能：Understand ownership"));
    assert!(body.contains("Explain borrowing"));
    assert!(body.contains("Ownership"));
    assert!(body.contains("Memory rules"));
    assert!(body.contains("Move one value"));
    assert_eq!(
        version,
        project_issue(&issue, Some(7), "issue:course-1:issue-1").1
    );
    assert_ne!(
        version,
        project_issue(&issue, Some(8), "issue:course-1:issue-1").1
    );
}
