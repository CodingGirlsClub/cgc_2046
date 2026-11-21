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
                // Windows 破坏性系统/整盘命令（classify 统一转小写；保留工作区内正常 rd/del）
                "rd /s /q c:\\",
                "rd /q /s c:\\",
                "rd /s c:\\",
                "rd /s /q \\",
                "rd /q /s \\",
                "rd /s /q %userprofile%",
                "rd /q /s %userprofile%",
                "rd /s %userprofile%",
                "rmdir /s /q c:\\",
                "rmdir /q /s c:\\",
                "rmdir /s c:\\",
                "rmdir /s /q \\",
                "rmdir /q /s \\",
                "rmdir /s /q %userprofile%",
                "rmdir /q /s %userprofile%",
                "rmdir /s %userprofile%",
                "del /f /s /q c:\\",
                "del /s /f /q c:\\",
                "del /s /q c:\\",
                "del /f /s c:\\",
                "del /f /s /q \\",
                "del /s /f /q \\",
                "del /f /s /q %userprofile%",
                "del /s /q %userprofile%",
                "remove-item -recurse -force c:\\",
                "remove-item -force -recurse c:\\",
                "remove-item -recurse -force ~",
                "remove-item -recurse -force $env:userprofile",
                "format c:",
                "format d:",
                "diskpart",
                "bcdedit",
                "reg delete hklm",
                "reg delete hkcu",
                "cipher /w",
                "takeown /f c:\\",
                "icacls c:\\",
            ]
            .into_iter()
            .map(str::to_string)
            .collect(),
        }
    }
}

impl CommandPolicy {
    pub fn with_deny_patterns(patterns: Vec<String>) -> Self {
        Self {
            deny_patterns: patterns,
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
        CommandDecision::Ask
    }
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
    fn default_policy_denies_windows_destructive_commands() {
        let policy = CommandPolicy::default();
        for dangerous in [
            r"rd /s /q C:\",
            r"rmdir /s /q %USERPROFILE%\Documents",
            r"del /f /s /q C:\Windows",
            r"Remove-Item -Recurse -Force C:\Users",
            "diskpart",
            "format C: /fs:ntfs",
            r"reg delete HKLM\Software\Test",
            "bcdedit /delete {current}",
        ] {
            assert!(
                matches!(policy.classify(dangerous), CommandDecision::Deny(_)),
                "expected Deny for Windows destructive command: {dangerous}"
            );
        }
    }

    #[test]
    fn normal_commands_still_ask() {
        let policy = CommandPolicy::default();
        assert_eq!(policy.classify("cargo test"), CommandDecision::Ask);
        assert_eq!(policy.classify("echo hello"), CommandDecision::Ask);
        assert_eq!(
            policy.classify(r#"git log --format "%H""#),
            CommandDecision::Ask
        );
        assert_eq!(policy.classify("rd /s /q dist"), CommandDecision::Ask);
        assert_eq!(policy.classify("del temp.txt"), CommandDecision::Ask);
        assert_eq!(policy.classify("dir"), CommandDecision::Ask);
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
}
