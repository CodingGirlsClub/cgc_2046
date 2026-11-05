use super::*;

#[test]
fn workspace_overview_projection_uses_visible_subset_without_secrets() {
    use cgc_events::enrollments::MyEnrollmentRow;
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
    let course = MyEnrollmentRow {
        id: "enroll-course".into(),
        status: "confirmed".into(),
        target_title: Some("Rust Basics".into()),
        starts_at: None,
        event_id: None,
        course_id: Some("course-1".into()),
        payment_mode: None,
        check_in_code: Some("SECRET".into()),
    };
    let event = EventSummary {
        id: "event-1".into(),
        title: "Rust Night".into(),
        status: "open".into(),
        visibility: "public".into(),
        enrollment_policy: "open".into(),
        capacity: None,
        confirmed_count: None,
        enrollment_badge: None,
        registration_deadline: None,
        starts_at: Some("2026-11-02".into()),
        venue: None,
        pricing_enabled: false,
    };

    let (body, _) = project_workspace_overview(&workspace, &[course], &[event], "page:/workspace");
    let PageBody::Ready(body) = body else {
        panic!("workspace overview must have a ready body");
    };
    assert!(body.contains("Beijing Chapter"));
    assert!(body.contains("learner"));
    assert!(body.contains("42"));
    assert!(body.contains("Rust Basics"));
    assert!(body.contains("Rust Night"));
    assert!(!body.contains("SECRET"));
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
        enrollment_status: Some("confirmed".into()),
        revision_number: Some(7),
    };
    let summary = CourseSummary {
        id: "course-1".into(),
        title: "Rust Basics".into(),
        status: "published".into(),
        workspace_id: Some("ws-1".into()),
        pricing_enabled: false,
        starts_at: Some("2026-11-02".into()),
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
            provider: None,
            external_id: None,
        }
    }

    let issue = CourseIssue {
        goal: Some("Understand ownership".into()),
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
