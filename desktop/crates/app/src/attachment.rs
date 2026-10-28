//! 图片附件管线（B4a-2：从 `native_agent_view.rs` 迁出，供共享附件层复用）。
//!
//! 编码/降采样/预览与已发送图片解码；不依赖 GPUI 窗口，只有预览图用 `RenderImage`。

use std::sync::Arc;

use base64::Engine as _;
use cgc_agent_core::ImageAttachment;
use gpui_kit::RenderImage;
use image::GenericImageView as _;

/// 与 Zed `language_model::request` 对齐：单图编码后 PNG ≤5MB，最长边 1568px。
const ANTHROPIC_SIZE_LIMIT: u32 = 1568;
const IMAGE_MAX_BYTES: usize = 5 * 1024 * 1024;
const MAX_IMAGE_DOWNSCALE_PASSES: usize = 8;

pub(crate) fn encode_png(image: &image::DynamicImage) -> Option<Vec<u8>> {
    let mut cursor = std::io::Cursor::new(Vec::new());
    image.write_to(&mut cursor, image::ImageFormat::Png).ok()?;
    Some(cursor.into_inner())
}

/// 解码 → 尺寸降采样 → PNG 重编码 → 5MB 内迭代缩放。返回 (png 字节, 预览图)。
pub(crate) fn prepare_clipboard_image(bytes: &[u8]) -> Option<(Vec<u8>, Arc<RenderImage>)> {
    let mut decoded = image::load_from_memory(bytes).ok()?;
    let (width, height) = decoded.dimensions();
    if width > ANTHROPIC_SIZE_LIMIT || height > ANTHROPIC_SIZE_LIMIT {
        let scale = ANTHROPIC_SIZE_LIMIT as f32 / width.max(height) as f32;
        decoded = decoded.resize(
            ((width as f32) * scale).round().max(1.0) as u32,
            ((height as f32) * scale).round().max(1.0) as u32,
            image::imageops::FilterType::Triangle,
        );
    }
    let mut png = encode_png(&decoded)?;
    for _ in 0..MAX_IMAGE_DOWNSCALE_PASSES {
        if png.len() <= IMAGE_MAX_BYTES {
            break;
        }
        let (width, height) = decoded.dimensions();
        if width <= 1 || height <= 1 {
            break;
        }
        decoded = decoded.resize(
            ((width as f32) * 0.85).round().max(1.0) as u32,
            ((height as f32) * 0.85).round().max(1.0) as u32,
            image::imageops::FilterType::Triangle,
        );
        png = encode_png(&decoded)?;
    }
    if png.len() > IMAGE_MAX_BYTES {
        return None;
    }
    let preview = Arc::new(RenderImage::new(vec![image::Frame::new(
        decoded.into_rgba8(),
    )]));
    Some((png, preview))
}

/// 已发送消息里展示用的图片引用（chip + 悬停预览）。
#[derive(Clone)]
pub(crate) struct SentImage {
    pub(crate) name: String,
    pub(crate) preview: Option<Arc<RenderImage>>,
}

pub(crate) fn is_image_path(path: &std::path::Path) -> bool {
    matches!(
        path.extension()
            .and_then(|extension| extension.to_str())
            .map(str::to_ascii_lowercase)
            .as_deref(),
        Some("png" | "jpg" | "jpeg" | "webp" | "gif")
    )
}

pub(crate) fn decode_sent_images(images: &[ImageAttachment]) -> Vec<SentImage> {
    images
        .iter()
        .map(|image| SentImage {
            name: if image.name.is_empty() {
                "image.png".to_string()
            } else {
                image.name.clone()
            },
            preview: base64::engine::general_purpose::STANDARD
                .decode(image.data.as_bytes())
                .ok()
                .and_then(|bytes| prepare_clipboard_image(&bytes))
                .map(|(_, preview)| preview),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{decode_sent_images, encode_png, prepare_clipboard_image};
    use base64::Engine as _;
    use cgc_agent_core::ImageAttachment;
    use image::GenericImageView as _;

    fn tiny_image() -> image::DynamicImage {
        image::DynamicImage::ImageRgba8(image::RgbaImage::from_pixel(
            4,
            4,
            image::Rgba([200, 30, 40, 255]),
        ))
    }

    #[test]
    fn encode_png_roundtrip() {
        let image = tiny_image();
        let bytes = encode_png(&image).expect("encode");
        let decoded = image::load_from_memory(&bytes).expect("decode");
        assert_eq!(decoded.dimensions(), (4, 4));
        assert_eq!(decoded.to_rgba8().get_pixel(0, 0).0, [200, 30, 40, 255]);
    }

    #[test]
    fn prepare_clipboard_image_produces_png_and_preview() {
        let png = encode_png(&tiny_image()).expect("encode");
        let (out, preview) = prepare_clipboard_image(&png).expect("prepare");
        assert!(!out.is_empty());
        assert!(out.len() <= super::IMAGE_MAX_BYTES);
        let _ = preview;
    }

    #[test]
    fn decode_sent_images_uses_fallback_name_and_tolerates_bad_data() {
        let png = encode_png(&tiny_image()).expect("encode");
        let data = base64::engine::general_purpose::STANDARD.encode(png);
        let images = vec![
            ImageAttachment {
                name: String::new(),
                mime_type: "image/png".into(),
                data: data.clone(),
            },
            ImageAttachment {
                name: "bad.png".into(),
                mime_type: "image/png".into(),
                data: "not-base64".into(),
            },
        ];
        let decoded = decode_sent_images(&images);
        assert_eq!(decoded[0].name, "image.png");
        assert!(decoded[0].preview.is_some(), "合法 PNG 应有预览");
        assert!(decoded[1].preview.is_none(), "坏数据不应 panic，预览为空");
    }
}
