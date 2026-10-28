//! Story 4.3 的公式渲染 spike：5 个真实样式的 LaTeX 用 ratex-gpui 渲染为 PNG。
//! 用法：`cargo run -p cgc-desktop-app --example formula_render`

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let samples = [
        ("quadratic", r"\frac{-b \pm \sqrt{b^2 - 4ac}}{2a}"),
        ("euler", r"e^{i\pi} + 1 = 0"),
        ("matrix", r"\begin{pmatrix} a & b \\ c & d \end{pmatrix}"),
        (
            "calculus",
            r"\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}",
        ),
        ("sum", r"\sum_{k=1}^{n} k = \frac{n(n+1)}{2}"),
        ("invalid", r"\frac{"),
    ];
    let dir = std::env::temp_dir().join("cgc-formula-samples");
    std::fs::create_dir_all(&dir)?;
    for (name, latex) in samples {
        match ratex_gpui::render::render_latex_to_png(latex, 32.0, 2.0) {
            Some(bytes) => {
                let path = dir.join(format!("{name}.png"));
                std::fs::write(&path, &bytes)?;
                println!("{name}: OK {} bytes → {:?}", bytes.len(), path);
            }
            None => println!("{name}: fallback (parse/render failed)"),
        }
    }
    // SVG 备选路径：同一 LaTeX 导出为自包含 SVG（不经网络字体/浏览器）。
    for (name, latex) in samples {
        if let Some(svg) = ratex_gpui::render::render_latex_to_svg(latex, 32.0) {
            let path = dir.join(format!("{name}.svg"));
            std::fs::write(&path, &svg)?;
            println!("{name}: SVG {} bytes → {:?}", svg.len(), path);
        }
    }
    Ok(())
}
