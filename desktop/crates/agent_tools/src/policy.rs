/// 危险命令策略（在审批之前先做硬拦截）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CommandDecision {
    /// 需要用户审批。
    Ask,
    /// 直接拒绝（返回给模型的原因）。
    Deny(String),
}

/// 命令策略：默认拦截不可逆的破坏性命令，其余走审批。
#[derive(Clone, Debug)]
pub struct CommandPolicy {
    deny_patterns: Vec<String>,
    deny_windows_commands: bool,
}

impl Default for CommandPolicy {
    fn default() -> Self {
        Self {
            deny_patterns: [
                "rm -rf /",
                "rm -fr /",
                "rm -rf ~",
                "rm -rf $home",
                "mkfs",
                "dd if=",
                "dd of=/dev/",
                "shutdown",
                "reboot",
                ":(){",
                ":(){ :|:& };:",
                "chmod -r 777 /",
                "chown -r /",
                "> /dev/sda",
                "mv /* /dev/null",
                // Windows 破坏性命令（统一小写匹配；`rd /s`、`rmdir /s`、`format` 走 token 判定防误杀）。
                "del /f /s",
                "del /s /f",
                "del /s /q",
                "del /q /s",
                "diskpart",
                "reg delete",
                "remove-item -recurse -force",
                "remove-item -force -recurse",
                "cipher /w",
            ]
            .into_iter()
            .map(str::to_string)
            .collect(),
            deny_windows_commands: true,
        }
    }
}

impl CommandPolicy {
    pub fn with_deny_patterns(patterns: Vec<String>) -> Self {
        Self {
            deny_patterns: patterns,
            deny_windows_commands: false,
        }
    }

    pub fn deny_patterns(&self) -> &[String] {
        &self.deny_patterns
    }

    pub fn classify(&self, command: &str) -> CommandDecision {
        let normalized = command.to_ascii_lowercase();
        for pattern in &self.deny_patterns {
            if normalized.contains(pattern) {
                return CommandDecision::Deny(format!("blocked destructive command: {pattern}"));
            }
        }
        if self.deny_windows_commands {
            if let Some(reason) = detect_windows_destructive_command(&normalized) {
                return CommandDecision::Deny(format!("blocked destructive command: {reason}"));
            }
        }
        CommandDecision::Ask
    }
}

/// 按命令片段与词边界识别 Windows `rd /s` / `rmdir /s` 与 `format <drive>:`，
/// 避免裸子串误杀 `rg card /src/ui`、`grep password /srv/config`、`mix format C:\repo\...` 等常规命令。
fn detect_windows_destructive_command(normalized: &str) -> Option<&'static str> {
    for segment in normalized.split(['&', '|', ';', '\n', '\r']) {
        let tokens: Vec<&str> = segment
            .split_whitespace()
            .map(|token| token.trim_matches(|ch| ch == '"' || ch == '\''))
            .filter(|token| !token.is_empty())
            .collect();
        let tokens = unwrap_shell_prefix(&tokens);
        let Some(&cmd) = tokens.first() else {
            continue;
        };
        let rest = &tokens[1..];
        match command_basename(cmd) {
            "rd" | "rmdir"
                if rest
                    .iter()
                    .any(|&arg| arg == "/s" || arg.starts_with("/s/")) =>
            {
                return Some("rd /s");
            }
            "format" if rest.iter().copied().any(is_windows_drive_arg) => {
                return Some("format");
            }
            _ => {}
        }
    }
    None
}

fn unwrap_shell_prefix<'a>(mut tokens: &'a [&'a str]) -> &'a [&'a str] {
    loop {
        let Some(&first) = tokens.first() else {
            return tokens;
        };
        match command_basename(first) {
            "call" => tokens = &tokens[1..],
            "start" => {
                let mut idx = 1;
                while idx < tokens.len() && tokens[idx].starts_with('/') {
                    idx += 1;
                }
                tokens = &tokens[idx..];
            }
            "cmd" => {
                if let Some(pos) = tokens[1..].iter().position(|&t| matches!(t, "/c" | "/k")) {
                    tokens = &tokens[pos + 2..];
                } else {
                    return tokens;
                }
            }
            "powershell" | "pwsh" => {
                if let Some(pos) = tokens[1..]
                    .iter()
                    .position(|&t| matches!(t, "-c" | "-command"))
                {
                    tokens = &tokens[pos + 2..];
                } else {
                    return tokens;
                }
            }
            _ => return tokens,
        }
    }
}

fn command_basename(token: &str) -> &str {
    let name = token.rsplit(['/', '\\']).next().unwrap_or(token);
    name.strip_suffix(".exe")
        .or_else(|| name.strip_suffix(".com"))
        .unwrap_or(name)
}

fn is_windows_drive_arg(arg: &str) -> bool {
    let bytes = arg.as_bytes();
    bytes.len() >= 2
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && (bytes.len() == 2 || (bytes.len() == 3 && matches!(bytes[2], b'\\' | b'/')))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_policy_denies_destructive_commands() {
        let policy = CommandPolicy::default();
        assert!(matches!(
            policy.classify("rm -rf / --no-preserve-root"),
            CommandDecision::Deny(_)
        ));
        assert!(matches!(
            policy.classify("DD IF=/dev/zero OF=/dev/sda"),
            CommandDecision::Deny(_)
        ));
        assert!(matches!(
            policy.classify("mkfs.ext4 /dev/sdb"),
            CommandDecision::Deny(_)
        ));
    }

    #[test]
    fn normal_commands_still_ask() {
        let policy = CommandPolicy::default();
        assert_eq!(policy.classify("cargo test"), CommandDecision::Ask);
        assert_eq!(policy.classify("echo hello"), CommandDecision::Ask);
    }

    #[test]
    fn custom_patterns_replace_defaults() {
        let policy = CommandPolicy::with_deny_patterns(vec!["npm publish".to_string()]);
        assert!(matches!(
            policy.classify("npm publish"),
            CommandDecision::Deny(_)
        ));
        assert_eq!(policy.classify("rm -rf /"), CommandDecision::Ask);
    }

    #[test]
    fn default_policy_denies_windows_destructive_commands_without_false_positives() {
        let policy = CommandPolicy::default();
        for dangerous in [
            r"rd /s /q C:\Users\alice",
            r"rd /q /s C:\temp",
            r"RMDIR /S C:\temp",
            r"cmd /c rd /s /q C:\temp",
            r"del /f /s /q C:\temp\*",
            r"del /s /q C:\temp\*",
            r"del /q /s C:\temp\*",
            "format c:",
            "format D: /fs:ntfs /q",
            "format C:\\",
            "cmd /c format E:",
            "powershell -NoProfile -Command format F:",
            "diskpart",
            r"reg delete HKCU\Software\App /f",
            r"Remove-Item -Recurse -Force C:\temp",
            r"Remove-Item -Force -Recurse C:\temp",
            r"cipher /w:C:\",
        ] {
            assert!(
                matches!(policy.classify(dangerous), CommandDecision::Deny(_)),
                "危险命令应被硬拦截: {dangerous}"
            );
        }

        for benign in [
            "del foo.txt",
            "dir",
            "cargo test",
            "cargo fmt --check",
            "git format-patch -1 HEAD",
            "git log --format=%H -n 5",
            "prettier --write src/main.ts --format",
            "cargo test -- --format terse",
            "rg card /src/ui",
            "grep keyword /src/main.rs",
            "grep password /srv/config",
            r"mix format C:\repo\lib\app.ex",
            r"ruff format C:\repo\main.py",
            r"biome format C:\repo\src",
            r"dotnet format C:\repo\App.sln",
            "rmdir /tmp/empty",
        ] {
            assert_eq!(
                policy.classify(benign),
                CommandDecision::Ask,
                "常规命令不应被误杀: {benign}"
            );
        }
    }
}
