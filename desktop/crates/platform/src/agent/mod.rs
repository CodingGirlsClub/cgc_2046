//! agent 接入与启动（Zed `agent_servers` 的角色）：探测、启动参数、进程生命周期、与 registry 衔接。

pub mod detect;
pub mod launch;
pub mod lifecycle;
pub mod node_runtime;
