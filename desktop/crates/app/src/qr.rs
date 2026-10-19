//! 二维码矩阵生成与 GPUI 渲染（story 3.13）。
//!
//! 依赖 `qrcode` **0.14.1**（license = **MIT OR Apache-2.0**，与项目的 AGPL-3.0 兼容），
//! 只取矩阵：`QrCode::new` 用默认纠错级别 M 并自动选最小版本，`into_colors()` 按行
//! 展开模块。Cargo.toml 已关闭该 crate 的默认 features（image/svg/pic），渲染不复用
//! 它的图片输出，而是用 gpui 的 div 逐格绘制，因此二维码是普通元素：可随主题换色、
//! 可被布局缩放，也不额外引入 image 依赖。
//!
//! 静默区（quiet zone）按规范固定 4 个模块，并计入 `side` 的总边长：
//! 每格边长 = `side / (size + 8)`，调用方只给最终显示边长即可。黑白之间没有 gap，
//! 外层 `overflow_hidden` 吸收子像素取整，避免行/列之间出现缝。
//!
//! 错误面：空内容（含纯空白）→ [`QrError::Empty`]；超长 → [`QrError::TooLong`]；
//! 其余编码错误保留 crate 文案 → [`QrError::Encode`]。渲染侧不 panic：
//! [`QrMatrix`] 字段是 `pub` 的，越界/不完整矩阵一律按浅色模块处理。

use std::fmt;

use gpui_kit::{div, px, AnyElement, Hsla, IntoElement, ParentElement, Pixels, Styled};

/// 二维码规范要求的静默区宽度（模块数），四边各 4 个模块。
const QUIET_ZONE: usize = 4;

/// 编码后的二维码模块矩阵。
///
/// `size` 是每边模块数（21、25、…、177），`modules` 按行优先展开，长度应为
/// `size * size`；`true` 表示深色模块。字段公开是为了让调用方能在测试里构造
/// 固定矩阵，渲染时对不完整矩阵做了防御。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QrMatrix {
    pub size: usize,
    pub modules: Vec<bool>,
}

/// [`encode`] 的错误面。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum QrError {
    /// 内容为空（`""` 或纯空白）。
    Empty,
    /// 内容超出二维码最大容量（版本 40-M，字节模式约 2331 字节）。
    TooLong,
    /// 其他编码错误，附带 `qrcode` crate 的原始文案。
    Encode(String),
}

impl fmt::Display for QrError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            QrError::Empty => write!(f, "二维码内容为空"),
            QrError::TooLong => write!(f, "二维码内容过长"),
            QrError::Encode(message) => write!(f, "二维码编码失败：{message}"),
        }
    }
}

impl std::error::Error for QrError {}

/// 把文本编码成二维码矩阵（纠错级别 M，自动选最小版本）。
pub fn encode(text: &str) -> Result<QrMatrix, QrError> {
    if text.trim().is_empty() {
        return Err(QrError::Empty);
    }

    let code = qrcode::QrCode::new(text.as_bytes()).map_err(|error| match error {
        qrcode::types::QrError::DataTooLong => QrError::TooLong,
        other => QrError::Encode(other.to_string()),
    })?;

    let size = code.width();
    let modules = code
        .into_colors()
        .into_iter()
        .map(|color| color == qrcode::Color::Dark)
        .collect();
    Ok(QrMatrix { size, modules })
}

/// 含静默区的每边格子数。
fn grid_side(matrix: &QrMatrix) -> usize {
    matrix.size + QUIET_ZONE * 2
}

/// 每格边长；`cells` 恒 ≥ 8，不会除零。
fn cell_size(side: Pixels, cells: usize) -> Pixels {
    px(side.as_f32() / cells as f32)
}

/// 第 `(x, y)` 格（坐标系含静默区）是否为深色。
///
/// 越界或 `modules` 长度不足时返回 `false`，让渲染在非法矩阵上也不会 panic。
fn module_is_dark(matrix: &QrMatrix, x: usize, y: usize) -> bool {
    if x < QUIET_ZONE || y < QUIET_ZONE {
        return false;
    }
    let module_x = x - QUIET_ZONE;
    let module_y = y - QUIET_ZONE;
    if module_x >= matrix.size || module_y >= matrix.size {
        return false;
    }
    matrix
        .modules
        .get(module_y * matrix.size + module_x)
        .copied()
        .unwrap_or(false)
}

/// 把矩阵渲染成 `side × side` 的正方形 GPUI 元素（含 4 模块静默区）。
///
/// 实现是「flex 列 × 若干 flex 行 × 每行 `size + 8` 个等宽 div」，格间无 gap；
/// 深/浅色模块都显式填充，背景色不会从格缝透出来。返回 `AnyElement`，可直接
/// 作为 payment 视图的 `child(...)` 使用。
///
/// 扫描可靠性建议传纯黑/纯白（`gpui_kit::component::{black, white}`）：半透明色
/// 会随背景变化，反色（浅字深底）并非所有扫码器都支持。
pub fn render_qr(matrix: &QrMatrix, dark: Hsla, light: Hsla, side: Pixels) -> AnyElement {
    let cells = grid_side(matrix);
    let cell = cell_size(side, cells);

    let rows = (0..cells).map(|y| {
        let row = (0..cells).map(|x| {
            div()
                .w(cell)
                .h(cell)
                .flex_shrink_0()
                .bg(if module_is_dark(matrix, x, y) {
                    dark
                } else {
                    light
                })
                .into_any_element()
        });
        div()
            .flex()
            .flex_row()
            .flex_shrink_0()
            .w(side)
            .h(cell)
            .children(row)
            .into_any_element()
    });

    div()
        .flex()
        .flex_col()
        .flex_shrink_0()
        .w(side)
        .h(side)
        .overflow_hidden()
        .children(rows)
        .into_any_element()
}

#[cfg(test)]
mod tests {
    // 显式导入，避免父模块的 gpui 类型与 std 的 `#[test]` 宏混在一起。
    use super::{cell_size, encode, grid_side, module_is_dark, QrError, QrMatrix, QUIET_ZONE};
    use gpui_kit::px;

    #[test]
    fn encode_empty_text_is_rejected() {
        assert_eq!(encode("").unwrap_err(), QrError::Empty);
        assert_eq!(encode("   ").unwrap_err(), QrError::Empty);
    }

    #[test]
    fn encode_overlong_text_is_rejected_without_panic() {
        let text = "x".repeat(5_000);
        assert_eq!(encode(&text).unwrap_err(), QrError::TooLong);
    }

    #[test]
    fn encode_is_deterministic() {
        let first = encode("https://example.com/pay/order/42").expect("encode");
        let second = encode("https://example.com/pay/order/42").expect("encode");
        assert_eq!(first, second);
    }

    #[test]
    fn known_vector_hello_world_matches_crate_reference_matrix() {
        // 参考矩阵由 qrcode 0.14.1 生成（纠错级别 M、版本 1），此处硬编码为回归基线：
        // 若升级 crate 或改编码参数导致矩阵变化，本测试必须跟着重新取证。
        let matrix = encode("HELLO WORLD").expect("encode");
        assert_eq!(matrix.size, 21);
        assert_eq!(matrix.modules.len(), 21 * 21);
        assert_eq!(matrix.modules.iter().filter(|dark| **dark).count(), 222);
        assert_eq!(row_string(&matrix, 0), "111111100010101111111");
        assert_eq!(row_string(&matrix, 10), "000111111101001011000");
        assert_eq!(row_string(&matrix, 20), "111111101101011100001");
        assert_eq!(matrix_hash(&matrix), 0x1c37_6158_ce5b_2c55);
    }

    #[test]
    fn quiet_zone_is_four_light_modules_on_every_side() {
        // 2×2 手写矩阵：深 浅 / 浅 深，用来验证静默区的坐标换算。
        let matrix = QrMatrix {
            size: 2,
            modules: vec![true, false, false, true],
        };
        assert_eq!(grid_side(&matrix), 2 + QUIET_ZONE * 2);

        let side = grid_side(&matrix);
        for y in 0..side {
            for x in 0..side {
                let in_matrix = (QUIET_ZONE..QUIET_ZONE + matrix.size).contains(&x)
                    && (QUIET_ZONE..QUIET_ZONE + matrix.size).contains(&y);
                if !in_matrix {
                    assert!(
                        !module_is_dark(&matrix, x, y),
                        "静默区 ({x}, {y}) 必须是浅色"
                    );
                }
            }
        }

        assert!(module_is_dark(&matrix, QUIET_ZONE, QUIET_ZONE));
        assert!(!module_is_dark(&matrix, QUIET_ZONE + 1, QUIET_ZONE));
        assert!(!module_is_dark(&matrix, QUIET_ZONE, QUIET_ZONE + 1));
        assert!(module_is_dark(&matrix, QUIET_ZONE + 1, QUIET_ZONE + 1));
    }

    #[test]
    fn cell_size_fills_side_without_gaps() {
        assert_eq!(cell_size(px(110.0), 11), px(10.0));
        assert_eq!(cell_size(px(100.0), 10) * 10, px(100.0));
    }

    #[test]
    fn incomplete_matrix_is_treated_as_light_without_panic() {
        let matrix = QrMatrix {
            size: 3,
            modules: Vec::new(),
        };
        assert_eq!(grid_side(&matrix), 11);
        assert!(!module_is_dark(&matrix, QUIET_ZONE, QUIET_ZONE));
        assert!(!module_is_dark(&matrix, 999, 999));
    }

    /// 一行模块的 `1`/`0` 字符串，只用于参考矩阵断言。
    fn row_string(matrix: &QrMatrix, y: usize) -> String {
        matrix.modules[y * matrix.size..(y + 1) * matrix.size]
            .iter()
            .map(|dark| if *dark { '1' } else { '0' })
            .collect()
    }

    /// FNV-1a（64 位）覆盖整个矩阵，用来钉住每一位而非只钉深色数量。
    fn matrix_hash(matrix: &QrMatrix) -> u64 {
        let mut hash = 0xcbf2_9ce4_8422_2325_u64;
        for module in &matrix.modules {
            hash ^= u64::from(*module);
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
        hash
    }
}
