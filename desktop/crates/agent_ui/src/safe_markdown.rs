//! 渲染安全边界（story 4.5）：课程正文与 agent 回复共用的 Markdown 预处理。
//!
//! 规则对齐 AD-23 / web `SafeMarkdown`：
//! - 原始 HTML 不执行：标签剥离，仅保留可读文本；
//! - 危险协议链接（javascript:/data:/vbscript:）降级为纯文本；
//! - 远程图片默认不加载：`![alt](url)` 降级为 alt 文本；
//! - 外链打开由 TextView `on_link_click` 收口（仅 http/https + 二次确认）。

/// 对 Markdown 做保守净化后再交给 TextView；纯函数，便于测试与 agent 回复复用。
pub fn sanitize_markdown(raw: &str) -> String {
    let without_scripts = strip_script_style(raw);
    remove_remote_images(&strip_html_tags(&without_scripts))
}

/// 移除 script/style 整段（含内容），避免脚本字面量进入正文。
fn strip_script_style(raw: &str) -> String {
    let lower = raw.to_ascii_lowercase();
    let mut ranges = Vec::new();
    for tag in ["script", "style"] {
        let open = format!("<{tag}");
        let close = format!("</{tag}");
        let mut search_from = 0;
        while let Some(start) = lower[search_from..].find(&open) {
            let start = search_from + start;
            let Some(close_at) = lower[start..].find(&close) else {
                break;
            };
            let close_at = start + close_at;
            // 找 </script> 的 '>'
            let Some(end_rel) = lower[close_at..].find('>') else {
                break;
            };
            let end = close_at + end_rel + 1;
            ranges.push((start, end));
            search_from = end;
        }
    }
    ranges.sort_by_key(|(start, _)| *start);
    let mut out = String::with_capacity(raw.len());
    let mut cursor = 0;
    for (start, end) in ranges {
        if start < cursor {
            continue;
        }
        out.push_str(&raw[cursor..start]);
        cursor = end;
    }
    out.push_str(&raw[cursor..]);
    out
}

fn strip_html_tags(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut chars = raw.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch != '<' {
            out.push(ch);
            continue;
        }
        // 找匹配的 '>'；找不到则按普通文本保留 '<'，避免吞掉后文。
        let mut tag = String::new();
        let mut closed = false;
        for next in chars.by_ref() {
            if next == '>' {
                closed = true;
                break;
            }
            tag.push(next);
        }
        if !closed {
            out.push('<');
            out.push_str(&tag);
        }
        // 标签内容（含 script/style 文本）不执行也不显示，避免脚本字面量混淆。
    }
    out
}

fn remove_remote_images(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let bytes: Vec<char> = raw.chars().collect();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == '!' && bytes.get(index + 1) == Some(&'[') {
            if let Some((alt, end)) = parse_link(&bytes, index + 1) {
                if let Some((_url, final_end)) = parse_url(&bytes, end) {
                    out.push_str(&alt);
                    index = final_end;
                    continue;
                }
            }
        }
        if bytes[index] == '[' {
            if let Some((text, end)) = parse_link(&bytes, index) {
                let url_start = end;
                // parse_link 已越过 `](url)`；从原文中取 url 判断协议。
                if let Some((url, final_end)) = parse_url(&bytes, url_start) {
                    if is_safe_link(&url) {
                        out.push('[');
                        out.push_str(&text);
                        out.push_str("](");
                        out.push_str(&url);
                        out.push(')');
                    } else {
                        out.push_str(&text);
                    }
                    index = final_end;
                    continue;
                }
            }
        }
        out.push(bytes[index]);
        index += 1;
    }
    out
}

/// 从 `[` 开始解析 `[text](`；返回 (text, 位置=url 起点)。
fn parse_link(chars: &[char], start: usize) -> Option<(String, usize)> {
    if chars.get(start) != Some(&'[') {
        return None;
    }
    let mut index = start + 1;
    let mut text = String::new();
    while index < chars.len() {
        if chars[index] == ']' {
            if chars.get(index + 1) == Some(&'(') {
                return Some((text, index + 2));
            }
            return None;
        }
        text.push(chars[index]);
        index += 1;
    }
    None
}

/// 从 url 起点解析到 `)`；返回 (url, 右括号后位置)。
fn parse_url(chars: &[char], start: usize) -> Option<(String, usize)> {
    let mut index = start;
    let mut url = String::new();
    let mut depth = 0usize;
    while index < chars.len() {
        match chars[index] {
            '(' => {
                depth += 1;
                url.push('(');
            }
            ')' => {
                if depth == 0 {
                    return Some((url, index + 1));
                }
                depth -= 1;
                url.push(')');
            }
            ch => url.push(ch),
        }
        index += 1;
    }
    None
}

pub fn is_safe_link(url: &str) -> bool {
    let lower = url.trim().to_ascii_lowercase();
    lower.starts_with("https://") || lower.starts_with("http://")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_raw_html_but_keeps_text() {
        assert_eq!(
            sanitize_markdown("hello <b onclick=alert(1)>world</b>"),
            "hello world"
        );
        assert_eq!(sanitize_markdown("<script>alert(1)</script>safe"), "safe");
    }

    #[test]
    fn keeps_safe_links_and_degrades_dangerous_ones() {
        let safe = sanitize_markdown("[Docs](https://example.com)");
        assert_eq!(safe, "[Docs](https://example.com)");

        let dangerous = sanitize_markdown("[click](javascript:alert(1))");
        assert_eq!(dangerous, "click");
        assert!(!dangerous.contains("javascript:"));
    }

    #[test]
    fn remote_images_are_reduced_to_alt_text() {
        let out = sanitize_markdown("before ![图表](https://cdn.example.com/a.png) after");
        assert_eq!(out, "before 图表 after");
        assert!(!out.contains("https://cdn.example.com"));
    }

    #[test]
    fn plain_markdown_passes_through() {
        assert_eq!(
            sanitize_markdown("# 标题\n\n**粗体** 与 `代码`"),
            "# 标题\n\n**粗体** 与 `代码`"
        );
    }

    #[test]
    fn safe_link_check_is_strict() {
        assert!(is_safe_link("https://a.b"));
        assert!(is_safe_link("http://a.b"));
        assert!(!is_safe_link("javascript:alert(1)"));
        assert!(!is_safe_link("file:///etc/passwd"));
        assert!(!is_safe_link("/relative"));
    }
}
