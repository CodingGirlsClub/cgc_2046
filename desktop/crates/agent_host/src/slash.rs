/// 客户端侧 slash 命令（不发给模型）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SlashCommand {
    Help,
    Clear,
    Stop,
    Tools,
    Checkpoint,
    Settings,
    Unknown(String),
}

/// 解析以 `/` 开头的输入；非 slash 输入返回 `None`。
pub fn parse(input: &str) -> Option<SlashCommand> {
    let trimmed = input.trim();
    let command = trimmed.strip_prefix('/')?;
    let name = command
        .split_whitespace()
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase();
    Some(match name.as_str() {
        "help" => SlashCommand::Help,
        "clear" => SlashCommand::Clear,
        "stop" => SlashCommand::Stop,
        "tools" => SlashCommand::Tools,
        "checkpoint" => SlashCommand::Checkpoint,
        "settings" => SlashCommand::Settings,
        other => SlashCommand::Unknown(other.to_string()),
    })
}

/// 供 UI 展示的命令列表。
pub const COMMANDS: &[(&str, &str)] = &[
    ("/help", "查看命令"),
    ("/clear", "清空对话显示"),
    ("/stop", "停止当前生成"),
    ("/tools", "列出可用工具"),
    ("/checkpoint", "查看 checkpoint 变更"),
    ("/settings", "打开 Provider 设置"),
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_known_commands() {
        assert_eq!(parse("/help"), Some(SlashCommand::Help));
        assert_eq!(parse("/Clear "), Some(SlashCommand::Clear));
        assert_eq!(parse("/stop"), Some(SlashCommand::Stop));
        assert_eq!(parse("/tools"), Some(SlashCommand::Tools));
        assert_eq!(parse("/checkpoint"), Some(SlashCommand::Checkpoint));
        assert_eq!(parse("/settings"), Some(SlashCommand::Settings));
    }

    #[test]
    fn non_slash_returns_none() {
        assert_eq!(parse("hello"), None);
        assert_eq!(parse(" /help"), Some(SlashCommand::Help));
        assert_eq!(parse(""), None);
    }

    #[test]
    fn unknown_command_is_preserved() {
        assert_eq!(
            parse("/nope extra"),
            Some(SlashCommand::Unknown("nope".to_string()))
        );
    }

    #[test]
    fn commands_list_covers_known_commands() {
        for (command, _) in COMMANDS {
            assert!(parse(command).is_some());
        }
    }
}
