//! CGC Desktop 的「学习搭子」domain crate：课程页的 agent 对话（流式、工具卡、审批卡、历史、模型选择）。
//!
//! 约束（脊柱 AD-1）：domain crate 之间不互相依赖，只依赖 `platform` 的端口 trait；
//! agent 进程的启动与 ACP 通信在 `platform/agent`，不在本 crate。
