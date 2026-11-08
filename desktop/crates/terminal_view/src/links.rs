//! 终端输出里的 URL / 文件路径识别（Zed `terminal_path_like_target` 的精简版）。
//!
//! 只做「点击位置落在哪个链接上」的纯计算；打开动作在 view 里。
//! 不引入正则依赖：按字节扫描起点，再裁剪尾部标点。

use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum LinkKind {
    Url,
    Path,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Span {
    pub start: usize,
    pub end: usize,
    pub kind: LinkKind,
}

/// 找出与 `byte_index` 重叠的 URL 或路径。
pub(crate) fn link_in_line(text: &str, byte_index: usize) -> Option<Span> {
    scan(text)
        .into_iter()
        .find(|span| span.start <= byte_index && byte_index < span.end)
}

/// 去掉路径末尾的 `:line` / `:line:col`（只裁纯数字后缀）。
pub(crate) fn strip_line_col(target: &str) -> &str {
    let mut end = target.len();
    for _ in 0..2 {
        let Some(colon) = target[..end].rfind(':') else {
            break;
        };
        let suffix = &target[colon + 1..end];
        if suffix.is_empty() || !suffix.bytes().all(|b| b.is_ascii_digit()) {
            break;
        }
        end = colon;
    }
    &target[..end]
}

/// 把点中的路径变成可打开的文件路径。
///
/// `~/` 展开到 home；绝对路径直接用；相对路径需要终端的 cwd（OSC 7），
/// 否则无法定位，返回 `None`。
pub(crate) fn resolve_path(target: &str, cwd: Option<&str>) -> Option<PathBuf> {
    let path = strip_line_col(target);
    if let Some(rest) = path.strip_prefix("~/") {
        let home = std::env::var_os("HOME")?;
        return Some(PathBuf::from(home).join(rest));
    }
    if path.starts_with('/') {
        return Some(PathBuf::from(path));
    }
    let cwd = cwd?;
    Some(PathBuf::from(cwd).join(path))
}

/// 把本地路径编码成 `file://` URL：保留常见 ASCII，转义空格、分隔符与非 ASCII
/// 字节（`Path::display` 直接拼进 URL 会让含空格/中文的路径打不开）。
pub(crate) fn file_url(path: &Path) -> String {
    let mut out = String::from("file://");
    for byte in path.to_string_lossy().bytes() {
        match byte {
            b'%' => out.push_str("%25"),
            b' ' => out.push_str("%20"),
            b'#' => out.push_str("%23"),
            b'?' => out.push_str("%3F"),
            b'(' => out.push_str("%28"),
            b')' => out.push_str("%29"),
            b'[' => out.push_str("%5B"),
            b']' => out.push_str("%5D"),
            b'\n' => out.push_str("%0A"),
            b'\r' => out.push_str("%0D"),
            b'\t' => out.push_str("%09"),
            other if !(0x20..0x7F).contains(&other) => {
                out.push_str(&format!("%{other:02X}"));
            }
            other => out.push(other as char),
        }
    }
    out
}

fn scan(text: &str) -> Vec<Span> {
    let bytes = text.as_bytes();
    let mut spans = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if let Some(end) = url_at(bytes, i) {
            spans.push(Span {
                start: i,
                end,
                kind: LinkKind::Url,
            });
            i = end;
            continue;
        }
        if let Some(end) = path_at(bytes, i) {
            spans.push(Span {
                start: i,
                end,
                kind: LinkKind::Path,
            });
            i = end;
            continue;
        }
        i += 1;
    }
    spans
}

fn url_at(bytes: &[u8], start: usize) -> Option<usize> {
    let rest = &bytes[start..];
    let scheme = if rest.starts_with(b"https://") {
        8
    } else if rest.starts_with(b"http://") {
        7
    } else {
        return None;
    };
    let mut end = start + scheme;
    while end < bytes.len() && !is_terminator(bytes[end]) {
        end += 1;
    }
    let end = trim_trailing_punct(bytes, start, end);
    (end > start + scheme).then_some(end)
}

fn path_at(bytes: &[u8], start: usize) -> Option<usize> {
    if start > 0 && !is_boundary(bytes[start - 1]) {
        return None;
    }
    if !is_path_start_byte(bytes[start]) {
        return None;
    }
    let mut end = start;
    while end < bytes.len() && is_path_byte(bytes[end]) {
        end += 1;
    }
    let end = trim_trailing_punct(bytes, start, end);
    looks_like_path(&bytes[start..end]).then_some(end)
}

/// 起点字符：绝对/相对路径与「带目录的相对路径」（`src/main.rs`）。
fn is_path_start_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'/' | b'~' | b'_')
}

/// 判定候选串是否像路径，避免把 `and/or` 这类普通词当链接。
///
/// - 以 `/`、`./`、`../`、`~/` 开头：一定接受；
/// - 否则要求含 `/`，且带扩展名或 `:行号` 后缀。
fn looks_like_path(candidate: &[u8]) -> bool {
    let Ok(text) = std::str::from_utf8(candidate) else {
        return false;
    };
    let absolute = text.starts_with('/')
        || text.starts_with("./")
        || text.starts_with("../")
        || text.starts_with("~/");
    if absolute {
        return true;
    }
    let has_separator = text.contains('/');
    let has_extension = text.contains('.');
    let has_line_suffix = text.rsplit_once(':').is_some_and(|(_, suffix)| {
        !suffix.is_empty() && suffix.bytes().all(|b| b.is_ascii_digit())
    });
    has_separator && (has_extension || has_line_suffix)
}

fn is_boundary(byte: u8) -> bool {
    matches!(
        byte,
        b' ' | b'\t' | b'(' | b'[' | b'{' | b'"' | b'\'' | b'<' | b'='
    )
}

fn is_terminator(byte: u8) -> bool {
    byte.is_ascii_whitespace() || matches!(byte, b'"' | b'\'' | b'<' | b'>' | b'`')
}

/// 路径字符：字母数字、路径分隔符与 `:line:col` 的冒号；非 ASCII 字节也算
/// （中文文件名）。
fn is_path_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric()
        || matches!(byte, b'/' | b'.' | b'_' | b'-' | b'~' | b':' | b'+' | b'@')
        || byte >= 0x80
}

fn trim_trailing_punct(bytes: &[u8], start: usize, mut end: usize) -> usize {
    while end > start
        && matches!(
            bytes[end - 1],
            b'.' | b',' | b';' | b':' | b'!' | b'?' | b')' | b']' | b'}'
        )
    {
        end -= 1;
    }
    end
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 取 `needle` 中间位置作为点击点，返回命中的文本与类型。
    fn hit<'a>(text: &'a str, needle: &str) -> Option<(&'a str, LinkKind)> {
        let index = text.find(needle).expect("needle") + needle.len() / 2;
        link_in_line(text, index).map(|span| (&text[span.start..span.end], span.kind))
    }

    #[test]
    fn finds_urls_and_paths_under_the_cursor() {
        let line = "error at src/main.rs:42:5 — see https://example.com/a?b=1";
        assert_eq!(
            hit(line, "main"),
            Some(("src/main.rs:42:5", LinkKind::Path))
        );
        assert_eq!(
            hit(line, "example"),
            Some(("https://example.com/a?b=1", LinkKind::Url))
        );
        assert_eq!(hit(line, "error"), None, "普通单词不是链接");
        assert_eq!(hit(line, "see"), None);
    }

    #[test]
    fn trims_trailing_punctuation() {
        let line = "open /tmp/log.txt, then done";
        assert_eq!(hit(line, "log"), Some(("/tmp/log.txt", LinkKind::Path)));
    }

    #[test]
    fn needs_a_path_boundary() {
        // 单词中间的斜杠不是路径起点。
        assert_eq!(hit("and/or", "or"), None);
        // 括号后的路径可以识别。
        assert_eq!(
            hit("(see /tmp/x.log)", "x.log"),
            Some(("/tmp/x.log", LinkKind::Path))
        );
    }

    #[test]
    fn strips_line_and_column_suffix() {
        assert_eq!(strip_line_col("src/main.rs:42:5"), "src/main.rs");
        assert_eq!(strip_line_col("src/main.rs:42"), "src/main.rs");
        assert_eq!(strip_line_col("src/main.rs"), "src/main.rs");
        assert_eq!(strip_line_col("a:b"), "a:b", "非数字后缀保留");
        assert_eq!(strip_line_col("/tmp/dir:1/file"), "/tmp/dir:1/file");
    }

    #[test]
    fn file_urls_escape_spaces_and_non_ascii() {
        assert_eq!(file_url(Path::new("/tmp/a b.txt")), "file:///tmp/a%20b.txt");
        assert_eq!(
            file_url(Path::new("/tmp/中文.md")),
            "file:///tmp/%E4%B8%AD%E6%96%87.md"
        );
        assert_eq!(
            file_url(Path::new("/tmp/100%.txt")),
            "file:///tmp/100%25.txt"
        );
    }

    #[test]
    fn resolves_absolute_and_relative_paths() {
        assert_eq!(
            resolve_path("/tmp/x.log:3", None),
            Some(PathBuf::from("/tmp/x.log"))
        );
        assert_eq!(
            resolve_path("src/main.rs:1", Some("/repo")),
            Some(PathBuf::from("/repo/src/main.rs"))
        );
        assert_eq!(
            resolve_path("src/main.rs", None),
            None,
            "相对路径没有 cwd 就不解析"
        );
    }
}
