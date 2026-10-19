//! workspace 上下文与课程上下文端口（story 4.1）。
//!
//! `CourseContextPort` 是 courses 实现、companion 消费的跨 feature 端口（脊柱 AD-1）：
//! 上下文缺失/过期必须 fail-closed，调用方不得用空 workspace 或空 revision 启动
//! 学习会话/agent。真正的 account/workspace epoch 由 story 2.4/2.5 提供，本 story
//! 先固定端口形状与 fail-closed 语义（缺失即错误）。

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CourseContext {
    pub user_id: String,
    pub workspace_id: String,
    pub course_id: String,
    pub course_revision_id: String,
    pub account_epoch: u64,
    pub workspace_epoch: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ContextError {
    MissingUser,
    MissingWorkspace,
    MissingCourse,
    MissingRevision,
}

/// 课程上下文端口：由 courses 域实现，learning/companion 侧只依赖此 trait。
pub trait CourseContextPort {
    fn current(&self) -> Result<CourseContext, ContextError>;
}

/// 课程上下文提供者：拿到什么就放什么，`current` 逐项 fail-closed。
#[derive(Clone, Debug, Default)]
pub struct CourseContextProvider {
    pub user_id: Option<String>,
    pub workspace_id: Option<String>,
    pub course_id: Option<String>,
    pub course_revision_id: Option<String>,
    pub account_epoch: Option<u64>,
    pub workspace_epoch: Option<u64>,
}

impl CourseContextProvider {
    pub fn from_parts(
        user_id: impl Into<Option<String>>,
        workspace_id: impl Into<Option<String>>,
        course_id: impl Into<Option<String>>,
        course_revision_id: impl Into<Option<String>>,
    ) -> Self {
        Self {
            user_id: user_id.into(),
            workspace_id: workspace_id.into(),
            course_id: course_id.into(),
            course_revision_id: course_revision_id.into(),
            account_epoch: Some(1),
            workspace_epoch: Some(1),
        }
    }

    fn non_empty(value: &Option<String>) -> Option<String> {
        value
            .as_ref()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
    }
}

impl CourseContextPort for CourseContextProvider {
    fn current(&self) -> Result<CourseContext, ContextError> {
        let user_id = Self::non_empty(&self.user_id).ok_or(ContextError::MissingUser)?;
        let workspace_id =
            Self::non_empty(&self.workspace_id).ok_or(ContextError::MissingWorkspace)?;
        let course_id = Self::non_empty(&self.course_id).ok_or(ContextError::MissingCourse)?;
        let course_revision_id =
            Self::non_empty(&self.course_revision_id).ok_or(ContextError::MissingRevision)?;

        Ok(CourseContext {
            user_id,
            workspace_id,
            course_id,
            course_revision_id,
            account_epoch: self.account_epoch.unwrap_or(0),
            workspace_epoch: self.workspace_epoch.unwrap_or(0),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn complete() -> CourseContextProvider {
        CourseContextProvider::from_parts(
            Some("u-1".to_string()),
            Some("ws-1".to_string()),
            Some("course-1".to_string()),
            Some("rev-3".to_string()),
        )
    }

    #[test]
    fn complete_parts_produce_context() {
        let context = complete().current().expect("context");
        assert_eq!(context.workspace_id, "ws-1");
        assert_eq!(context.course_revision_id, "rev-3");
        assert_eq!(context.account_epoch, 1);
    }

    #[test]
    fn missing_workspace_fails_closed() {
        let mut provider = complete();
        provider.workspace_id = None;
        assert_eq!(provider.current(), Err(ContextError::MissingWorkspace));
    }

    #[test]
    fn missing_revision_fails_closed() {
        let mut provider = complete();
        provider.course_revision_id = None;
        assert_eq!(provider.current(), Err(ContextError::MissingRevision));
    }

    #[test]
    fn blank_values_treated_as_missing() {
        let mut provider = complete();
        provider.course_id = Some("   ".to_string());
        assert_eq!(provider.current(), Err(ContextError::MissingCourse));
    }
}
