//! 图标覆盖仅用于内部调试：启动时预读，绘制只查询覆盖快照。
//! `CGC_ICON_OVERLAY_DIR` 中与 Kit 静态图标目录同名的普通 SVG 才参与加载。

use std::borrow::Cow;
use std::collections::HashMap;
use std::ffi::OsString;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use gpui_kit::assets::{AllAssets, IconName};
use gpui_kit::component::set_icon_resolver;
use gpui_kit::{App, AssetSource, SharedString};

const ICON_OVERLAY_ENV: &str = "CGC_ICON_OVERLAY_DIR";
const OVERLAY_PREFIX: &str = "app-icons/";
const MAX_ICON_BYTES: usize = 256 * 1024;
const MAX_OVERLAY_BYTES: usize = 16 * 1024 * 1024;

struct OverlayIcon {
    resolved_path: SharedString,
    bytes: Vec<u8>,
}

/// 仅缓存成功加载的覆盖；缺失或无效文件继续使用 Kit 的原始资产路径。
#[derive(Clone, Default)]
pub struct AppAssets {
    overrides: Arc<HashMap<SharedString, OverlayIcon>>,
}

impl AppAssets {
    pub fn new(overlay_dir: Option<PathBuf>) -> Self {
        let Some(dir) = overlay_dir else {
            return Self::default();
        };
        if !std::fs::symlink_metadata(&dir).is_ok_and(|metadata| metadata.file_type().is_dir()) {
            log::warn!(target: "icon_theme", "图标覆盖目录不可用或为符号链接，使用内置图标");
            return Self::default();
        }
        let mut overrides = HashMap::new();
        let mut remaining = MAX_OVERLAY_BYTES;
        for icon in IconName::ALL {
            if remaining == 0 {
                break;
            }
            let path = icon.path();
            let name = path.strip_prefix("icons/").expect("Kit icon path");
            match read_overlay(&dir.join(name), MAX_ICON_BYTES.min(remaining)) {
                Ok(bytes) => {
                    remaining -= bytes.len();
                    let resolved_path = format!("{OVERLAY_PREFIX}{path}").into();
                    overrides.insert(
                        path,
                        OverlayIcon {
                            resolved_path,
                            bytes,
                        },
                    );
                }
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => log::warn!(
                    target: "icon_theme",
                    "覆盖图标 {name} 未加载（{:?}），使用内置图标", error.kind()
                ),
            }
        }
        Self {
            overrides: Arc::new(overrides),
        }
    }

    pub fn install_resolver(&self, cx: &mut App) {
        let assets = self.clone();
        set_icon_resolver(cx, move |path, _| assets.resolve_path(path));
    }

    fn resolve_path(&self, path: &str) -> Option<SharedString> {
        self.overrides
            .get(path)
            .map(|icon| icon.resolved_path.clone())
    }
}

fn read_overlay(path: &Path, limit: usize) -> io::Result<Vec<u8>> {
    let metadata = std::fs::symlink_metadata(path)?;
    if !metadata.file_type().is_file() || metadata.len() > limit as u64 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid icon file",
        ));
    }
    let file = std::fs::File::open(path)?;
    if !file.metadata()?.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid icon file",
        ));
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(limit as u64 + 1).read_to_end(&mut bytes)?;
    if bytes.len() > limit {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "icon exceeds size limit",
        ));
    }
    Ok(bytes)
}

impl AssetSource for AppAssets {
    fn load(&self, path: &str) -> gpui_kit::Result<Option<Cow<'static, [u8]>>> {
        if let Some(inner) = path.strip_prefix(OVERLAY_PREFIX) {
            // AssetSource 要求静态生命周期；图集未命中时必须返回拥有所有权的字节。
            return Ok(self
                .overrides
                .get(inner)
                .map(|icon| Cow::Owned(icon.bytes.clone())));
        }
        AllAssets.load(path)
    }

    fn list(&self, path: &str) -> gpui_kit::Result<Vec<SharedString>> {
        AllAssets.list(path)
    }
}

/// 读取覆盖目录：`CGC_ICON_OVERLAY_DIR` 为空或未设置时返回 `None`。
pub fn overlay_dir_from_env() -> Option<PathBuf> {
    overlay_dir_from_value(std::env::var_os(ICON_OVERLAY_ENV))
}

/// 纯函数版（单测不改进程环境）。
fn overlay_dir_from_value(value: Option<OsString>) -> Option<PathBuf> {
    value.filter(|value| !value.is_empty()).map(PathBuf::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn overlay_dir_env_value_ignores_empty_and_maps_path() {
        assert_eq!(overlay_dir_from_value(None), None);
        assert_eq!(overlay_dir_from_value(Some(OsString::new())), None);
        assert_eq!(
            overlay_dir_from_value(Some(OsString::from("/tmp/icons"))),
            Some(PathBuf::from("/tmp/icons"))
        );
    }

    #[test]
    fn asset_source_reads_overlay_then_falls_back_to_bundled() {
        let dir = std::env::temp_dir().join(format!("cgc-icon-overlay-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("dir");
        const CUSTOM: &[u8] = br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M2 2h20v20H2z"/></svg>"#;
        std::fs::write(dir.join("check.svg"), CUSTOM).expect("write overlay");

        let assets = AppAssets::new(Some(dir.clone()));
        // 绘制阶段只读启动时的快照，覆盖目录移除后仍应使用已加载图标。
        std::fs::remove_dir_all(&dir).expect("remove overlay before drawing");
        let custom = assets
            .load("app-icons/icons/check.svg")
            .expect("load overlay")
            .expect("overlay bytes");
        assert_eq!(custom.as_ref(), CUSTOM);

        // 自定义目录没有的图标回退到内置资产。
        let builtin = assets.load("icons/bot.svg").expect("load bundled fallback");
        assert!(builtin.is_some());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn overlay_rejects_directories_and_oversized_files() {
        let dir = std::env::temp_dir().join(format!("cgc-icon-limits-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(dir.join("check.svg")).unwrap();
        std::fs::write(dir.join("bot.svg"), vec![b' '; MAX_ICON_BYTES + 1]).unwrap();
        let assets = AppAssets::new(Some(dir.clone()));
        std::fs::remove_dir_all(&dir).unwrap();
        assert!(assets.resolve_path("icons/check.svg").is_none());
        assert!(assets.resolve_path("icons/bot.svg").is_none());
        assert!(assets.load("app-icons/icons/bot.svg").unwrap().is_none());
        assert!(assets.load("icons/bot.svg").unwrap().is_some());
    }

    #[cfg(unix)]
    #[test]
    fn overlay_rejects_symbolic_links() {
        let dir = std::env::temp_dir().join(format!("cgc-icon-links-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        std::fs::write(dir.join("source.svg"), b"<svg/>").unwrap();
        std::fs::write(dir.join("bot.svg"), b"<svg/>").unwrap();
        std::os::unix::fs::symlink(dir.join("source.svg"), dir.join("check.svg")).unwrap();
        let assets = AppAssets::new(Some(dir.clone()));
        let root_link = dir.with_extension("link");
        std::os::unix::fs::symlink(&dir, &root_link).unwrap();
        let linked_assets = AppAssets::new(Some(root_link.clone()));
        std::fs::remove_file(&root_link).unwrap();
        std::fs::remove_dir_all(&dir).unwrap();
        assert!(assets.resolve_path("icons/check.svg").is_none());
        assert!(assets.load("app-icons/icons/check.svg").unwrap().is_none());
        assert!(assets.resolve_path("icons/bot.svg").is_some());
        assert!(linked_assets.resolve_path("icons/bot.svg").is_none());
    }

    #[test]
    fn asset_source_without_overlay_dir_uses_bundled_assets() {
        let assets = AppAssets::new(None);
        assert!(assets
            .load("icons/check.svg")
            .expect("bundled icon")
            .is_some());
    }
}
