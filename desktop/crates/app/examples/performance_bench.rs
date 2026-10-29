//! Story 4.7 的 headless 基准：长文切分/安全清洗 + 公式光栅化。
//! GUI 帧时间/内存/CJK 截图需真机，本工具只给出可重跑的解析/渲染基线。

use std::time::Instant;

fn main() {
    let paragraph = "这是一段用于长文性能测试的中文正文，包含 **粗体**、`inline code`、链接 [docs](https://example.com) 与行内公式 $E=mc^2$。\n\n";
    let mut markdown = String::new();
    while markdown.len() < 10_000 {
        markdown.push_str(paragraph);
    }
    let started = Instant::now();
    let iterations = 100;
    let mut segments = 0;
    for _ in 0..iterations {
        segments = cgc_desktop_app::formula::split_math(&markdown).len();
    }
    let split_elapsed = started.elapsed();
    println!(
        "markdown: {} chars, {} iterations, last segments={} , total={:?}, per-iter={:?}",
        markdown.len(),
        iterations,
        segments,
        split_elapsed,
        split_elapsed / iterations
    );

    let started = Instant::now();
    let mut sanitized_bytes = 0;
    for _ in 0..iterations {
        sanitized_bytes = cgc_agent_ui::safe_markdown::sanitize_markdown(&markdown).len();
    }
    let sanitize_elapsed = started.elapsed();
    println!(
        "sanitize: {} bytes, total={:?}, per-iter={:?}",
        sanitized_bytes,
        sanitize_elapsed,
        sanitize_elapsed / iterations
    );

    let formulas = [
        r"\frac{-b \pm \sqrt{b^2 - 4ac}}{2a}",
        r"\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}",
        r"\sum_{k=1}^{n} k = \frac{n(n+1)}{2}",
        r"\begin{pmatrix} a & b \\ c & d \end{pmatrix}",
        r"e^{i\pi} + 1 = 0",
    ];
    let started = Instant::now();
    let mut rendered = 0;
    for _ in 0..20 {
        for latex in formulas {
            if ratex_gpui::render::render_latex_to_png(latex, 32.0, 2.0).is_some() {
                rendered += 1;
            }
        }
    }
    let render_elapsed = started.elapsed();
    println!(
        "formula raster: {} renders, total={:?}, per-render={:?}",
        rendered,
        render_elapsed,
        render_elapsed / rendered.max(1)
    );
    println!("note: GUI frame time / RSS / CJK screenshots require real devices (epic-7).");
}
