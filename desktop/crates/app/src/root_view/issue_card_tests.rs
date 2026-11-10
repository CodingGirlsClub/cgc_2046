//! issue 卡信息层级：章节 kicker、单元类型、objective 掌握态/验收/rubric。

use super::RootView;
use crate::i18n::Language;
use crate::root_view::state::MediaState;
use crate::theme::ThemePreference;
use cgc_courses::catalog::{CourseCatalogService, CoursesApi, FakeCoursesApi};
use cgc_courses::content::{
    AgentActionSpec, AgentIntent, CourseChecklistItem, CourseObjective, MaterialKind, TypedMaterial,
};
use cgc_courses::projection::{LearningProjection, LearningProjectionService, ObjectiveState};
use cgc_platform::session::{FakeAuthApi, MemoryStore, SessionService};
use gpui_kit::test::TestWindowExt;
use gpui_kit::{
    div, px, size, AppContext, Bounds, Context, Entity, IntoElement, ParentElement, Render, Styled,
    TestAppContext, Window, WindowBounds, WindowOptions,
};
use std::sync::Arc;

struct IssueCardProbe {
    root: Entity<RootView>,
}

impl Render for IssueCardProbe {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let area = self.root.update(cx, |root, cx| {
            let palette = crate::theme::palette(gpui_kit::component::ThemeMode::Light);
            let mut context = crate::root_view::screens::ScreenContext::new(&mut root.state);
            crate::root_view::screens::render_issue_card(
                &mut context,
                "crs-000",
                "issue-1",
                Language::Zh,
                &palette,
                cx,
            )
        });
        div().size(px(760.0)).flex().flex_col().child(area)
    }
}

fn issue_card_window(cx: &mut TestAppContext) -> (gpui_kit::AnyWindowHandle, Entity<RootView>) {
    cx.update(gpui_kit::init);
    cx.update(|cx| {
        let (handle, probe) = gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(960.), px(720.)),
                    cx,
                ))),
                ..Default::default()
            },
            cx,
            |_, cx| {
                let root = cx.new(|_| {
                    RootView::with_session_from(
                        crate::registration::build_registry().expect("registry"),
                        Language::Zh,
                        ThemePreference::Light,
                        SessionService::new(
                            Box::new(FakeAuthApi::demo()),
                            Box::new(MemoryStore::default()),
                        ),
                        "/w/2046/courses",
                    )
                });
                cx.new(|_| IssueCardProbe { root: root.clone() })
            },
        )
        .expect("issue card window");
        let root = probe.read(cx).root.clone();
        (handle, root)
    })
}

const IMAGE_URL: &str = "https://cdn.example.com/a.png";

fn card_content() -> cgc_courses::content::CourseContent {
    let api = FakeCoursesApi::with_seed(5);
    let mut content = api
        .get_course_content(None, "crs-000")
        .expect("published course content");
    let issue = content
        .document
        .issues
        .first_mut()
        .expect("fake content has one issue");
    issue.chapter_id = Some("ch-1".into());
    issue.kind = Some("thoughtwork".into());
    issue.goal = Some("理解物理学的研究对象与学科定位".into());
    issue.as_a = Some("刚接触物理的八年级学员".into());
    issue.given = vec!["已读完第一章".into()];
    issue.checklist = vec![CourseChecklistItem {
        id: Some("check-1".into()),
        text: "只给 agent 的清单".into(),
    }];
    issue.objectives = vec![CourseObjective {
        id: Some("obj-1".into()),
        title: Some("理解物理学的对象".into()),
        required: true,
        prereq_ids: Vec::new(),
        activity: Some("阅读教材".into()),
        assessment: Some("回答诊断问题".into()),
        rubric: vec![CourseChecklistItem {
            id: Some("rubric-1".into()),
            text: "优秀：准确说出".into(),
        }],
        materials: Vec::new(),
        agent_actions: Vec::new(),
    }];
    issue.story_materials.push(TypedMaterial {
        id: Some("mat-video".into()),
        kind: MaterialKind::Video,
        title: Some("讲解视频".into()),
        body: None,
        url: None,
        alt_text: None,
        caption: None,
        provider: Some("bilibili".into()),
        external_id: Some("BV1xx411c7mD".into()),
    });
    issue.story_materials.push(TypedMaterial {
        id: Some("mat-image".into()),
        kind: MaterialKind::Image,
        title: None,
        body: None,
        url: Some(IMAGE_URL.into()),
        alt_text: Some("插图".into()),
        caption: Some("图 1".into()),
        provider: None,
        external_id: None,
    });
    issue.story_materials.push(TypedMaterial {
        id: Some("mat-text".into()),
        kind: MaterialKind::Text,
        title: Some("一句话".into()),
        body: Some("物理学研究物质及其运动规律。".into()),
        url: None,
        alt_text: None,
        caption: None,
        provider: None,
        external_id: None,
    });
    content
}

fn projection() -> LearningProjection {
    LearningProjection {
        course_id: "crs-000".into(),
        title: "八年级物理".into(),
        revision_number: Some(1),
        stale_revision: false,
        run: None,
        next_action: None,
        progress: None,
        objectives: vec![ObjectiveState {
            id: "obj-1".into(),
            title: "理解物理学的对象".into(),
            required: true,
            mastery: "mastered".into(),
            locked: false,
            attempt_count: 1,
            missing_prereq_ids: Vec::new(),
        }],
        review_queue: Vec::new(),
    }
}

#[gpui_kit::test]
fn issue_card_renders_chapter_kind_assessment_and_rubric(cx: &mut TestAppContext) {
    let (handle, root) = issue_card_window(cx);
    root.update(cx, |root, _| {
        root.courses = CourseCatalogService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        root.content.adopt(card_content());
        // 避免测试触发真实网络下载；图片走失败态分支。
        root.media_cache
            .insert(IMAGE_URL.into(), MediaState::Failed);
        root.projection = LearningProjectionService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        root.projection.adopt(projection());
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(root.read(cx).content.content().is_some(), "content adopted");
        assert!(
            window.try_find("issue-card").is_some(),
            "card root rendered"
        );
        assert!(window.try_find("issue-card-kicker").is_some());
        assert!(window.try_find("issue-card-kind").is_some());
        assert!(window.try_find("issue-card-user-story").is_some());
        assert!(window.try_find("issue-card-story-as").is_some());
        assert!(window.try_find("issue-card-story-given").is_some());
        assert!(window.try_find("issue-card-story-goal").is_some());
        assert!(window.try_find("issue-card-objective-obj-1").is_some());
        assert!(window.try_find("issue-card-assessment-obj-1").is_some());
        assert!(window.try_find("issue-card-rubric-obj-1").is_some());
        assert!(window.try_find("issue-card-mastery-obj-1").is_some());
        assert!(window.try_find("issue-materials").is_some());
        for index in 0..5 {
            assert!(
                window
                    .try_find(format!("issue-material-issue-1-{index}"))
                    .is_some(),
                "material row {index}"
            );
        }
        assert!(window.try_find("material-expand-issue-1-0").is_some());
        assert!(window.try_find("material-body-issue-1-4").is_some());
        assert!(window.try_find("material-open-issue-1-1").is_some());
        assert!(window.try_find("material-open-issue-1-2").is_some());
        assert!(window.try_find("material-open-issue-1-3").is_some());
        window.click("material-expand-issue-1-0", cx);
        assert!(root
            .read(cx)
            .expanded_material
            .values()
            .any(|key| key.ends_with(":mat-md")));
        window.click("material-done-issue-1-0", cx);
        assert!(root
            .read(cx)
            .completed_materials
            .iter()
            .any(|key| key.ends_with(":mat-md")));
    })
    .unwrap();
}

#[gpui_kit::test]
fn issue_card_switches_selected_objective(cx: &mut TestAppContext) {
    let (handle, root) = issue_card_window(cx);
    root.update(cx, |root, _| {
        root.courses = CourseCatalogService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        let mut content = card_content();
        content
            .document
            .issues
            .first_mut()
            .expect("fake content has one issue")
            .objectives
            .push(CourseObjective {
                id: Some("obj-2".into()),
                title: Some("理解测量单位".into()),
                required: false,
                prereq_ids: Vec::new(),
                activity: None,
                assessment: None,
                rubric: Vec::new(),
                materials: Vec::new(),
                agent_actions: Vec::new(),
            });
        root.content.adopt(content);
        root.projection = LearningProjectionService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        root.projection.adopt(projection());
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(window.try_find("issue-objective-practice").is_some());
        assert!(window.try_find("issue-objective-row-obj-1").is_some());
        assert!(window.try_find("issue-objective-row-obj-2").is_some());
        assert!(window.try_find("issue-card-objective-obj-1").is_some());
        assert!(window.try_find("issue-card-objective-obj-2").is_none());

        window.click("issue-objective-row-obj-2", cx);
        assert!(root
            .read(cx)
            .selected_objective
            .values()
            .any(|id| id == "obj-2"));
        assert!(window.try_find("issue-card-objective-obj-2").is_some());
        assert!(window.try_find("issue-card-objective-obj-1").is_none());
    })
    .unwrap();
}

#[gpui_kit::test]
fn issue_card_cta_dispatches_agent_call_to_composer(cx: &mut TestAppContext) {
    let (handle, root) = issue_card_window(cx);
    root.update(cx, |root, _| {
        root.courses = CourseCatalogService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        let mut content = card_content();
        content.document.issues[0].objectives[0].agent_actions = vec![
            AgentActionSpec {
                id: "a-answer".into(),
                label: "回答当前问题".into(),
                intent: AgentIntent::Answer,
                primary: true,
            },
            AgentActionSpec {
                id: "a-hint".into(),
                label: "给我一个提示".into(),
                intent: AgentIntent::Hint,
                primary: false,
            },
        ];
        root.content.adopt(content);
        root.projection = LearningProjectionService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        root.projection.adopt(projection());
        root.native_chat_mode = false;
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(window.try_find("issue-objective-actions-obj-1").is_some());
        assert!(window
            .try_find("issue-agent-action-obj-1-a-answer")
            .is_some());
        assert!(window.try_find("issue-agent-action-obj-1-a-hint").is_some());

        window.click("issue-agent-action-obj-1-a-answer", cx);
        let input = root.read(cx).chat.input.clone();
        assert!(input.contains("请根据当前目标的验收标准向我提问"));
        assert!(root.read(cx).chat.pending_agent_call.is_some());
        assert!(root.read(cx).agent_panel_open);
    })
    .unwrap();
}

#[gpui_kit::test]
fn issue_card_cta_does_not_flip_native_mode_when_initializing(cx: &mut TestAppContext) {
    let (handle, root) = issue_card_window(cx);
    root.update(cx, |root, _| {
        root.courses = CourseCatalogService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        let mut content = card_content();
        content.document.issues[0].objectives[0].agent_actions = vec![AgentActionSpec {
            id: "a-hint".into(),
            label: "给我一个提示".into(),
            intent: AgentIntent::Hint,
            primary: false,
        }];
        root.content.adopt(content);
        root.projection = LearningProjectionService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        root.projection.adopt(projection());
        root.native_chat_mode = true;
        root.native_agent_view = None;
    });
    cx.update_window(handle, |_, window, cx| {
        std::env::set_var("CGC_NATIVE_AGENT", "1");
        window.render_frame(cx);
        window.click("issue-agent-action-obj-1-a-hint", cx);
        let root = root.read(cx);
        assert!(root.native_chat_mode, "mode must stay native");
        assert!(
            root.pane_notice.is_some(),
            "user must see initializing notice"
        );
        assert!(root.chat.input.is_empty(), "no ACP fallback prefill");
    })
    .unwrap();
}

#[gpui_kit::test]
fn issue_card_practice_uses_prototype_hierarchy(cx: &mut TestAppContext) {
    let (handle, root) = issue_card_window(cx);
    root.update(cx, |root, _| {
        root.courses = CourseCatalogService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        let mut content = card_content();
        let objective = &mut content.document.issues[0].objectives[0];
        objective.materials.push(TypedMaterial {
            id: Some("obj-mat-1".into()),
            kind: MaterialKind::Text,
            title: Some("任务材料".into()),
            body: Some("任务材料正文".into()),
            url: None,
            alt_text: None,
            caption: None,
            provider: None,
            external_id: None,
        });
        root.content.adopt(content);
        root.projection = LearningProjectionService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        root.projection.adopt(projection());
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(window.try_find("issue-practice-mastered").is_some());
        assert!(window.try_find("issue-practice-mode").is_some());
        assert!(window
            .try_find("issue-objective-description-obj-1")
            .is_some());
        assert!(window.try_find("issue-card-assessment-obj-1").is_some());

        assert!(window.try_find("issue-objective-materials-obj-1").is_some());
        assert!(window
            .try_find("issue-objective-materials-toggle-obj-1")
            .is_some());
        assert!(window
            .find_all("issue-objective-material-content-obj-1")
            .is_empty());
        window.click("issue-objective-materials-toggle-obj-1", cx);
        assert!(!root.read(cx).expanded_objective_materials.is_empty());
        window.render_frame(cx);
        assert!(!window
            .find_all("issue-objective-material-content-obj-1")
            .is_empty());

        assert!(window
            .find_all("issue-objective-rubric-item-obj-1-0")
            .is_empty());
        let revision = root
            .read(cx)
            .content
            .content()
            .and_then(|content| content.revision_number)
            .map(|value| value.to_string())
            .unwrap_or_else(|| "unversioned".into());
        root.update(cx, |root, _| {
            root.expanded_objective_rubric
                .insert(format!("crs-000:{revision}:issue-1:obj-1:rubric"));
        });
        window.render_frame(cx);
        assert!(!window
            .find_all("issue-objective-rubric-item-obj-1-0")
            .is_empty());
    })
    .unwrap();
}

#[gpui_kit::test]
fn issue_card_user_story_falls_back_to_goal_only(cx: &mut TestAppContext) {
    let (handle, root) = issue_card_window(cx);
    root.update(cx, |root, _| {
        root.courses = CourseCatalogService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        let mut content = card_content();
        let issue = content
            .document
            .issues
            .first_mut()
            .expect("fake content has one issue");
        issue.as_a = None;
        issue.given.clear();
        issue.goal = Some("只写 goal 的旧内容".into());
        root.content.adopt(content);
        root.projection = LearningProjectionService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        root.projection.adopt(projection());
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(window.try_find("issue-card-user-story").is_some());
        assert!(window.try_find("issue-card-story-goal").is_some());
        assert!(window.try_find("issue-card-story-as").is_none());
        assert!(window.try_find("issue-card-story-given").is_none());
    })
    .unwrap();
}
