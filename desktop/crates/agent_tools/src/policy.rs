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
}
