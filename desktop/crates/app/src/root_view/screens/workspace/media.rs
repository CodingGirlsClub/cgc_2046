//! 课程材料的 section 渲染：行内完成勾选、按 kind 打开、Markdown 本页展开。
//!
//! 文本/Markdown 使用安全净化与公式渲染；图片走受限下载 + 内存缓存 +
//! 应用内 Image Viewer；视频不做内嵌播放器（ADR-0024 无 WebView），
//! 点击用系统浏览器打开 B 站页面；网页同样交给外部浏览器。

use super::super::super::*;
use super::super::ScreenContext;
use crate::root_view::state::MediaState;
use cgc_courses::content::{MaterialKind, TypedMaterial};
use gpui_kit::base::SelectableText;
use gpui_kit::component::checkbox::Checkbox;
use gpui_kit::component::collapsible::Collapsible;
use gpui_kit::component::list::ListItem;
use std::collections::BTreeSet;
use std::sync::Arc;

/// 内存里最多保留的图片数；超出后按 URL 顺序淘汰最前面的一张。
pub(in crate::root_view) const MEDIA_CACHE_LIMIT: usize = 20;
const MAX_DECODED_EDGE: u32 = 4096;

/// 材料进度的作用域：course + revision + issue。
pub(in crate::root_view) fn material_scope(
    course_id: &str,
    revision: Option<i64>,
    issue_id: &str,
) -> String {
    let revision = revision
        .map(|value| value.to_string())
        .unwrap_or_else(|| "unversioned".into());
    format!("{course_id}:{revision}:{issue_id}")
}

/// 材料 key：优先内容提供的稳定 id，缺失时回退到 Issue 内序号。
pub(in crate::root_view) fn material_key(
    scope: &str,
    material: &TypedMaterial,
    index: usize,
) -> String {
    let id = material
        .id
        .as_deref()
        .filter(|id| !id.trim().is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| format!("#{index}"));
    format!("{scope}:{id}")
}

fn material_kind_icon(kind: &MaterialKind) -> AssetIcon {
    match kind {
        MaterialKind::Text | MaterialKind::Markdown | MaterialKind::Unknown(_) => {
            AssetIcon::FileText
        }
        MaterialKind::Image => AssetIcon::Image,
        MaterialKind::Video => AssetIcon::Video,
        MaterialKind::Web => AssetIcon::Link,
    }
}

fn material_kind_label(language: Language, kind: &MaterialKind) -> &'static str {
    match kind {
        MaterialKind::Text => translate(language, Key::CoursesLearningMaterialKindShortText),
        MaterialKind::Markdown => translate(language, Key::CoursesLearningMaterialKindText),
        MaterialKind::Image => translate(language, Key::CoursesLearningMaterialKindImage),
        MaterialKind::Video => translate(language, Key::CoursesLearningVideo),
        MaterialKind::Web => translate(language, Key::CoursesLearningMaterialKindWeb),
        MaterialKind::Unknown(_) => translate(language, Key::CoursesLearningMaterialKindUnknown),
    }
}

fn material_display_title(material: &TypedMaterial, language: Language) -> String {
    material
        .title
        .as_deref()
        .filter(|title| !title.trim().is_empty())
        .or_else(|| {
            material
                .alt_text
                .as_deref()
                .filter(|alt| !alt.trim().is_empty())
        })
        .map(str::to_string)
        .unwrap_or_else(|| material_kind_label(language, &material.kind).to_string())
}

fn completed_count(keys: &[String], completed: &BTreeSet<String>) -> usize {
    keys.iter().filter(|key| completed.contains(*key)).count()
}

fn image_action_label(state: Option<&MediaState>, language: Language) -> &'static str {
    match state {
        Some(MediaState::Ready(_)) => translate(language, Key::CoursesLearningMaterialOpen),
        Some(MediaState::Loading) => translate(language, Key::CoursesLearningImageLoading),
        Some(MediaState::Failed) => translate(language, Key::CoursesLearningMaterialRetry),
        None => translate(language, Key::CoursesLearningMaterialOpen),
    }
}

pub(in crate::root_view) fn open_image_material(
    ctx: &mut ScreenContext<'_>,
    url: &str,
    title: &str,
    cx: &mut Context<RootView>,
) {
    match ctx.media_cache.get(url) {
        Some(MediaState::Ready(image)) => {
            let focus = cx.focus_handle();
            crate::image_viewer::open(title.to_string(), image.clone(), focus, cx);
        }
        Some(MediaState::Failed) => {
            ctx.media_cache.remove(url);
            ctx.pending_image_opens
                .insert(url.to_string(), title.to_string());
            ensure_image(ctx, url, cx);
        }
        _ => {
            ctx.pending_image_opens
                .insert(url.to_string(), title.to_string());
            ensure_image(ctx, url, cx);
        }
    }
}

/// Issue 的 story materials section：行内勾选、按 kind 打开、Markdown 本页展开。
pub(in crate::root_view) fn material_section(
    ctx: &mut ScreenContext<'_>,
    issue: &cgc_courses::content::CourseIssue,
    scope: &str,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let total = issue.story_materials.len();
    let material_keys = issue
        .story_materials
        .iter()
        .enumerate()
        .map(|(index, material)| material_key(scope, material, index))
        .collect::<Vec<_>>();
    let completed = completed_count(&material_keys, &ctx.completed_materials);
    let expanded = ctx.expanded_material.get(scope).cloned();
    let issue_id = issue.id.as_deref().unwrap_or("issue");
    let root = cx.entity().downgrade();
    let mut rows: Vec<AnyElement> = Vec::new();

    for (index, material) in issue.story_materials.iter().enumerate() {
        let key = material_keys[index].clone();
        let done = ctx.completed_materials.contains(&key);
        let is_expanded = expanded.as_deref() == Some(key.as_str());
        let title = material_display_title(material, language);
        let accessible_title = material
            .alt_text
            .as_deref()
            .filter(|alt| !alt.trim().is_empty())
            .map(str::to_string)
            .unwrap_or_else(|| title.clone());
        let row_id = format!("issue-material-{issue_id}-{index}");

        let key_for_check = key.clone();
        let root_for_check = root.clone();
        let checkbox = Checkbox::new(SharedString::from(format!(
            "material-done-{issue_id}-{index}"
        )))
        .checked(done)
        .accessibility_label(title.clone())
        .on_change(move |checked, _, cx| {
            let _ = root_for_check.update(cx, |this, cx| {
                if *checked {
                    this.completed_materials.insert(key_for_check.clone());
                } else {
                    this.completed_materials.remove(&key_for_check);
                }
                cx.notify();
            });
        });

        let title_base = || {
            div()
                .flex()
                .flex_1()
                .min_w(px(0.0))
                .flex_row()
                .items_center()
                .gap(px(6.0))
                .child(
                    div()
                        .text_size(px(13.0))
                        .text_color(palette.ink)
                        .child(title.clone()),
                )
        };

        let title_group: AnyElement = match &material.kind {
            MaterialKind::Markdown => {
                let key_for_toggle = key.clone();
                let scope_for_toggle = scope.to_string();
                let root_for_toggle = root.clone();
                title_base()
                    .child(div().text_size(px(12.0)).text_color(palette.accent).child(
                        if is_expanded {
                            translate(language, Key::CoursesLearningMaterialCollapse)
                        } else {
                            translate(language, Key::CoursesLearningMaterialReadFull)
                        },
                    ))
                    .id(SharedString::from(format!(
                        "material-expand-{issue_id}-{index}"
                    )))
                    .test_support()
                    .on_click(move |_, _, cx| {
                        let _ = root_for_toggle.update(cx, |this, cx| {
                            if this
                                .expanded_material
                                .get(&scope_for_toggle)
                                .map(String::as_str)
                                == Some(key_for_toggle.as_str())
                            {
                                this.expanded_material.remove(&scope_for_toggle);
                            } else {
                                this.expanded_material
                                    .insert(scope_for_toggle.clone(), key_for_toggle.clone());
                            }
                            cx.notify();
                        });
                    })
                    .into_any_element()
            }
            MaterialKind::Image => {
                if let Some(url) = material
                    .url
                    .as_deref()
                    .filter(|url| cgc_platform::api::media::is_allowed_media_url(url))
                {
                    let title_for_open = title.clone();
                    let url_for_open = url.to_string();
                    let root_for_open = root.clone();
                    let state = ctx.media_cache.get(url);
                    let action_label = image_action_label(state, language);
                    let show_label =
                        matches!(state, Some(MediaState::Loading) | Some(MediaState::Failed));
                    let mut group = title_base();
                    if show_label {
                        group = group.child(
                            div()
                                .text_size(px(12.0))
                                .text_color(palette.accent)
                                .child(action_label),
                        );
                    }
                    group = group.child(
                        Icon::default()
                            .path(AssetIcon::ArrowUpRight.path())
                            .text_color(palette.accent)
                            .small(),
                    );
                    group
                        .id(SharedString::from(format!(
                            "material-open-{issue_id}-{index}"
                        )))
                        .test_support()
                        .on_click(move |_, _, cx| {
                            let _ = root_for_open.update(cx, |this, cx| {
                                let mut screen = ScreenContext::new(&mut this.state);
                                open_image_material(
                                    &mut screen,
                                    &url_for_open,
                                    &title_for_open,
                                    cx,
                                );
                                cx.notify();
                            });
                        })
                        .into_any_element()
                } else {
                    title_base().into_any_element()
                }
            }
            MaterialKind::Video => {
                if let Some(bv) = bilibili_bv(material) {
                    let url = format!("https://www.bilibili.com/video/{bv}");
                    title_base()
                        .child(
                            Icon::default()
                                .path(AssetIcon::ArrowUpRight.path())
                                .text_color(palette.accent)
                                .small(),
                        )
                        .id(SharedString::from(format!(
                            "material-open-{issue_id}-{index}"
                        )))
                        .test_support()
                        .on_click(move |_, _, cx| cx.open_url(&url))
                        .into_any_element()
                } else {
                    title_base().into_any_element()
                }
            }
            MaterialKind::Web => {
                if let Some(url) = material
                    .url
                    .as_deref()
                    .filter(|url| url.starts_with("https://"))
                {
                    let url = url.to_string();
                    title_base()
                        .child(
                            Icon::default()
                                .path(AssetIcon::ArrowUpRight.path())
                                .text_color(palette.accent)
                                .small(),
                        )
                        .id(SharedString::from(format!(
                            "material-open-{issue_id}-{index}"
                        )))
                        .test_support()
                        .on_click(move |_, _, cx| cx.open_url(&url))
                        .into_any_element()
                } else {
                    title_base().into_any_element()
                }
            }
            _ => title_base().into_any_element(),
        };

        let mut row = ListItem::new(SharedString::from(row_id.clone()))
            .accessibility_label(accessible_title.clone())
            .child(
                div()
                    .flex()
                    .flex_1()
                    .min_w(px(0.0))
                    .flex_row()
                    .items_center()
                    .gap(px(8.0))
                    .child(checkbox)
                    .child(
                        Icon::default()
                            .path(material_kind_icon(&material.kind).path())
                            .text_color(palette.ink_3)
                            .small(),
                    )
                    .child(title_group)
                    .child(
                        div()
                            .flex_none()
                            .text_size(px(10.0))
                            .text_color(palette.ink_3)
                            .child(material_kind_label(language, &material.kind)),
                    ),
            );
        if index + 1 < total {
            row = row.border_b_1().border_color(palette.line);
        }
        rows.push(row.into_any_element());

        if let Some(body) = material
            .body
            .as_deref()
            .filter(|body| !body.trim().is_empty())
        {
            match material.kind {
                MaterialKind::Text => {
                    rows.push(
                        div()
                            .id(SharedString::from(format!(
                                "material-body-{issue_id}-{index}"
                            )))
                            .test_support()
                            .w_full()
                            .min_w(px(0.0))
                            .pl(px(44.0))
                            .pr(px(8.0))
                            .pb(px(8.0))
                            .text_size(px(13.0))
                            .text_color(palette.ink_2)
                            .child(SelectableText::new(
                                SharedString::from(format!(
                                    "material-body-text-{issue_id}-{index}"
                                )),
                                body.to_string(),
                            ))
                            .into_any_element(),
                    );
                }
                MaterialKind::Markdown => {
                    rows.push(
                        div()
                            .id(SharedString::from(format!(
                                "material-expanded-{issue_id}-{index}"
                            )))
                            .test_support()
                            .w_full()
                            .min_w(px(0.0))
                            .child({
                                let content = if is_expanded {
                                    div()
                                        .w_full()
                                        .min_w(px(0.0))
                                        .pl(px(44.0))
                                        .pr(px(8.0))
                                        .pb(px(10.0))
                                        .children(render_markdown_with_math(
                                            body,
                                            &format!("material-{key}"),
                                            13.0,
                                            2.0,
                                            palette.ink,
                                        ))
                                } else {
                                    div()
                                };
                                Collapsible::new()
                                    .w_full()
                                    .min_w(px(0.0))
                                    .open(is_expanded)
                                    .motion_id(key.clone())
                                    .content(content)
                            })
                            .into_any_element(),
                    );
                }
                _ => {}
            }
        }

        if !matches!(material.kind, MaterialKind::Text | MaterialKind::Markdown) {
            if let Some(caption) = caption_element(material, palette) {
                rows.push(
                    div()
                        .pl(px(44.0))
                        .pr(px(8.0))
                        .pb(px(6.0))
                        .child(caption)
                        .into_any_element(),
                );
            }
        }
    }

    let header = div()
        .flex()
        .flex_row()
        .items_center()
        .justify_between()
        .pb(px(6.0))
        .child(
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap(px(6.0))
                .child(
                    Icon::default()
                        .path(AssetIcon::FileText.path())
                        .text_color(palette.accent_strong)
                        .small(),
                )
                .child(
                    div()
                        .text_size(px(11.0))
                        .text_color(palette.accent_strong)
                        .child(translate(language, Key::CoursesLearningMaterials)),
                ),
        )
        .child(
            div().text_size(px(10.0)).text_color(palette.ink_3).child(
                translate(language, Key::CoursesLearningMaterialsCompleted)
                    .replace("{done}", &completed.to_string())
                    .replace("{total}", &total.to_string()),
            ),
        );

    div()
        .id("issue-materials")
        .test_support()
        .flex()
        .flex_col()
        .w_full()
        .min_w(px(0.0))
        .child(header)
        .child(
            div()
                .flex()
                .flex_col()
                .w_full()
                .min_w(px(0.0))
                .border_1()
                .border_color(palette.line)
                .rounded(px(RADIUS_MEDIUM))
                .bg(palette.card)
                .overflow_hidden()
                .children(rows),
        )
        .into_any_element()
}

pub(in crate::root_view) fn material_element(
    ctx: &mut ScreenContext<'_>,
    material: &TypedMaterial,
    index: usize,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> Option<AnyElement> {
    match material.kind {
        MaterialKind::Text | MaterialKind::Markdown => text_material(material, index, palette),
        MaterialKind::Image => image_material(ctx, material, index, palette, cx),
        MaterialKind::Video => video_material(material, index, language, palette),
        MaterialKind::Web | MaterialKind::Unknown(_) => link_material(material, index, palette),
    }
}

fn text_material(
    material: &TypedMaterial,
    index: usize,
    palette: &theme::Palette,
) -> Option<AnyElement> {
    let body = material.body.as_deref()?;
    if body.trim().is_empty() {
        return None;
    }
    let content = if material.kind == MaterialKind::Markdown {
        div()
            .flex()
            .flex_col()
            .gap(px(4.0))
            .children(render_markdown_with_math(
                body,
                &format!("issue-material-{index}"),
                14.0,
                2.0,
                palette.ink,
            ))
            .into_any_element()
    } else {
        div()
            .text_size(px(14.0))
            .text_color(palette.ink_2)
            .child(SelectableText::new(
                SharedString::from(format!("issue-text-{index}")),
                body.to_string(),
            ))
            .into_any_element()
    };
    let mut elements = vec![content];
    if let Some(caption) = caption_element(material, palette) {
        elements.push(caption);
    }
    Some(
        div()
            .flex()
            .flex_col()
            .gap(px(4.0))
            .children(elements)
            .into_any_element(),
    )
}

fn image_material(
    ctx: &mut ScreenContext<'_>,
    material: &TypedMaterial,
    index: usize,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> Option<AnyElement> {
    let url = material
        .url
        .as_deref()
        .filter(|url| cgc_platform::api::media::is_allowed_media_url(url))?;
    let alt = material
        .alt_text
        .as_deref()
        .filter(|alt| !alt.trim().is_empty());
    let id = SharedString::from(format!("issue-image-{index}"));

    let body = match alt {
        None => unavailable(
            id,
            translate(ctx.language, Key::CoursesLearningImageUnavailable),
            palette,
        ),
        Some(alt) => {
            ensure_image(ctx, url, cx);
            match ctx.media_cache.get(url) {
                Some(MediaState::Ready(image)) => div()
                    .id(id)
                    .test_support()
                    .flex()
                    .flex_col()
                    .gap(px(4.0))
                    .child(
                        img(image.clone())
                            .w_full()
                            .max_w(px(680.0))
                            .rounded(px(RADIUS_MEDIUM)),
                    )
                    .aria_label(alt.to_string())
                    .children(caption_element(material, palette))
                    .into_any_element(),
                Some(MediaState::Failed) => unavailable(
                    id,
                    translate(ctx.language, Key::CoursesLearningImageFailed),
                    palette,
                ),
                _ => div()
                    .id(id)
                    .test_support()
                    .text_size(px(12.0))
                    .text_color(palette.ink_3)
                    .child(translate(ctx.language, Key::CoursesLearningImageLoading))
                    .into_any_element(),
            }
        }
    };

    Some(
        div()
            .flex()
            .flex_col()
            .gap(px(4.0))
            .child(body)
            .into_any_element(),
    )
}

fn video_material(
    material: &TypedMaterial,
    index: usize,
    language: Language,
    palette: &theme::Palette,
) -> Option<AnyElement> {
    if let Some(bv) = bilibili_bv(material) {
        let video_url = format!("https://www.bilibili.com/video/{bv}");
        let title = material
            .title
            .clone()
            .filter(|title| !title.trim().is_empty())
            .unwrap_or_else(|| translate(language, Key::CoursesLearningVideo).to_string());
        let open_url = video_url.clone();
        let play = div()
            .id(SharedString::from(format!("issue-video-{index}")))
            .test_support()
            .flex()
            .flex_row()
            .items_center()
            .justify_center()
            .gap(px(8.0))
            .h(px(160.0))
            .w_full()
            .rounded(px(RADIUS_MEDIUM))
            .bg(palette.soft)
            .child(
                div()
                    .text_size(px(16.0))
                    .text_color(palette.accent)
                    .child("▶"),
            )
            .child(
                div()
                    .text_size(px(13.0))
                    .text_color(palette.ink)
                    .child(title.clone()),
            )
            .on_click(move |_, _, cx| cx.open_url(&open_url))
            .into_any_element();
        let mut elements = vec![play];
        elements.push(
            div()
                .text_size(px(12.0))
                .text_color(palette.accent)
                .child(translate(language, Key::CoursesLearningVideoOpen))
                .into_any_element(),
        );
        if let Some(caption) = caption_element(material, palette) {
            elements.push(caption);
        }
        return Some(
            div()
                .flex()
                .flex_col()
                .gap(px(4.0))
                .children(elements)
                .into_any_element(),
        );
    }
    link_material(material, index, palette)
}

fn link_material(
    material: &TypedMaterial,
    index: usize,
    palette: &theme::Palette,
) -> Option<AnyElement> {
    let url = material
        .url
        .as_deref()
        .filter(|url| url.starts_with("https://"))?;
    let title = material
        .title
        .clone()
        .filter(|title| !title.trim().is_empty())
        .unwrap_or_else(|| url.to_string());
    let open_url = url.to_string();
    Some(
        div()
            .flex()
            .flex_col()
            .gap(px(4.0))
            .child(
                div()
                    .id(SharedString::from(format!("issue-link-{index}")))
                    .test_support()
                    .text_size(px(12.0))
                    .text_color(palette.accent)
                    .child(title)
                    .on_click(move |_, _, cx| cx.open_url(&open_url)),
            )
            .children(caption_element(material, palette))
            .into_any_element(),
    )
}

fn caption_element(material: &TypedMaterial, palette: &theme::Palette) -> Option<AnyElement> {
    material
        .caption
        .clone()
        .filter(|caption| !caption.trim().is_empty())
        .map(|caption| {
            div()
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(caption)
                .into_any_element()
        })
}

fn unavailable(id: SharedString, label: &'static str, palette: &theme::Palette) -> AnyElement {
    div()
        .id(id)
        .test_support()
        .text_size(px(12.0))
        .text_color(palette.ink_3)
        .child(label)
        .into_any_element()
}

/// B 站 BV 号：`^BV[0-9A-Za-z]{10}$`。
fn bilibili_bv(material: &TypedMaterial) -> Option<&str> {
    if material.provider.as_deref() != Some("bilibili") {
        return None;
    }
    let bv = material.external_id.as_deref()?;
    let bytes = bv.as_bytes();
    if bytes.len() == 12 && bv.starts_with("BV") && bytes[2..].iter().all(u8::is_ascii_alphanumeric)
    {
        Some(bv)
    } else {
        None
    }
}

/// 首次遇到图片时发起后台下载；`media_loading` 防止每帧重复请求。
fn ensure_image(ctx: &mut ScreenContext<'_>, url: &str, cx: &mut Context<RootView>) {
    if ctx.media_cache.contains_key(url) || ctx.media_loading.contains(url) {
        return;
    }
    ctx.media_loading.insert(url.to_string());
    ctx.media_cache.insert(url.to_string(), MediaState::Loading);
    let url = url.to_string();
    cx.spawn(async move |this, cx| {
        let fetched = cx
            .background_executor()
            .spawn({
                let url = url.clone();
                async move {
                    let bytes = cgc_platform::api::media::fetch_image(&url)
                        .map_err(|error| error.to_string())?;
                    decode_render_image(&bytes)
                        .map(Arc::new)
                        .ok_or_else(|| "image decode failed".to_string())
                }
            })
            .await;
        let _ = this.update(cx, |this, cx| {
            this.media_loading.remove(&url);
            let state = match fetched {
                Ok(image) => MediaState::Ready(image),
                Err(_) => MediaState::Failed,
            };
            this.media_cache.insert(url.clone(), state);
            let pending_title = this.pending_image_opens.remove(&url);
            if let Some(title) = pending_title {
                let image = this.media_cache.get(&url).and_then(|state| match state {
                    MediaState::Ready(image) => Some(image.clone()),
                    _ => None,
                });
                if let Some(image) = image {
                    let focus = cx.focus_handle();
                    crate::image_viewer::open(title, image, focus, cx);
                }
            }
            while this.media_cache.len() > MEDIA_CACHE_LIMIT {
                let Some(oldest) = this.media_cache.keys().next().cloned() else {
                    break;
                };
                this.media_cache.remove(&oldest);
            }
            cx.notify();
        });
    })
    .detach();
}

/// 解码 + 限制异常大图，返回 GPUI 可直接绘制的图像。
fn decode_render_image(bytes: &[u8]) -> Option<RenderImage> {
    let reader = image::ImageReader::new(std::io::Cursor::new(bytes))
        .with_guessed_format()
        .ok()?;
    let (width, height) = reader.into_dimensions().ok()?;
    if width == 0 || height == 0 || width > MAX_DECODED_EDGE || height > MAX_DECODED_EDGE {
        return None;
    }
    let decoded = image::load_from_memory(bytes).ok()?;
    Some(RenderImage::new(vec![image::Frame::new(
        decoded.into_rgba8(),
    )]))
}

#[cfg(test)]
mod tests {
    use super::{
        bilibili_bv, completed_count, decode_render_image, image_action_label, material_key,
        material_scope,
    };
    use crate::i18n::{translate, Key, Language};
    use crate::root_view::state::MediaState;
    use cgc_courses::content::{MaterialKind, TypedMaterial};
    use std::collections::BTreeSet;

    fn material(kind: MaterialKind) -> TypedMaterial {
        TypedMaterial {
            id: None,
            kind,
            title: None,
            body: None,
            url: None,
            alt_text: None,
            caption: None,
            provider: None,
            external_id: None,
        }
    }

    #[test]
    fn bilibili_requires_bv_prefix_and_length() {
        let mut video = material(MaterialKind::Video);
        video.provider = Some("bilibili".into());
        video.external_id = Some("BV1xx411c7mD".into());
        assert_eq!(bilibili_bv(&video), Some("BV1xx411c7mD"));

        video.external_id = Some("av123".into());
        assert_eq!(bilibili_bv(&video), None);
        video.external_id = Some("BV1xx".into());
        assert_eq!(bilibili_bv(&video), None);
        video.provider = Some("other".into());
        assert_eq!(bilibili_bv(&video), None);
    }

    #[test]
    fn material_key_prefers_id_and_falls_back_to_index() {
        let mut item = material(MaterialKind::Text);
        item.id = Some("mat-a".into());
        let scope = material_scope("crs-1", Some(3), "issue-1");
        assert_eq!(scope, "crs-1:3:issue-1");
        assert_eq!(material_key(&scope, &item, 2), "crs-1:3:issue-1:mat-a");

        item.id = None;
        assert_eq!(material_key(&scope, &item, 2), "crs-1:3:issue-1:#2");

        item.id = Some("  ".into());
        assert_eq!(material_key(&scope, &item, 2), "crs-1:3:issue-1:#2");
    }

    #[test]
    fn image_action_label_matches_cache_state() {
        let language = Language::Zh;
        assert_eq!(
            image_action_label(None, language),
            translate(language, Key::CoursesLearningMaterialOpen)
        );
        assert_eq!(
            image_action_label(Some(&MediaState::Loading), language),
            translate(language, Key::CoursesLearningImageLoading)
        );
        assert_eq!(
            image_action_label(Some(&MediaState::Failed), language),
            translate(language, Key::CoursesLearningMaterialRetry)
        );
    }

    #[test]
    fn completed_count_ignores_stale_keys() {
        let keys = vec!["scope:a".to_string(), "scope:b".to_string()];
        let completed = BTreeSet::from(["scope:a".to_string(), "scope:stale".to_string()]);
        assert_eq!(completed_count(&keys, &completed), 1);
    }

    #[test]
    fn decodes_a_png_and_rejects_garbage() {
        // 1x1 透明 PNG。
        const PNG: &[u8] = &[
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48,
            0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00,
            0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78,
            0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
        ];
        assert!(decode_render_image(PNG).is_some());
        assert!(decode_render_image(b"not an image").is_none());
    }
}
