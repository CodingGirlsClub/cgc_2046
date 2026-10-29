//! `cgc://` 深链的语法解析与路由白名单。
//!
//! 只把深链归一成应用内 path；不把原始 URL 传给业务层，也不把 ID 当作路径拼接材料。
//! 第一版白名单覆盖首页、工作台、活动、课程、学习、设置、Agent 注册与学习搭子。

use url::Url;
use uuid::Uuid;

pub const SCHEME: &str = "cgc";
const MAX_URL_LEN: usize = 2048;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeepLink {
    pub path: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeepLinkError {
    TooLong,
    InvalidUrl,
    WrongScheme,
    BadHost,
    BadPath,
}

pub fn parse(raw: &str) -> Result<DeepLink, DeepLinkError> {
    if raw.len() > MAX_URL_LEN {
        return Err(DeepLinkError::TooLong);
    }
    let url = Url::parse(raw).map_err(|_| DeepLinkError::InvalidUrl)?;
    if url.scheme() != SCHEME {
        return Err(DeepLinkError::WrongScheme);
    }
    if url.username() != ""
        || url.password().is_some()
        || url.port().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(DeepLinkError::BadPath);
    }
    let host = url.host_str().ok_or(DeepLinkError::BadHost)?;
    let segments = url
        .path_segments()
        .map(|segments| {
            segments
                .filter(|segment| !segment.is_empty())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    let path = match (host, segments.as_slice()) {
        ("home", []) => "/".to_string(),
        ("workspace", []) => "/workspace".to_string(),
        ("settings", []) => "/settings".to_string(),
        ("agents", []) => "/agents".to_string(),
        ("companion", []) => "/companion".to_string(),
        ("events", []) => "/events".to_string(),
        ("events", ["mine"]) => "/events/mine".to_string(),
        ("events", [id]) => format!("/events/{}", uuid(id)?),
        ("courses", []) => "/courses".to_string(),
        ("courses", [id]) => format!("/courses/{}", uuid(id)?),
        ("courses", [id, "learn"]) => format!("/courses/{}/learn", uuid(id)?),
        _ => return Err(DeepLinkError::BadPath),
    };
    Ok(DeepLink { path })
}

fn uuid(value: &str) -> Result<String, DeepLinkError> {
    Uuid::parse_str(value)
        .map(|uuid| uuid.to_string())
        .map_err(|_| DeepLinkError::BadPath)
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "3f2b0f9e-0c1d-4c7a-9b0e-8f6d5a4c3b2a";

    #[test]
    fn parses_supported_routes() {
        assert_eq!(parse("cgc://home").unwrap().path, "/");
        assert_eq!(parse("cgc://workspace").unwrap().path, "/workspace");
        assert_eq!(parse("cgc://settings").unwrap().path, "/settings");
        assert_eq!(parse("cgc://agents").unwrap().path, "/agents");
        assert_eq!(parse("cgc://companion").unwrap().path, "/companion");
        assert_eq!(parse("cgc://events").unwrap().path, "/events");
        assert_eq!(parse("cgc://events/mine").unwrap().path, "/events/mine");
        assert_eq!(parse("cgc://courses").unwrap().path, "/courses");
        assert_eq!(
            parse(&format!("cgc://events/{ID}")).unwrap().path,
            format!("/events/{ID}")
        );
        assert_eq!(
            parse(&format!("cgc://courses/{ID}")).unwrap().path,
            format!("/courses/{ID}")
        );
        assert_eq!(
            parse(&format!("cgc://courses/{ID}/learn")).unwrap().path,
            format!("/courses/{ID}/learn")
        );
    }

    #[test]
    fn rejects_unsafe_or_unknown_links() {
        assert_eq!(parse("https://events/x"), Err(DeepLinkError::WrongScheme));
        assert_eq!(
            parse("cgc://events"),
            Ok(DeepLink {
                path: "/events".into()
            })
        );
        assert_eq!(
            parse("cgc://events/not-a-uuid"),
            Err(DeepLinkError::BadPath)
        );
        assert_eq!(
            parse("cgc://events/../settings"),
            Err(DeepLinkError::BadPath)
        );
        assert_eq!(parse("cgc://events/x?token=1"), Err(DeepLinkError::BadPath));
        assert_eq!(parse("cgc://events/x#frag"), Err(DeepLinkError::BadPath));
        assert_eq!(parse("cgc://user@events/x"), Err(DeepLinkError::BadPath));
        assert_eq!(parse("cgc://unknown"), Err(DeepLinkError::BadPath));
        assert_eq!(
            parse("cgc://courses/x/learn/extra"),
            Err(DeepLinkError::BadPath)
        );
        assert_eq!(parse(""), Err(DeepLinkError::InvalidUrl));
    }
}
