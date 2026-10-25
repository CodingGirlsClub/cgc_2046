//! 纯文本 / Markdown 工具（双栈共用）。
//!
//! Stage 0 从 `native_agent_view` 抽出：ACP 面板此前反向 import
//! `crate::native_agent_view::markdown_to_plain`，等于让 ACP 依赖 native 视图。
//! 复制纯文本、`Copy`/`Copy as Markdown` 载荷都走这里，两栈不再各带一份。

/// 把 Markdown 粗转成可读纯文本（复制用，不追求完整渲染语义）。
pub(crate) fn markdown_to_plain(markdown: &str) -> String {
    let mut out = String::with_capacity(markdown.len());
    let mut in_fence = false;
    let mut blank_pending = false;
    for raw_line in markdown.lines() {
        let trimmed = raw_line.trim();
        if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            in_fence = !in_fence;
            continue;
        }
        if in_fence {
            out.push_str(raw_line);
            out.push('\n');
            blank_pending = false;
            continue;
        }
        if trimmed.is_empty() {
            blank_pending = true;
            continue;
        }
        // 分隔线（--- / *** / ___）
        if trimmed.len() >= 3
            && trimmed
                .chars()
                .all(|ch| matches!(ch, '-' | '*' | '_' | ' '))
        {
            continue;
        }
        let mut line = trimmed;
        while let Some(rest) = line.strip_prefix('>') {
            line = rest.trim_start();
        }
        let heading = line.trim_start_matches('#');
        if heading.len() != line.len() {
            line = heading.trim_start();
        }
        line = strip_list_prefix(line);
        if blank_pending && !out.is_empty() {
            out.push('\n');
        }
        blank_pending = false;
        out.push_str(&strip_inline_markdown(line));
        out.push('\n');
    }
    out.trim_end().to_string()
}

fn strip_list_prefix(line: &str) -> &str {
    for marker in ["- ", "* ", "+ "] {
        if let Some(rest) = line.strip_prefix(marker) {
            return rest;
        }
    }
    let digits = line.chars().take_while(|ch| ch.is_ascii_digit()).count();
    if digits > 0 {
        let rest = &line[digits..];
        if rest.starts_with(". ") || rest.starts_with(") ") {
            return &rest[2..];
        }
    }
    line
}

fn strip_inline_markdown(line: &str) -> String {
    let chars: Vec<char> = line.chars().collect();
    let mut out = String::with_capacity(line.len());
    let mut index = 0;
    while index < chars.len() {
        match chars[index] {
            '\\' => {
                if let Some(next) = chars.get(index + 1) {
                    out.push(*next);
                }
                index += 2;
            }
            '!' if chars.get(index + 1) == Some(&'[') => {
                if let Some((label, next)) = parse_link_like(&chars, index + 1) {
                    out.push_str(&label);
                    index = next;
                } else {
                    index += 1;
                }
            }
            '[' => {
                if let Some((label, next)) = parse_link_like(&chars, index) {
                    out.push_str(&label);
                    index = next;
                } else {
                    out.push('[');
                    index += 1;
                }
            }
            '`' | '*' | '_' | '~' => index += 1,
            other => {
                out.push(other);
                index += 1;
            }
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// 解析 `[label](url)`（从 bracket 位置的 '[' 开始），返回 label 与结束位置。
fn parse_link_like(chars: &[char], bracket: usize) -> Option<(String, usize)> {
    if chars.get(bracket) != Some(&'[') {
        return None;
    }
    let close = chars.iter().skip(bracket + 1).position(|ch| *ch == ']')? + bracket + 1;
    if chars.get(close + 1) != Some(&'(') {
        return None;
    }
    let paren_close = chars.iter().skip(close + 2).position(|ch| *ch == ')')? + close + 2;
    let label: String = chars[bracket + 1..close].iter().collect();
    Some((label, paren_close + 1))
}

#[cfg(test)]
mod tests {
    #[test]
    fn markdown_to_plain_strips_common_syntax() {
        let markdown = "# H1\n- a\n- **b**\n> quote\n`inline` **bold** [link](https://x.y)\n```rust\nfn main() {}\n```\n![图](https://i)";
        assert_eq!(
            super::markdown_to_plain(markdown),
            "H1\na\nb\nquote\ninline bold link\nfn main() {}\n图"
        );
        assert_eq!(super::markdown_to_plain("plain text"), "plain text");
    }
}
