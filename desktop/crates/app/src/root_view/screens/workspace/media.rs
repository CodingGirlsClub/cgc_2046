//! 课程材料的渲染：文本/Markdown、图片（受限下载 + 内存缓存）、B 站视频卡、外链。
//!
//! 图片 URL 来自课程内容，下载走 `cgc_platform::api::media` 的受限客户端；
//! 视频不做内嵌播放器（ADR-0024 无 WebView），点击用系统浏览器打开 B 站页面。

use super::super::super::*;
use super::super::ScreenContext;
use crate::root_view::state::MediaState;
use cgc_courses::content::{MaterialKind, TypedMaterial};
use gpui_kit::base::SelectableText;
use std::sync::Arc;

/// 内存里最多保留的图片数；超出后按 URL 顺序淘汰最前面的一张。
pub(in crate::root_view) const MEDIA_CACHE_LIMIT: usize = 20;
const MAX_DECODED_EDGE: u32 = 4096;

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
    use super::{bilibili_bv, decode_render_image};
    use cgc_courses::content::{MaterialKind, TypedMaterial};

    fn material(kind: MaterialKind) -> TypedMaterial {
        TypedMaterial {
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
