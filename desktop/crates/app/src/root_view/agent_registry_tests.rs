//! Agent Registry：DSH Desktop 检测信息在 Ready 状态展示，不阻断安装/启动。

use super::RootView;
use crate::i18n::Language;
use crate::theme::ThemePreference;
use cgc_platform::agent::detect::{AgentStatus, DetectedAgent};
use cgc_platform::agent::dsh_runtime::{RuntimeProbe, RuntimeSource};
use cgc_platform::registry::manifest::Registry;
use cgc_platform::session::{FakeAuthApi, MemoryStore, SessionService};
use gpui_kit::test::{TestQueryExt, TestWindowExt};
use gpui_kit::{
    div, px, size, AppContext, Bounds, Context, Entity, IntoElement, ParentElement, Render, Styled,
    TestAppContext, Window, WindowBounds, WindowOptions,
};

struct AgentRegistryProbe {
    root: Entity<RootView>,
}

impl Render for AgentRegistryProbe {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let registry = self.root.update(cx, |root, cx| {
            let language = root.language;
            let palette = crate::theme::palette(gpui_kit::component::ThemeMode::Light);
            let mut context = crate::root_view::screens::ScreenContext::new(&mut root.state);
            crate::root_view::screens::render_agent_registry(&mut context, language, &palette, cx)
        });
        div().size(px(900.0)).flex().flex_col().child(registry)
    }
}

fn registry_rows(statuses: &[(&'static str, AgentStatus)]) -> Vec<DetectedAgent> {
    rows_with_runtime(
        statuses
            .iter()
            .map(|(id, status)| (*id, status.clone(), RuntimeProbe::missing())),
    )
}

fn rows_with_runtime(
    rows: impl IntoIterator<Item = (&'static str, AgentStatus, RuntimeProbe)>,
) -> Vec<DetectedAgent> {
    let registry = Registry::builtin().expect("builtin registry");
    rows.into_iter()
        .map(|(id, status, runtime)| DetectedAgent {
            entry: registry.get(id).expect("registry entry").clone(),
            status,
            runtime,
        })
        .collect()
}

fn open_registry(
    cx: &mut TestAppContext,
    language: Language,
    rows: Vec<DetectedAgent>,
) -> gpui_kit::AnyWindowHandle {
    cx.update(gpui_kit::init);
    cx.update(|cx| {
        let (handle, _probe) = gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(900.), px(640.)),
                    cx,
                ))),
                ..Default::default()
            },
            cx,
            |_, cx| {
                let root = cx.new(|_| {
                    let mut root = RootView::with_session_from(
                        crate::registration::build_registry().expect("routes"),
                        language,
                        ThemePreference::Light,
                        SessionService::new(
                            Box::new(FakeAuthApi::demo()),
                            Box::new(MemoryStore::default()),
                        ),
                        "/agents",
                    );
                    root.state.agent_registry_rows = rows;
                    root
                });
                cx.new(|_| AgentRegistryProbe { root })
            },
        )
        .expect("registry probe window");
        handle
    })
}

fn detected_desktop(desktop: &str, bundled: &str) -> RuntimeProbe {
    RuntimeProbe {
        found: true,
        version: Some(desktop.to_string()),
        source: RuntimeSource::DshDesktop,
        path: Some("/Applications/DSH Desktop.app/Contents/Resources/runtime/cli/bin/dsh".into()),
        bundled_version: Some(bundled.to_string()),
    }
}

fn bundled_only(bundled: &str) -> RuntimeProbe {
    RuntimeProbe {
        found: false,
        version: None,
        source: RuntimeSource::Missing,
        path: None,
        bundled_version: Some(bundled.to_string()),
    }
}

#[gpui_kit::test]
fn ready_with_dsh_desktop_shows_versions_without_changing_install_state(cx: &mut TestAppContext) {
    let rows = rows_with_runtime([(
        "deepseek",
        AgentStatus::Ready {
            version: "0.4.41".to_string(),
        },
        detected_desktop("0.2.2-rc.1", "0.2.1-rc.5"),
    )]);
    let handle = open_registry(cx, Language::Zh, rows);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(
            window
                .try_find_by_label("检测到 DSH Desktop 0.2.2-rc.1；本次使用内置运行时 0.2.1-rc.5")
                .is_some(),
            "Ready + 检测到 Desktop 时必须同时展示 Desktop 版本与内置运行时版本"
        );
        assert!(
            window.try_find("agent-install-deepseek").is_none(),
            "已安装的 Ready 行保持不显示安装按钮（安装状态不变）"
        );
    })
    .unwrap();
}

#[gpui_kit::test]
fn ready_without_dsh_desktop_uses_bundled_and_offers_optional_download(cx: &mut TestAppContext) {
    let rows = rows_with_runtime([(
        "deepseek",
        AgentStatus::Ready {
            version: "0.4.41".to_string(),
        },
        bundled_only("0.2.1-rc.5"),
    )]);
    let handle = open_registry(cx, Language::Zh, rows);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(
            window
                .try_find_by_label(
                    "未检测到 DSH Desktop；不影响使用，将使用内置运行时（0.2.1-rc.5）"
                )
                .is_some(),
            "Ready + 未检测到 Desktop 时必须明确说明使用内置运行时"
        );
        assert!(
            window.try_find_by_label("下载 DSH Desktop").is_some(),
            "未检测到 Desktop 时保留可选下载入口"
        );
        assert!(
            window.try_find("agent-install-deepseek").is_none(),
            "已安装的 Ready 行保持不显示安装按钮（安装状态不变）"
        );
    })
    .unwrap();
}

#[gpui_kit::test]
fn existing_install_states_keep_the_install_button_enabled(cx: &mut TestAppContext) {
    let rows = rows_with_runtime([
        ("codex", AgentStatus::Missing, RuntimeProbe::missing()),
        (
            "claude_code",
            AgentStatus::Outdated {
                found: "0.90.0".to_string(),
                required: "0.94.0".to_string(),
            },
            RuntimeProbe::missing(),
        ),
        (
            "deepseek",
            AgentStatus::NodeUnavailable {
                required: "24.0.0".to_string(),
                found: None,
            },
            RuntimeProbe::missing(),
        ),
    ]);
    let handle = open_registry(cx, Language::En, rows);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        for id in ["codex", "claude_code", "deepseek"] {
            assert_ne!(
                window.find(format!("agent-install-{id}")).disabled(),
                Some(true),
                "existing states must keep install enabled for {id}"
            );
        }
        assert!(
            window
                .try_find_by_label(
                    "DSH Desktop not detected. No impact: the bundled runtime will be used."
                )
                .is_some(),
            "openma 条目即使未检测到 Desktop 也展示信息行"
        );
    })
    .unwrap();
}
