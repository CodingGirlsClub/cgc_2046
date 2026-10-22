#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum ToolError {
    #[error("invalid arguments: {0}")]
    InvalidArgs(String),
    #[error("path escapes the workspace: {0}")]
    PathEscape(String),
    #[error("file not found: {0}")]
    NotFound(String),
    #[error("file is too large: {0}")]
    TooLarge(String),
    #[error("io error: {0}")]
    Io(String),
}

impl From<std::io::Error> for ToolError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error.to_string())
    }
}
