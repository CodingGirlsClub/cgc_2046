/// Provider 错误分类，UI 与重试策略都只依赖这个枚举。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProviderErrorCategory {
    Authentication,
    PaymentRequired,
    Permission,
    RateLimit,
    Overloaded,
    ContextTooLong,
    InvalidRequest,
    Transport,
    Cancelled,
    Other,
}

impl ProviderErrorCategory {
    pub fn from_status(status: u16) -> Self {
        match status {
            401 => Self::Authentication,
            402 => Self::PaymentRequired,
            403 => Self::Permission,
            408 | 504 => Self::Transport,
            413 => Self::ContextTooLong,
            429 => Self::RateLimit,
            500..=599 => Self::Overloaded,
            400..=499 => Self::InvalidRequest,
            _ => Self::Other,
        }
    }

    pub fn is_retryable(self) -> bool {
        matches!(self, Self::RateLimit | Self::Overloaded | Self::Transport)
    }
}

/// Provider 返回的错误。
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ProviderError {
    #[error("{category:?}: {message}")]
    Api {
        category: ProviderErrorCategory,
        status: Option<u16>,
        message: String,
        retry_after: Option<u64>,
    },
    #[error("transport: {0}")]
    Transport(String),
    #[error("invalid response: {0}")]
    InvalidResponse(String),
}

impl ProviderError {
    pub fn api(status: u16, message: impl Into<String>) -> Self {
        Self::Api {
            category: ProviderErrorCategory::from_status(status),
            status: Some(status),
            message: message.into(),
            retry_after: None,
        }
    }

    pub fn api_with_category(
        category: ProviderErrorCategory,
        status: Option<u16>,
        message: impl Into<String>,
    ) -> Self {
        Self::Api {
            category,
            status,
            message: message.into(),
            retry_after: None,
        }
    }

    pub fn transport(message: impl Into<String>) -> Self {
        Self::Transport(message.into())
    }

    pub fn invalid_response(message: impl Into<String>) -> Self {
        Self::InvalidResponse(message.into())
    }

    pub fn category(&self) -> ProviderErrorCategory {
        match self {
            Self::Api { category, .. } => *category,
            Self::Transport(_) => ProviderErrorCategory::Transport,
            Self::InvalidResponse(_) => ProviderErrorCategory::InvalidRequest,
        }
    }

    pub fn is_retryable(&self) -> bool {
        self.category().is_retryable()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_maps_to_category() {
        assert_eq!(
            ProviderErrorCategory::from_status(401),
            ProviderErrorCategory::Authentication
        );
        assert_eq!(
            ProviderErrorCategory::from_status(402),
            ProviderErrorCategory::PaymentRequired
        );
        assert_eq!(
            ProviderErrorCategory::from_status(429),
            ProviderErrorCategory::RateLimit
        );
        assert_eq!(
            ProviderErrorCategory::from_status(503),
            ProviderErrorCategory::Overloaded
        );
        assert_eq!(
            ProviderErrorCategory::from_status(400),
            ProviderErrorCategory::InvalidRequest
        );
    }

    #[test]
    fn retryable_categories() {
        assert!(ProviderError::api(429, "busy").is_retryable());
        assert!(!ProviderError::api(401, "bad key").is_retryable());
    }
}
