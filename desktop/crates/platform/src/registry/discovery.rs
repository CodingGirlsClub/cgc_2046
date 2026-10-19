//! 官方 ACP Registry 发现层（ADR-0026 决策 3）。
//!
//! 只做发现：列出官方 registry 中的 agent 元数据（名称/版本/发行形态），
//! **不安装**第三方条目；安装仍只来自内置签名清单。MCP 官方 registry 元数据
//! 不含 checksum/签名，v1 不据此做安装决策。

use std::time::Duration;

use serde_json::Value;

use super::manifest::RegistryError;

pub const ACP_REGISTRY_URL: &str =
    "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json";

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DiscoveryDistribution {
    Npx { package: String },
    Binary { platforms: Vec<String> },
    Unknown,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DiscoveredAgent {
    pub id: String,
    pub name: String,
    pub version: String,
    pub description: Option<String>,
    pub distribution: DiscoveryDistribution,
}

/// 解析官方 ACP registry JSON（schema `version=1.0.0`，`agents[]`）。
pub fn parse_acp_registry(raw: &str) -> Result<Vec<DiscoveredAgent>, RegistryError> {
    let value: Value =
        serde_json::from_str(raw).map_err(|error| RegistryError::InvalidJson(error.to_string()))?;
    let agents = value
        .get("agents")
        .and_then(Value::as_array)
        .ok_or_else(|| RegistryError::InvalidEntry("missing agents[]".to_string()))?;

    let mut discovered = Vec::new();
    for agent in agents {
        let Some(id) = agent.get("id").and_then(Value::as_str) else {
            continue;
        };
        let Some(name) = agent.get("name").and_then(Value::as_str) else {
            continue;
        };
        if id.trim().is_empty() || name.trim().is_empty() {
            continue;
        }
        discovered.push(DiscoveredAgent {
            id: id.to_string(),
            name: name.to_string(),
            version: agent
                .get("version")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
                .to_string(),
            description: agent
                .get("description")
                .and_then(Value::as_str)
                .map(str::to_string),
            distribution: parse_distribution(agent.get("distribution")),
        });
    }
    if discovered.is_empty() {
        return Err(RegistryError::InvalidEntry(
            "official registry has no valid agents".to_string(),
        ));
    }
    Ok(discovered)
}

fn parse_distribution(value: Option<&Value>) -> DiscoveryDistribution {
    let Some(value) = value else {
        return DiscoveryDistribution::Unknown;
    };
    if let Some(package) = value
        .get("npx")
        .and_then(|npx| npx.get("package"))
        .and_then(Value::as_str)
    {
        return DiscoveryDistribution::Npx {
            package: package.to_string(),
        };
    }
    if let Some(binary) = value.get("binary") {
        let platforms: Vec<String> = binary
            .as_object()
            .map(|entries| entries.keys().cloned().collect())
            .unwrap_or_default();
        if !platforms.is_empty() {
            return DiscoveryDistribution::Binary { platforms };
        }
    }
    DiscoveryDistribution::Unknown
}

fn proxy_from_env() -> Option<ureq::Proxy> {
    ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"]
        .iter()
        .find_map(|key| std::env::var(key).ok())
        .filter(|value| !value.trim().is_empty())
        .and_then(|value| ureq::Proxy::new(value.trim()).ok())
}

/// 拉取官方 registry；非 2xx/超时/解析失败一律 fail-closed（调用方可静默隐藏发现层）。
/// 外部 URL 使用系统代理 env（本机测试/内网 localhost 不走代理）。
pub fn fetch_acp_registry(
    url: &str,
    timeout: Duration,
) -> Result<Vec<DiscoveredAgent>, RegistryError> {
    let local = url.contains("127.0.0.1") || url.contains("localhost");
    let config = ureq::Agent::config_builder()
        .timeout_global(Some(timeout))
        .proxy(if local { None } else { proxy_from_env() })
        .build();
    let agent: ureq::Agent = config.into();
    let mut response = agent
        .get(url)
        .call()
        .map_err(|error| RegistryError::InvalidEntry(format!("registry fetch failed: {error}")))?;
    let raw = response
        .body_mut()
        .read_to_string()
        .map_err(|error| RegistryError::InvalidJson(format!("read registry body: {error}")))?;
    parse_acp_registry(&raw)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read as _, Write as _};
    use std::net::TcpListener;

    const SAMPLE: &str = r#"{
      "version": "1.0.0",
      "agents": [
        {
          "id": "amp-acp",
          "name": "Amp",
          "version": "0.10.0",
          "description": "ACP wrapper for Amp",
          "distribution": {"binary": {"darwin-aarch64": {"archive": "x", "cmd": "amp", "sha256": "y"}}}
        },
        {
          "id": "npx-agent",
          "name": "NPX Agent",
          "version": "1.2.3",
          "distribution": {"npx": {"package": "npx-agent@1.2.3"}}
        },
        {"id": "", "name": "broken"}
      ]
    }"#;

    #[test]
    fn parses_official_registry_entries() {
        let agents = parse_acp_registry(SAMPLE).expect("parse");
        assert_eq!(agents.len(), 2);
        assert_eq!(agents[0].id, "amp-acp");
        assert_eq!(agents[0].version, "0.10.0");
        assert!(matches!(
            agents[0].distribution,
            DiscoveryDistribution::Binary { ref platforms } if platforms == &vec!["darwin-aarch64".to_string()]
        ));
        assert_eq!(agents[1].name, "NPX Agent");
        assert!(matches!(
            agents[1].distribution,
            DiscoveryDistribution::Npx { ref package } if package == "npx-agent@1.2.3"
        ));
    }

    #[test]
    fn invalid_or_empty_registry_is_rejected() {
        assert!(matches!(
            parse_acp_registry("not json"),
            Err(RegistryError::InvalidJson(_))
        ));
        assert!(matches!(
            parse_acp_registry(r#"{"version":"1.0.0"}"#),
            Err(RegistryError::InvalidEntry(_))
        ));
        assert!(matches!(
            parse_acp_registry(r#"{"version":"1.0.0","agents":[]}"#),
            Err(RegistryError::InvalidEntry(_))
        ));
    }

    fn spawn_mock(status: u16, body: &'static str) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let mut request = Vec::new();
            let mut buf = [0u8; 1024];
            while !request.windows(4).any(|w| w == b"\r\n\r\n") {
                let read = stream.read(&mut buf).expect("read");
                if read == 0 {
                    break;
                }
                request.extend_from_slice(&buf[..read]);
            }
            let response = format!(
                "HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            stream.write_all(response.as_bytes()).expect("write");
        });
        format!("http://{addr}/registry.json")
    }

    #[test]
    fn fetch_reads_and_parses_http() {
        let url = spawn_mock(200, SAMPLE);
        let agents = fetch_acp_registry(&url, Duration::from_secs(5)).expect("fetch");
        assert_eq!(agents.len(), 2);
    }

    #[test]
    fn fetch_non_2xx_fails_closed() {
        let url = spawn_mock(503, "{}");
        assert!(fetch_acp_registry(&url, Duration::from_secs(5)).is_err());
    }
}
