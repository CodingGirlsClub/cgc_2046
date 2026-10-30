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

fn enrollment_line(row: &cgc_events::enrollments::MyEnrollmentRow) -> String {
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
}

/// 我的学习/参与/报名列表的可见行；核销码等敏感字段不进入上下文。
pub(crate) fn project_enrollments(
    rows: &[cgc_events::enrollments::MyEnrollmentRow],
    tab_id: &str,
) -> (PageBody, String) {
    if rows.is_empty() {
        return project_body(tab_id, "enrollments-v1", Vec::new());
    }
    project_body(
        tab_id,
        "enrollments-v1",
        rows.iter().map(enrollment_line).collect(),
    )
}

/// 工作台概览的可见子集：工作区身份、课程/参与/近期活动摘要。
pub(crate) fn project_workspace_overview(
    workspace: &cgc_platform::workspace::WorkspaceSummary,
    enrollments: &[cgc_events::enrollments::MyEnrollmentRow],
    events: &[cgc_events::list::EventSummary],
    tab_id: &str,
) -> (PageBody, String) {
    let mut sections = vec![workspace.name.clone()];
    if !workspace.my_role_names.is_empty() {
        sections.push(format!("我的角色：{}", workspace.my_role_names.join("、")));
    }
    if let Some(member_count) = workspace.member_count {
        sections.push(format!("成员数：{member_count}"));
    }
    let courses = enrollments
        .iter()
        .filter(|row| row.course_id.is_some())
        .take(4)
        .map(enrollment_line)
        .collect::<Vec<_>>();
    if !courses.is_empty() {
        sections.push(format!("我的课程\n{}", courses.join("\n")));
    }
    let participations = enrollments
        .iter()
        .take(3)
        .map(enrollment_line)
        .collect::<Vec<_>>();
    if !participations.is_empty() {
        sections.push(format!("我的参与\n{}", participations.join("\n")));
    }
    let upcoming = events
        .iter()
        .take(3)
        .map(|event| {
            let mut facts = vec![event.title.clone(), event.status.clone()];
            if let Some(starts_at) = event.starts_at.as_deref() {
                facts.push(starts_at.to_string());
            }
            facts.join(" · ")
        })
        .collect::<Vec<_>>();
    if !upcoming.is_empty() {
        sections.push(format!("近期活动\n{}", upcoming.join("\n")));
    }
    project_body(tab_id, "workspace-overview-v1", sections)
}

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

fn issue_sections(issue: &cgc_courses::content::CourseIssue) -> Vec<String> {
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
    sections
}

/// 把当前 issue 的可见主内容投影为提交正文；Outline 与其他 issue 不参与。
pub(crate) fn project_issue(
    issue: &cgc_courses::content::CourseIssue,
    revision: Option<i64>,
    tab_id: &str,
) -> (PageBody, String) {
    let revision = revision
        .map(|value| value.to_string())
        .unwrap_or_else(|| "unversioned".into());
    project_body(
        tab_id,
        &format!("issue-context-v1\0{revision}"),
        issue_sections(issue),
    )
}

/// 课程学习整页（未聚焦单张 issue 卡时）的主内容。
pub(crate) fn project_course_learning(
    content: &cgc_courses::content::CourseContent,
    tab_id: &str,
) -> (PageBody, String) {
    let mut sections = vec![content.title.clone()];
    if let Some(description) = content
        .description
        .as_deref()
        .filter(|description| !description.trim().is_empty())
    {
        sections.push(description.to_string());
    }
    if !content.document.goals.is_empty() {
        sections.push(content.document.goals.join("\n"));
    }
    let chapters = content
        .document
        .chapters
        .iter()
        .filter_map(|chapter| chapter.title.clone())
        .collect::<Vec<_>>();
    if !chapters.is_empty() {
        sections.push(chapters.join("\n"));
    }
    for issue in &content.document.issues {
        if let Some(title) = issue.title.as_deref() {
            sections.push(title.to_string());
        }
        sections.extend(issue_sections(issue));
    }
    let revision = content
        .revision_number
        .map(|value| value.to_string())
        .unwrap_or_else(|| "unversioned".into());
    project_body(tab_id, &format!("course-learning-v1\0{revision}"), sections)
}

#[cfg(test)]
mod tests;
