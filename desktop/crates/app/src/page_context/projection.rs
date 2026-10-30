//! Active tab 的正文与内容版本投影。

use std::sync::Arc;

use super::PageBody;

fn project_body(tab_id: &str, schema: &str, sections: Vec<String>) -> (PageBody, String) {
    let body = sections.join("\n\n").trim().to_string();
    let version_source = format!("{schema}\0{tab_id}\0{body}");
    let version = cgc_platform::registry::checksum::sha256_hex(version_source.as_bytes());
    let body = if body.is_empty() {
        PageBody::Empty
    } else {
        PageBody::Ready(Arc::from(body))
    };
    (body, version)
}

/// 场次详情页的可见主内容。
pub(crate) fn project_event_detail(
    detail: &cgc_events::detail::EventDetail,
    tab_id: &str,
) -> (PageBody, String) {
    use cgc_events::detail::PriceMode;

    let mut sections = vec![detail.title.clone()];
    if let Some(description) = detail
        .description
        .as_deref()
        .filter(|description| !description.trim().is_empty())
    {
        sections.push(description.to_string());
    }
    if let Some(badge) = detail.enrollment_badge.as_deref() {
        sections.push(badge.to_string());
    }
    sections.push(format!(
        "状态：{} · 可见性：{} · 报名策略：{}",
        detail.status, detail.visibility, detail.enrollment_policy
    ));
    let mut schedule = Vec::new();
    if let Some(starts_at) = detail.starts_at.as_deref() {
        schedule.push(format!("开始：{starts_at}"));
    }
    if let Some(ends_at) = detail.ends_at.as_deref() {
        schedule.push(format!("结束：{ends_at}"));
    }
    if let Some(deadline) = detail.registration_deadline.as_deref() {
        schedule.push(format!("报名截止：{deadline}"));
    }
    if !schedule.is_empty() {
        sections.push(schedule.join("\n"));
    }
    if let Some(venue) = detail.venue.as_deref() {
        sections.push(format!("地点：{venue}"));
    }
    let mut facts = Vec::new();
    if let Some(capacity) = detail.capacity {
        facts.push(format!("容量：{capacity}"));
    }
    if let Some(confirmed) = detail.confirmed_count {
        facts.push(format!("已报名：{confirmed}"));
    }
    if let Some(min_age) = detail.min_age {
        facts.push(format!("最低年龄：{min_age}"));
    }
    if !facts.is_empty() {
        sections.push(facts.join(" · "));
    }
    sections.push(match detail.price_mode() {
        PriceMode::Free => "价格：免费".to_string(),
        PriceMode::Paid {
            min_amount_cents,
            tiers,
        } => format!(
            "价格：¥{:.2} 起 · {tiers} 档",
            min_amount_cents as f64 / 100.0
        ),
        PriceMode::Deposit { amount_cents } => {
            format!("押金：¥{:.2}（可退）", amount_cents as f64 / 100.0)
        }
    });
    project_body(tab_id, "event-detail-v1", sections)
}

/// 场次列表页的可见行与当前筛选。
pub(crate) fn project_event_list(
    events: &[cgc_events::list::EventSummary],
    filter: &str,
    tab_id: &str,
) -> (PageBody, String) {
    let schema = format!("event-list-v1\0{filter}");
    if events.is_empty() {
        return project_body(tab_id, &schema, Vec::new());
    }
    let mut sections = vec![format!("筛选：{filter}")];
    for event in events {
        let mut facts = vec![event.title.clone(), event.status.clone()];
        if let Some(starts_at) = event.starts_at.as_deref() {
            facts.push(starts_at.to_string());
        }
        if let Some(venue) = event.venue.as_deref() {
            facts.push(venue.to_string());
        }
        if let Some(capacity) = event.capacity {
            facts.push(format!("容量 {capacity}"));
        }
        if let Some(confirmed) = event.confirmed_count {
            facts.push(format!("已报名 {confirmed}"));
        }
        sections.push(facts.join(" · "));
    }
    project_body(tab_id, &schema, sections)
}

/// 课程详情页的可见主内容。
pub(crate) fn project_course_detail(
    detail: &cgc_courses::catalog::CourseDetail,
    tab_id: &str,
) -> (PageBody, String) {
    let mut sections = vec![detail.title.clone()];
    if let Some(description) = detail
        .description
        .as_deref()
        .filter(|description| !description.trim().is_empty())
    {
        sections.push(description.to_string());
    }
    let mut facts = vec![
        format!("状态：{}", detail.status),
        format!("可见性：{}", detail.visibility),
    ];
    if let Some(enrollment) = detail.enrollment_status.as_deref() {
        facts.push(format!("我的报名：{enrollment}"));
    }
    if let Some(revision) = detail.revision_number {
        facts.push(format!("学习版本：{revision}"));
    }
    facts.push(if detail.pricing_enabled {
        "收费课程".to_string()
    } else {
        "免费课程".to_string()
    });
    sections.push(facts.join(" · "));
    project_body(tab_id, "course-detail-v1", sections)
}

/// 课程目录页的可见行。
pub(crate) fn project_course_list(
    courses: &[cgc_courses::catalog::CourseSummary],
    tab_id: &str,
) -> (PageBody, String) {
    if courses.is_empty() {
        return project_body(tab_id, "course-list-v1", Vec::new());
    }
    let sections = courses
        .iter()
        .map(|course| {
            let mut facts = vec![course.title.clone(), course.status.clone()];
            if let Some(starts_at) = course.starts_at.as_deref() {
                facts.push(starts_at.to_string());
            }
            if course.pricing_enabled {
                facts.push("收费课程".to_string());
            }
            facts.join(" · ")
        })
        .collect::<Vec<_>>();
    project_body(tab_id, "course-list-v1", sections)
}

/// 我的学习/参与/报名列表的可见行；核销码等敏感字段不进入上下文。
pub(crate) fn project_enrollments(
    rows: &[cgc_events::enrollments::MyEnrollmentRow],
    tab_id: &str,
) -> (PageBody, String) {
    if rows.is_empty() {
        return project_body(tab_id, "enrollments-v1", Vec::new());
    }
    let sections = rows
        .iter()
        .map(|row| {
            let mut facts = vec![
                row.target_title.clone().unwrap_or_else(|| row.id.clone()),
                row.status.clone(),
            ];
            if let Some(starts_at) = row.starts_at.as_deref() {
                facts.push(starts_at.to_string());
            }
            if let Some(payment_mode) = row.payment_mode.as_deref() {
                facts.push(payment_mode.to_string());
            }
            facts.join(" · ")
        })
        .collect::<Vec<_>>();
    project_body(tab_id, "enrollments-v1", sections)
}

/// 把当前 issue 的可见主内容投影为提交正文；Outline 与其他 issue 不参与。
pub(crate) fn project_issue(
    issue: &cgc_courses::content::CourseIssue,
    revision: Option<i64>,
    tab_id: &str,
) -> (PageBody, String) {
    fn push_material(sections: &mut Vec<String>, material: &cgc_courses::content::TypedMaterial) {
        use cgc_courses::content::MaterialKind;

        let mut lines = Vec::new();
        if let Some(title) = material
            .title
            .as_deref()
            .filter(|title| !title.trim().is_empty())
        {
            lines.push(title.to_string());
        }
        if matches!(material.kind, MaterialKind::Text | MaterialKind::Markdown) {
            if let Some(body) = material.body.as_deref() {
                let text = cgc_agent_ui::markdown_text::markdown_to_plain(body);
                if !text.trim().is_empty() {
                    lines.push(text);
                }
            }
        } else {
            if let Some(url) = material.url.as_deref() {
                lines.push(url.to_string());
            }
            if let Some(alt) = material.alt_text.as_deref() {
                lines.push(alt.to_string());
            }
        }
        if !lines.is_empty() {
            sections.push(lines.join("\n"));
        }
    }

    let mut sections = Vec::new();
    if let Some(goal) = issue.goal.as_deref().filter(|goal| !goal.trim().is_empty()) {
        sections.push(goal.to_string());
    }
    if !issue.checklist.is_empty() {
        sections.push(
            issue
                .checklist
                .iter()
                .map(|item| format!("- {}", item.text))
                .collect::<Vec<_>>()
                .join("\n"),
        );
    }
    for material in &issue.story_materials {
        push_material(&mut sections, material);
    }
    for objective in &issue.objectives {
        if let Some(title) = objective.title.as_deref() {
            sections.push(title.to_string());
        }
        for material in &objective.materials {
            push_material(&mut sections, material);
        }
    }
    let revision = revision
        .map(|value| value.to_string())
        .unwrap_or_else(|| "unversioned".into());
    project_body(tab_id, &format!("issue-context-v1\0{revision}"), sections)
}

#[cfg(test)]
mod tests {
    use super::*;

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

        let (body, version) =
            project_event_detail(&detail("Ownership talk"), "page:/events/event-1");
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
}
