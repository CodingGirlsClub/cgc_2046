//! 内置签名 agent 清单（story 5.3）：随包发布、按固定版本与签名校验。
//!
//! 信任模型（ADR-0026）：清单签名覆盖 `registry.json` 原始字节；公钥随二进制内置。
//! 官方 ACP/MCP registry 只作发现层，安装决策只来自这份内置清单。
//! 签名算法 Ed25519；发布签名密钥的保管/轮换属 epic-6，v1 使用仓库内 dev 公钥并要求
//! release 流程重签（见 story 5.3 Notes）。

use base64::Engine as _;
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde_json::Value;

/// 内置清单公钥（Ed25519，base64；dev key，release 前由 epic-6 轮换）。
pub const BUILTIN_PUBLIC_KEY: &str = "untHOijv9YBjBbTNolki+4z+kmwYhi173W8CX+aaE9U=";
pub const BUILTIN_MANIFEST: &str = include_str!("../../resources/registry.json");
pub const BUILTIN_SIGNATURE: &str = include_str!("../../resources/registry.sig");

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Distribution {
    Native {
        command: String,
    },
    Npx {
        package: String,
        version: String,
        node: String,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentEntry {
    pub id: String,
    pub display_name: String,
    pub distribution: Distribution,
    pub launch_args: Vec<String>,
    /// 版本探测参数；空 = `["--version"]`（如 codex-acp 用 `version` 子命令）。
    pub version_args: Vec<String>,
    pub minimum_version: String,
    pub mcp_server_name: String,
    pub login_hint: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Registry {
    pub schema_version: u32,
    pub node_required: String,
    pub agents: Vec<AgentEntry>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RegistryError {
    InvalidJson(String),
    UnsupportedSchema(u32),
    BadSignature,
    InvalidEntry(String),
    MissingAgent(String),
}

impl std::fmt::Display for RegistryError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.diagnostic())
    }
}

impl std::error::Error for RegistryError {}

impl RegistryError {
    pub fn diagnostic(&self) -> String {
        match self {
            RegistryError::InvalidJson(reason) => format!("invalid registry json: {reason}"),
            RegistryError::UnsupportedSchema(version) => {
                format!("unsupported registry schema: {version}")
            }
            RegistryError::BadSignature => "registry signature verification failed".to_string(),
            RegistryError::InvalidEntry(reason) => format!("invalid registry entry: {reason}"),
            RegistryError::MissingAgent(id) => format!("agent not in registry: {id}"),
        }
    }
}

impl Registry {
    /// 校验内置清单签名并解析；任何失败都 fail-closed（不降级到未签名数据）。
    pub fn builtin() -> Result<Self, RegistryError> {
        Self::builtin_from(BUILTIN_MANIFEST)
    }

    /// 内置清单的验签入口（清单文本可注入，便于覆盖 Windows CRLF 检出）。
    ///
    /// 签名是对 LF 版本的清单算的，但 `include_str!` 取的是**工作树里的字节**：
    /// Windows 检出（core.autocrlf=true，GitHub runner 默认）会把 registry.json
    /// 转成 CRLF，直接校验必然 BadSignature —— 整个内置 registry 失效，构建出来的
    /// 包一个 agent 都装不了。所以先归一化再验签。
    fn builtin_from(manifest: &str) -> Result<Self, RegistryError> {
        let payload = normalize_line_endings(manifest);
        Self::from_signed(
            payload.as_bytes(),
            BUILTIN_SIGNATURE.trim(),
            BUILTIN_PUBLIC_KEY,
        )
    }

    pub fn from_signed(
        payload: &[u8],
        signature_b64: &str,
        public_key_b64: &str,
    ) -> Result<Self, RegistryError> {
        verify_signature(payload, signature_b64, public_key_b64)?;
        Self::parse(payload)
    }

    pub fn parse(payload: &[u8]) -> Result<Self, RegistryError> {
        let value: Value = serde_json::from_slice(payload)
            .map_err(|error| RegistryError::InvalidJson(error.to_string()))?;
        let schema_version = value
            .get("schema_version")
            .and_then(Value::as_u64)
            .unwrap_or(0) as u32;
        if schema_version != 1 {
            return Err(RegistryError::UnsupportedSchema(schema_version));
        }
        let node_required = value
            .get("node_runtime")
            .and_then(|node| node.get("required"))
            .and_then(Value::as_str)
            .ok_or_else(|| RegistryError::InvalidEntry("node_runtime.required".to_string()))?
            .to_string();
        let agents = value
            .get("agents")
            .and_then(Value::as_array)
            .ok_or_else(|| RegistryError::InvalidEntry("agents".to_string()))?
            .iter()
            .map(parse_agent)
            .collect::<Result<Vec<_>, _>>()?;
        if agents.is_empty() {
            return Err(RegistryError::InvalidEntry("agents is empty".to_string()));
        }
        Ok(Self {
            schema_version,
            node_required,
            agents,
        })
    }

    pub fn find(&self, id: &str) -> Option<&AgentEntry> {
        self.agents.iter().find(|agent| agent.id == id)
    }

    pub fn get(&self, id: &str) -> Result<&AgentEntry, RegistryError> {
        self.find(id)
            .ok_or_else(|| RegistryError::MissingAgent(id.to_string()))
    }
}

fn parse_agent(value: &Value) -> Result<AgentEntry, RegistryError> {
    let id = value
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| RegistryError::InvalidEntry("agent.id".to_string()))?
        .to_string();
    let display_name = value
        .get("display_name")
        .and_then(Value::as_str)
        .ok_or_else(|| RegistryError::InvalidEntry(format!("{id}.display_name")))?
        .to_string();
    let distribution_value = value
        .get("distribution")
        .ok_or_else(|| RegistryError::InvalidEntry(format!("{id}.distribution")))?;
    let distribution = match distribution_value.get("kind").and_then(Value::as_str) {
        Some("native") => Distribution::Native {
            command: required_str(distribution_value, "command", &id)?,
        },
        Some("npx") => {
            let node = required_str(distribution_value, "node", &id)?;
            if node != "24" {
                return Err(RegistryError::InvalidEntry(format!(
                    "{id}.distribution.node"
                )));
            }
            Distribution::Npx {
                package: required_str(distribution_value, "package", &id)?,
                version: required_str(distribution_value, "version", &id)?,
                node,
            }
        }
        _ => {
            return Err(RegistryError::InvalidEntry(format!(
                "{id}.distribution.kind"
            )))
        }
    };
    let launch_args = value
        .get("launch")
        .and_then(|launch| launch.get("args"))
        .and_then(Value::as_array)
        .map(|args| {
            args.iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();
    let version_args = value
        .get("version_args")
        .and_then(Value::as_array)
        .map(|args| {
            args.iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();
    Ok(AgentEntry {
        id: id.clone(),
        display_name,
        distribution,
        launch_args,
        version_args,
        minimum_version: required_str(value, "minimum_version", &id)?,
        mcp_server_name: required_str(value, "mcp_server_name", &id)?,
        login_hint: required_str(value, "login_hint", &id)?,
    })
}

fn required_str(value: &Value, key: &str, id: &str) -> Result<String, RegistryError> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| RegistryError::InvalidEntry(format!("{id}.{key}")))
}

/// 把 CRLF 归一化成 LF（签名是对 LF 字节算的）。
fn normalize_line_endings(text: &str) -> String {
    if text.contains('\r') {
        text.replace("\r\n", "\n")
    } else {
        text.to_string()
    }
}

fn verify_signature(
    payload: &[u8],
    signature_b64: &str,
    public_key_b64: &str,
) -> Result<(), RegistryError> {
    let engine = base64::engine::general_purpose::STANDARD;
    let key_bytes = engine
        .decode(public_key_b64)
        .map_err(|_| RegistryError::BadSignature)?;
    let key_array: [u8; 32] = key_bytes
        .try_into()
        .map_err(|_| RegistryError::BadSignature)?;
    let key = VerifyingKey::from_bytes(&key_array).map_err(|_| RegistryError::BadSignature)?;
    let signature_bytes = engine
        .decode(signature_b64)
        .map_err(|_| RegistryError::BadSignature)?;
    let signature =
        Signature::from_slice(&signature_bytes).map_err(|_| RegistryError::BadSignature)?;
    key.verify(payload, &signature)
        .map_err(|_| RegistryError::BadSignature)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builtin_registry_verifies_and_has_three_agents() {
        let registry = Registry::builtin().expect("builtin verifies");
        assert_eq!(registry.agents.len(), 3);
        assert!(registry.find("omp").is_some());
        assert!(registry.find("codex").is_some());
        assert!(registry.find("claude_code").is_some());
        assert_eq!(registry.node_required, "24.0.0");
        assert_eq!(
            registry.get("omp").expect("omp").distribution,
            Distribution::Native {
                command: "omp".to_string()
            }
        );
        match &registry.get("codex").expect("codex").distribution {
            Distribution::Npx {
                package, version, ..
            } => {
                assert_eq!(package, "@agentclientprotocol/codex-acp");
                assert_eq!(version, "2.2.2");
            }
            other => panic!("unexpected codex distribution: {other:?}"),
        }
    }

    #[test]
    fn crlf_checked_out_manifest_still_verifies() {
        // Windows 检出会把清单变成 CRLF；归一化后必须还能验签，
        // 否则 Windows 构建出的客户端内置 registry 全废。
        // 基线先归一化成 LF：Windows 上 `include_str!` 读到的本来就是 CRLF，
        // 直接 replace 会造出 `\r\r\n` 这种非法输入。
        let lf_manifest = normalize_line_endings(BUILTIN_MANIFEST);
        let crlf = lf_manifest.replace('\n', "\r\n");
        assert_ne!(crlf, lf_manifest);
        assert_eq!(normalize_line_endings(&crlf), lf_manifest);
        // 未归一化的 CRLF 载荷验签必然失败——这一步不是可选的。
        assert_eq!(
            Registry::from_signed(
                crlf.as_bytes(),
                BUILTIN_SIGNATURE.trim(),
                BUILTIN_PUBLIC_KEY
            )
            .unwrap_err(),
            RegistryError::BadSignature
        );
        // 走 builtin() 同一条路径（builtin_from）应通过——归一化被删掉这里就红。
        let registry = Registry::builtin_from(&crlf).expect("CRLF manifest verifies");
        assert_eq!(registry.agents.len(), 3);
    }

    #[test]
    fn tampered_payload_fails_closed() {
        let mut payload = BUILTIN_MANIFEST.as_bytes().to_vec();
        payload.push(b' ');
        let error = Registry::from_signed(&payload, BUILTIN_SIGNATURE.trim(), BUILTIN_PUBLIC_KEY)
            .unwrap_err();
        assert_eq!(error, RegistryError::BadSignature);
    }

    #[test]
    fn bad_public_key_or_signature_is_rejected() {
        assert_eq!(
            Registry::from_signed(b"{}", "bad", BUILTIN_PUBLIC_KEY).unwrap_err(),
            RegistryError::BadSignature
        );
        assert_eq!(
            Registry::from_signed(b"{}", BUILTIN_SIGNATURE.trim(), "bad").unwrap_err(),
            RegistryError::BadSignature
        );
    }

    #[test]
    fn unknown_schema_is_rejected() {
        let payload =
            br#"{"schema_version": 2, "agents": [], "node_runtime": {"required": "24.0.0"}}"#;
        assert_eq!(
            Registry::parse(payload).unwrap_err(),
            RegistryError::UnsupportedSchema(2)
        );
    }

    #[test]
    fn unknown_agent_id_is_reported() {
        let registry = Registry::builtin().expect("builtin");
        assert_eq!(
            registry.get("unknown").unwrap_err(),
            RegistryError::MissingAgent("unknown".to_string())
        );
    }
}
