//! native 面板的非 UI 纯逻辑（B4a：从 `native_agent_view.rs` 迁出，便于 B4b 删除视图）。
//!
//! 包含：工作区 system prompt、工作区文件扫描、离线回显提示、时间戳、
//! slash 菜单匹配、mention 匹配。只依赖 agent 领域 crate，不依赖 GPUI。

use cgc_agent_host::SLASH_COMMANDS;
use cgc_agent_tools::ToolRegistry;

use crate::mention::SkillEntry;

/// 工作区文件 mention 匹配（纯函数；native 面板与后续共享输入共用）。
pub(crate) fn mention_matches(files: &[String], query: &str) -> Vec<String> {
    let query = query.to_ascii_lowercase();
    files
        .iter()
        .filter(|path| query.is_empty() || path.to_ascii_lowercase().contains(&query))
        .take(8)
        .cloned()
        .collect()
}

pub(crate) fn collect_workspace_files(root: &std::path::Path) -> Vec<String> {
    fn walk(dir: &std::path::Path, root: &std::path::Path, out: &mut Vec<String>) {
        if out.len() >= 1000 {
            return;
        }
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with('.')
                || matches!(name.as_str(), "target" | "node_modules" | "dist" | "build")
            {
                continue;
            }
            if path.is_dir() {
                walk(&path, root, out);
            } else if path.is_file() {
                if let Ok(relative) = path.strip_prefix(root) {
                    out.push(relative.to_string_lossy().replace('\\', "/"));
                }
            }
        }
    }
    let mut files = Vec::new();
    walk(root, root, &mut files);
    files.sort();
    files
}

pub(crate) fn truncate_text(text: &str, max_chars: usize) -> String {
    let mut out = text.chars().take(max_chars).collect::<String>();
    if text.chars().count() > max_chars {
        out.push('…');
    }
    out
}

pub(crate) fn clean_thread_title(raw: &str) -> String {
    raw.trim()
        .trim_matches(|ch| {
            matches!(
                ch,
                '"' | '\'' | '「' | '」' | '《' | '》' | '。' | '.' | '\n'
            )
        })
        .chars()
        .filter(|ch| *ch != '\n' && *ch != '\r')
        .take(40)
        .collect::<String>()
        .trim()
        .to_string()
}

pub(crate) fn humanize_tokens(count: u64) -> String {
    if count >= 1_000_000 {
        format!("{:.1}M", count as f64 / 1_000_000.0).replace(".0M", "M")
    } else if count >= 1_000 {
        format!("{:.1}k", count as f64 / 1_000.0).replace(".0k", "k")
    } else {
        count.to_string()
    }
}

/// 仅在没有可用 Provider 凭据（Echo 回退）时提示离线回显。
/// 认证 / 凭据类错误的额外指引（对齐 Zed 的 credentials 提示）。
pub(crate) fn retry_hint_for_error(error: &str) -> Option<&'static str> {
    let lower = error.to_lowercase();
    let credentials_issue = [
        "401",
        "403",
        "api key",
        "apikey",
        "unauthorized",
        "credential",
    ]
    .iter()
    .any(|needle| lower.contains(needle));
    credentials_issue
        .then_some("去 Settings → AI → LLM Providers 检查 Provider Key，保存后点「重试」。")
}

pub(crate) fn trailing_mention(text: &str) -> Option<(usize, String)> {
    let position = text.rfind('@')?;
    if let Some(previous) = text[..position].chars().next_back() {
        if !previous.is_whitespace() {
            return None;
        }
    }
    let query = &text[position + 1..];
    if query.chars().any(char::is_whitespace) {
        return None;
    }
    Some((position, query.to_string()))
}

#[derive(Debug, Clone)]
pub(crate) struct SlashEntry {
    pub(crate) category: &'static str,
    pub(crate) label: String,
    pub(crate) description: String,
    pub(crate) tool: Option<String>,
    pub(crate) skill: Option<SkillEntry>,
    pub(crate) scope: Option<String>,
}

pub(crate) fn slash_match_rank(query: &str, name: &str, description: &str) -> Option<u8> {
    if query.is_empty() {
        return Some(0);
    }
    let name = name.to_ascii_lowercase();
    if name == query {
        Some(0)
    } else if name.starts_with(query) {
        Some(1)
    } else if name.contains(query) {
        Some(2)
    } else if description.to_ascii_lowercase().contains(query) {
        Some(3)
    } else {
        None
    }
}

/// slash 菜单的匹配打分：名字精确 > 名字前缀 > 名字包含 > 描述包含。
///
/// 技能名匹配必须排在「工具描述里恰好包含同一个词」之前：
/// 例如 `/answer` 想选 `answer-me-with-html`，而 `task` 工具的描述里也有
/// "answer"——按固定类别顺序会让回车选错工具。
pub(crate) fn offline_echo_notice(using_echo: bool) -> Option<&'static str> {
    using_echo.then_some(
        "未配置可用的 Provider API Key，当前离线回显模式。请在 Settings → AI → LLM Providers 保存 Key 后重新打开 Agent 面板。",
    )
}

/// 启动时注入的工作区上下文：工作区根 + 规则文件（AGENTS/CLAUDE）。
pub(crate) fn build_workspace_system_prompt(workspace: &std::path::Path) -> String {
    let mut prompt = format!(
        "你运行在用户的本地工作区：{}\n可以读写工作区文件、执行命令；修改前先读相关文件。\n",
        workspace.display()
    );
    for relative in ["AGENTS.md", "CLAUDE.md", "desktop/AGENTS.md"] {
        let path = workspace.join(relative);
        let Ok(content) = std::fs::read_to_string(&path) else {
            continue;
        };
        let content = truncate_text(&content, 20_000);
        prompt.push_str(&format!(
            "\n<workspace_rules source=\"{relative}\">\n{content}\n</workspace_rules>\n"
        ));
    }
    prompt.push_str("\n遵循上述工作区规则；规则与用户指令冲突时以用户当前指令为准。");
    prompt
}

pub(crate) fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or_default()
}

pub(crate) fn slash_entries_for(
    registry: &ToolRegistry,
    skills: &[SkillEntry],
    value: &str,
) -> Vec<SlashEntry> {
    let trimmed = value.trim_start();
    let Some(raw_query) = trimmed.strip_prefix('/') else {
        return Vec::new();
    };
    let query = raw_query.trim().to_ascii_lowercase();

    // 分组内按 (匹配质量, 原始顺序) 排序；分组之间按「该组最好匹配」再按类别优先级。
    let commands: Vec<(u8, usize, SlashEntry)> = SLASH_COMMANDS
        .iter()
        .enumerate()
        .filter_map(|(index, (command, description))| {
            slash_match_rank(&query, command.trim_start_matches('/'), description).map(|rank| {
                (
                    rank,
                    index,
                    SlashEntry {
                        category: "命令",
                        label: (*command).to_string(),
                        description: (*description).to_string(),
                        tool: None,
                        skill: None,
                        scope: None,
                    },
                )
            })
        })
        .collect();
    let tools: Vec<(u8, usize, SlashEntry)> = registry
        .list_descriptions()
        .into_iter()
        .enumerate()
        .filter_map(|(index, (name, description))| {
            slash_match_rank(&query, name, description).map(|rank| {
                (
                    rank,
                    index,
                    SlashEntry {
                        category: "工具",
                        label: name.to_string(),
                        description: description.to_string(),
                        tool: Some(name.to_string()),
                        skill: None,
                        scope: None,
                    },
                )
            })
        })
        .collect();
    let skills_group: Vec<(u8, usize, SlashEntry)> = skills
        .iter()
        .enumerate()
        .filter_map(|(index, skill)| {
            slash_match_rank(&query, &skill.name, &skill.description).map(|rank| {
                (
                    rank,
                    index,
                    SlashEntry {
                        category: "技能",
                        label: skill.name.clone(),
                        description: skill.description.clone(),
                        tool: None,
                        skill: Some(skill.clone()),
                        scope: Some(skill.scope.clone()),
                    },
                )
            })
        })
        .collect();

    let mut groups = [(0usize, commands), (1, tools), (2, skills_group)];
    for (_, group) in groups.iter_mut() {
        group.sort_by_key(|(rank, index, _)| (*rank, *index));
    }
    groups.sort_by_key(|(priority, group)| {
        (
            group.first().map(|(rank, _, _)| *rank).unwrap_or(u8::MAX),
            *priority,
        )
    });
    groups
        .into_iter()
        .flat_map(|(_, group)| group.into_iter().map(|(_, _, entry)| entry))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{
        build_workspace_system_prompt, collect_workspace_files, mention_matches, now_secs,
        offline_echo_notice, truncate_text,
    };

    fn temp_dir(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "cgc-native-context-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or_default()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn workspace_prompt_includes_rules_file() {
        let dir = temp_dir("prompt");
        std::fs::write(dir.join("AGENTS.md"), "规则：先读文件").unwrap();
        let prompt = build_workspace_system_prompt(&dir);
        assert!(prompt.contains("你运行在用户的本地工作区"));
        assert!(prompt.contains("<workspace_rules source=\"AGENTS.md\">"));
        assert!(prompt.contains("规则：先读文件"));
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn offline_echo_notice_only_when_echo() {
        assert!(offline_echo_notice(true).is_some());
        assert!(offline_echo_notice(false).is_none());
    }

    #[test]
    fn now_secs_is_positive() {
        assert!(now_secs() > 0);
    }

    #[test]
    fn workspace_files_skip_hidden_and_target_dirs() {
        let dir = temp_dir("files");
        std::fs::create_dir_all(dir.join("src")).unwrap();
        std::fs::create_dir_all(dir.join("target")).unwrap();
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        std::fs::write(dir.join("src/main.rs"), "fn main() {}").unwrap();
        std::fs::write(dir.join("target/out.bin"), "x").unwrap();
        std::fs::write(dir.join(".env"), "x").unwrap();
        let files = collect_workspace_files(&dir);
        assert_eq!(files, vec!["src/main.rs".to_string()]);
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn mention_matches_filter_and_limit() {
        let files: Vec<String> = (0..20).map(|i| format!("src/m{i}.rs")).collect();
        assert_eq!(mention_matches(&files, "M1").len(), 8, "匹配后最多 8 条");
        assert_eq!(mention_matches(&files, "m1").len(), 8, "最多 8 条");
        assert_eq!(mention_matches(&files, "nope"), Vec::<String>::new());
        assert_eq!(mention_matches(&files, "").len(), 8);
    }

    #[test]
    fn truncate_text_adds_ellipsis_only_when_over_limit() {
        assert_eq!(truncate_text("abc", 3), "abc");
        assert_eq!(truncate_text("abcd", 3), "abc…");
    }
}
