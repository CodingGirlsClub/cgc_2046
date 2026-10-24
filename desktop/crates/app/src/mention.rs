//! Composer 内联 mention 的协议层：技能 / 文件引用统一成「链接文本 + inline token」。
//!
//! 参照 Zed 的 mention 模型：编辑框里存可读的 markdown 链接文本
//! （`[@name](skill://scope/name)`、`[@path](file://path)`），由 inline token 在
//! UI 上渲染成 chip；发送时按 token 解析出技能 / 文件内容注入 prompt 上下文。
//! 这里只放纯逻辑（无 GPUI 视图），视图接线在 `native_agent_view`。

use gpui_kit::assets::IconName;
use gpui_kit::component::input::{InlineToken, InputContent};
use gpui_kit::SharedString;
use std::path::{Path, PathBuf};

/// 单个可引用的技能（slash 菜单展示 + chip / 发送注入都用它）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SkillEntry {
    pub name: String,
    pub description: String,
    pub scope: String,
    pub file_path: PathBuf,
}

/// 一次 mention 引用：技能或工作区文件。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Mention {
    Skill {
        name: String,
        scope: String,
        file_path: PathBuf,
    },
    File {
        /// 工作区相对路径。
        path: String,
    },
}

const SKILL_ID_PREFIX: &str = "skill:";
const FILE_ID_PREFIX: &str = "file:";

impl Mention {
    pub(crate) fn skill(entry: &SkillEntry) -> Self {
        Self::Skill {
            name: entry.name.clone(),
            scope: entry.scope.clone(),
            file_path: entry.file_path.clone(),
        }
    }

    /// token id：持久化在输入框内容里，发送时据此定位技能文件 / 工作区文件。
    pub(crate) fn token_id(&self) -> String {
        match self {
            Self::Skill {
                name,
                scope,
                file_path,
            } => format!(
                "{SKILL_ID_PREFIX}{}:{}:{}",
                encode_component(scope),
                encode_component(name),
                encode_component(&file_path.display().to_string())
            ),
            Self::File { path } => format!("{FILE_ID_PREFIX}{}", encode_component(path)),
        }
    }

    pub(crate) fn parse_token_id(id: &str) -> Option<Self> {
        if let Some(rest) = id.strip_prefix(SKILL_ID_PREFIX) {
            // 三段都用 encode_component 转义过，因此 ':' 不是内容分隔符。
            let mut parts = rest.splitn(3, ':');
            let scope = decode_component(parts.next()?);
            let name = decode_component(parts.next()?);
            let file_path = PathBuf::from(decode_component(parts.next()?));
            if scope.is_empty() || name.is_empty() || file_path.as_os_str().is_empty() {
                return None;
            }
            return Some(Self::Skill {
                name,
                scope,
                file_path,
            });
        }
        let path = id.strip_prefix(FILE_ID_PREFIX)?;
        let path = decode_component(path);
        if path.is_empty() {
            return None;
        }
        Some(Self::File { path })
    }

    /// 编辑框里出现的链接文本（Zed 风格）。
    pub(crate) fn link_text(&self) -> String {
        match self {
            Self::Skill { name, scope, .. } => format!(
                "[@{}](skill://{}/{})",
                encode_component(name),
                encode_component(scope),
                encode_component(name)
            ),
            Self::File { path } => {
                format!(
                    "[@{}](file://{})",
                    encode_component(path),
                    encode_component(path)
                )
            }
        }
    }

    /// chip 上显示的短标签。
    pub(crate) fn chip_label(&self) -> String {
        match self {
            Self::Skill { name, .. } => name.clone(),
            Self::File { path } => path.clone(),
        }
    }

    pub(crate) fn chip_icon(&self) -> IconName {
        match self {
            Self::Skill { .. } => IconName::Sparkle,
            Self::File { .. } => IconName::FileText,
        }
    }

    pub(crate) fn chip_icon_path(&self) -> SharedString {
        self.chip_icon().path()
    }

    /// hover chip 时展示的路径（技能是 SKILL.md 绝对路径，文件是工作区绝对路径）。
    pub(crate) fn tooltip(&self, workspace: &Path) -> String {
        match self {
            Self::Skill { file_path, .. } => file_path.display().to_string(),
            Self::File { path } => workspace.join(path).display().to_string(),
        }
    }

    /// 把 mention 放进编辑框内容：prefix + 链接文本 + suffix，链接整体为一个原子 token。
    pub(crate) fn content_at(&self, prefix: &str, suffix: &str) -> InputContent {
        let link = self.link_text();
        let text = format!("{prefix}{link}{suffix}");
        let range = prefix.len()..prefix.len() + link.len();
        let token = InlineToken::new(self.token_id(), link).with_label(self.chip_label());
        InputContent::new(text)
            .with_token(range, token)
            .expect("mention token range must match its link text")
    }

    /// 发送时注入 prompt 的上下文块；读不到内容时静默跳过。
    pub(crate) fn prompt_context(&self, workspace: &Path) -> Option<String> {
        match self {
            Self::Skill {
                name, file_path, ..
            } => {
                let content = std::fs::read_to_string(file_path).ok()?;
                Some(format!(
                    "[技能: {name}]\n{}\n\n",
                    truncate_text(&content, 64 * 1024)
                ))
            }
            Self::File { path } => file_context(workspace, path),
        }
    }
}

/// 发送文本：token 里的技能 / 文件内容作为上下文前置，其余文本原样保留。
pub(crate) fn resolve_prompt(content: &InputContent, workspace: &Path) -> String {
    let text = content.text().as_ref();
    let mut context = String::new();
    for span in content.tokens() {
        if let Some(mention) = Mention::parse_token_id(span.token().id()) {
            if let Some(block) = mention.prompt_context(workspace) {
                context.push_str(&block);
            }
        }
    }
    // 兼容手输的 `@path`（没有经过 mention 菜单，没有 token）。
    context.push_str(&legacy_at_context(text, workspace));
    if context.is_empty() {
        text.to_string()
    } else {
        format!("{context}{text}")
    }
}

/// 展示用文本：把 mention 链接还原成 `/技能名`、`@文件路径`，普通 markdown 链接不动。
pub(crate) fn display_text(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut cursor = 0usize;
    while let Some(relative) = text[cursor..].find("[@") {
        let start = cursor + relative;
        out.push_str(&text[cursor..start]);
        let Some((replacement, next_cursor)) = parse_mention_link(text, start) else {
            out.push_str(&text[start..start + 2]);
            cursor = start + 2;
            continue;
        };
        out.push_str(&replacement);
        cursor = next_cursor;
    }
    out.push_str(&text[cursor..]);
    out
}

/// 技能 / 文件内容读取与展示，统一走工作区扫描后的结果。
pub(crate) fn load_skills(workspace: &Path) -> Vec<SkillEntry> {
    let mut roots: Vec<(PathBuf, &'static str)> = Vec::new();
    if let Some(home) = std::env::var_os("HOME") {
        roots.push((PathBuf::from(home).join(".agents").join("skills"), "global"));
    }
    roots.push((workspace.join(".agents").join("skills"), "project"));
    roots.push((workspace.join("skills"), "project"));
    load_skills_from(roots)
}

fn load_skills_from(roots: Vec<(PathBuf, &'static str)>) -> Vec<SkillEntry> {
    let mut skills: std::collections::BTreeMap<String, SkillEntry> =
        std::collections::BTreeMap::new();
    for (root, scope) in roots {
        let Ok(entries) = std::fs::read_dir(&root) else {
            continue;
        };
        for entry in entries.flatten() {
            let file_path = entry.path().join("SKILL.md");
            let Ok(content) = std::fs::read_to_string(&file_path) else {
                continue;
            };
            let mut name = entry.file_name().to_string_lossy().to_string();
            let mut description = String::new();
            let mut in_frontmatter = false;
            for line in content.lines() {
                if line.trim() == "---" {
                    in_frontmatter = !in_frontmatter;
                    continue;
                }
                if !in_frontmatter {
                    continue;
                }
                if let Some(value) = line.strip_prefix("name:") {
                    name = value.trim().trim_matches('"').to_string();
                } else if let Some(value) = line.strip_prefix("description:") {
                    description = value.trim().trim_matches('"').to_string();
                }
            }
            if description.is_empty() {
                description = format!("技能：{name}");
            }
            // 同名时 project 覆盖 global。
            let should_insert = match skills.get(&name) {
                Some(existing) => scope == "project" && existing.scope != "project",
                None => true,
            };
            if should_insert {
                skills.insert(
                    name.clone(),
                    SkillEntry {
                        name,
                        description,
                        scope: scope.to_string(),
                        file_path,
                    },
                );
            }
        }
    }
    let mut result: Vec<SkillEntry> = skills.into_values().collect();
    result.truncate(50);
    result
}

fn legacy_at_context(text: &str, workspace: &Path) -> String {
    let mut context = String::new();
    for token in text.split_whitespace() {
        let Some(path) = token.strip_prefix('@') else {
            continue;
        };
        if path.is_empty() || path.starts_with('/') {
            continue;
        }
        if let Some(block) = file_context(workspace, path) {
            context.push_str(&block);
        }
    }
    context
}

fn file_context(workspace: &Path, path: &str) -> Option<String> {
    let full = workspace.join(path);
    let metadata = std::fs::metadata(&full).ok()?;
    if !metadata.is_file() || metadata.len() > 256 * 1024 {
        return None;
    }
    let content = std::fs::read_to_string(full).ok()?;
    Some(format!("[文件: {path}]\n{content}\n\n"))
}

fn truncate_text(text: &str, limit: usize) -> String {
    if text.len() <= limit {
        return text.to_string();
    }
    let mut end = limit;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}\n…(已截断)", &text[..end])
}

/// 解析 `[@label](skill://…)` / `[@label](file://…)`。
/// 返回：(替换文本、下一个扫描位置)。
fn parse_mention_link(text: &str, start: usize) -> Option<(String, usize)> {
    let after = &text[start + 2..];
    let label_end = after.find("](")?;
    let label = &after[..label_end];
    let target_start = label_end + 2;
    let target_rest = after.get(target_start..)?;
    let target_end = target_rest.find(')')?;
    let target = &target_rest[..target_end];
    let next = start + 2 + target_start + target_end + 1;
    if target.starts_with("skill://") {
        return Some((format!("/{}", decode_component(label)), next));
    }
    if target.starts_with("file://") {
        return Some((format!("@{}", decode_component(label)), next));
    }
    // 普通 markdown 链接原样保留。
    Some((text[start..next].to_string(), next))
}

/// markdown 链接里不安全字符的百分号转义（label 与 target 共用）。
fn encode_component(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for ch in input.chars() {
        match ch {
            '%' => out.push_str("%25"),
            ':' => out.push_str("%3A"),
            '(' => out.push_str("%28"),
            ')' => out.push_str("%29"),
            '[' => out.push_str("%5B"),
            ']' => out.push_str("%5D"),
            ' ' => out.push_str("%20"),
            '\n' => out.push_str("%0A"),
            '\r' => out.push_str("%0D"),
            '\t' => out.push_str("%09"),
            other => out.push(other),
        }
    }
    out
}

fn decode_component(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut index = 0usize;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            if let (Some(high), Some(low)) =
                (hex_value(bytes[index + 1]), hex_value(bytes[index + 2]))
            {
                out.push(high * 16 + low);
                index += 3;
                continue;
            }
        }
        out.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui_kit::component::input::InlineTokenSpan;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("cgc-mention-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("mkdir temp");
        dir
    }

    fn demo_skill(file_path: PathBuf) -> Mention {
        Mention::Skill {
            name: "answer-me-with-html".to_string(),
            scope: "global".to_string(),
            file_path,
        }
    }

    #[test]
    fn skill_mention_builds_zed_style_link_token() {
        let file_path = PathBuf::from("/tmp/skills/answer-me-with-html/SKILL.md");
        let mention = demo_skill(file_path);
        let content = mention.content_at("前文 ", " ");
        assert_eq!(
            content.text().as_ref(),
            "前文 [@answer-me-with-html](skill://global/answer-me-with-html) "
        );
        assert_eq!(content.tokens().len(), 1);
        let span: &InlineTokenSpan = &content.tokens()[0];
        assert_eq!(span.token().label().as_ref(), "answer-me-with-html");
        assert_eq!(&content.text()[span.range()], mention.link_text());
        assert_eq!(
            Mention::parse_token_id(span.token().id()),
            Some(demo_skill(PathBuf::from(
                "/tmp/skills/answer-me-with-html/SKILL.md"
            )))
        );
    }

    #[test]
    fn skill_mention_tooltip_is_skill_file_path() {
        let mention = demo_skill(PathBuf::from(
            "/Users/x/.agents/skills/answer-me-with-html/SKILL.md",
        ));
        assert_eq!(
            mention.tooltip(Path::new("/workspace")),
            "/Users/x/.agents/skills/answer-me-with-html/SKILL.md"
        );
    }

    #[test]
    fn file_mention_encodes_link_target_and_round_trips() {
        let mention = Mention::File {
            path: "docs/a b(1).md".to_string(),
        };
        let content = mention.content_at("", " ");
        assert!(content.text().contains("file://docs/a%20b%281%29.md"));
        assert_eq!(content.tokens().len(), 1);
        assert_eq!(
            Mention::parse_token_id(content.tokens()[0].token().id()),
            Some(mention)
        );
    }

    #[test]
    fn resolve_prompt_injects_skill_content() {
        let dir = temp_dir("skillresolve");
        let skill_file = dir.join("SKILL.md");
        std::fs::write(&skill_file, "# Skill Body\n步骤一").expect("write skill");
        let mention = demo_skill(skill_file);
        let content = mention.content_at("", " 请执行");
        let prompt = resolve_prompt(&content, Path::new("/workspace"));
        assert!(prompt.contains("[技能: answer-me-with-html]"), "{prompt}");
        assert!(prompt.contains("# Skill Body"), "{prompt}");
        assert!(prompt.contains("请执行"), "{prompt}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn resolve_prompt_injects_workspace_file_content() {
        let dir = temp_dir("fileresolve");
        std::fs::create_dir_all(dir.join("src")).expect("mkdir src");
        std::fs::write(dir.join("src/main.rs"), "fn main() {}").expect("write file");
        let mention = Mention::File {
            path: "src/main.rs".to_string(),
        };
        let content = mention.content_at("看这个 ", "");
        let prompt = resolve_prompt(&content, &dir);
        assert!(prompt.contains("[文件: src/main.rs]"), "{prompt}");
        assert!(prompt.contains("fn main() {}"), "{prompt}");
        assert!(prompt.contains("看这个"), "{prompt}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn resolve_prompt_keeps_legacy_at_path_expansion() {
        let dir = temp_dir("legacy");
        std::fs::write(dir.join("notes.md"), "legacy body").expect("write notes");
        let content = InputContent::new("读 @notes.md 然后总结");
        let prompt = resolve_prompt(&content, &dir);
        assert!(prompt.contains("[文件: notes.md]"), "{prompt}");
        assert!(prompt.contains("legacy body"), "{prompt}");
        assert!(prompt.contains("读 @notes.md 然后总结"), "{prompt}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn resolve_prompt_tolerates_missing_skill_file() {
        let mention = demo_skill(PathBuf::from("/nonexistent/cgc-skill/SKILL.md"));
        let content = mention.content_at("hi ", "");
        let prompt = resolve_prompt(&content, Path::new("/workspace"));
        assert_eq!(
            prompt,
            "hi [@answer-me-with-html](skill://global/answer-me-with-html)"
        );
    }

    #[test]
    fn display_text_humanizes_mention_links_only() {
        let text = "[@answer-me-with-html](skill://global/answer-me-with-html) 做一下 [@docs/a b.md](file://docs/a%20b.md)";
        assert_eq!(
            display_text(text),
            "/answer-me-with-html 做一下 @docs/a b.md"
        );
        assert_eq!(display_text("纯文本"), "纯文本");
        assert_eq!(
            display_text("[普通链接](https://example.com)"),
            "[普通链接](https://example.com)"
        );
        assert_eq!(display_text("[@没有闭合"), "[@没有闭合");
    }

    #[test]
    fn load_skills_from_captures_file_path_and_prefers_project() {
        let dir = temp_dir("loadskills");
        let global = dir.join("global");
        let project = dir.join("project");
        std::fs::create_dir_all(global.join("deploy")).expect("mkdir global skill");
        std::fs::create_dir_all(project.join("deploy")).expect("mkdir project skill");
        std::fs::write(
            global.join("deploy/SKILL.md"),
            "---\nname: deploy\ndescription: 全局部署\n---\n",
        )
        .expect("write global");
        std::fs::write(
            project.join("deploy/SKILL.md"),
            "---\nname: deploy\ndescription: 项目部署\n---\n",
        )
        .expect("write project");
        let skills = load_skills_from(vec![
            (global.clone(), "global"),
            (project.clone(), "project"),
        ]);
        assert_eq!(skills.len(), 1, "{skills:?}");
        assert_eq!(skills[0].name, "deploy");
        assert_eq!(skills[0].scope, "project");
        assert_eq!(skills[0].description, "项目部署");
        assert_eq!(skills[0].file_path, project.join("deploy/SKILL.md"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
