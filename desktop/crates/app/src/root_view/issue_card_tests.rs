//! issue 卡信息层级：章节 kicker、单元类型、objective 掌握态/验收/rubric。

use super::RootView;
use crate::i18n::Language;
use crate::root_view::state::MediaState;
use crate::theme::ThemePreference;
use cgc_courses::catalog::{CourseCatalogService, CoursesApi, FakeCoursesApi};
use cgc_courses::content::{CourseChecklistItem, CourseObjective, MaterialKind, TypedMaterial};
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
    }];
    issue.story_materials.push(TypedMaterial {
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
        kind: MaterialKind::Image,
        title: None,
        body: None,
        url: Some(IMAGE_URL.into()),
        alt_text: Some("插图".into()),
        caption: Some("图 1".into()),
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
        assert!(window.try_find("issue-card-objective-obj-1").is_some());
        assert!(window.try_find("issue-card-assessment-obj-1").is_some());
        assert!(window.try_find("issue-card-rubric-obj-1").is_some());
        assert!(window.try_find("issue-card-mastery-obj-1").is_some());
        assert!(window.try_find("issue-video-2").is_some());
        assert!(window.try_find("issue-image-3").is_some());
    })
    .unwrap();
}
