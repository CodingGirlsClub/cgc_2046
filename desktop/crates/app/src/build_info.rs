//! 构建可追溯信息（story 1.7）：版本号与 commit SHA 由 build.rs 注入。

pub const VERSION: &str = env!("CGC_BUILD_VERSION");
pub const COMMIT: &str = env!("CGC_BUILD_COMMIT");

/// 关于页/产物同名信息：`0.0.1 (abc1234)`。
pub fn about_line() -> String {
    format!("{VERSION} ({COMMIT})")
}

/// 安装包文件名片段：`cgc-desktop-0.0.1-abc1234`。
pub fn artifact_stem() -> String {
    format!("cgc2046-{VERSION}-{COMMIT}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_and_commit_are_injected_and_non_empty() {
        assert!(!VERSION.trim().is_empty());
        assert!(!COMMIT.trim().is_empty());
        assert_eq!(VERSION, env!("CGC_BUILD_VERSION"));
        assert_eq!(COMMIT, env!("CGC_BUILD_COMMIT"));
        assert_eq!(about_line(), format!("{VERSION} ({COMMIT})"));
        assert!(artifact_stem().starts_with("cgc2046-"));
        assert!(artifact_stem().contains(COMMIT));
    }
}
