//! CGC Desktop 的 `account` feature crate。
//!
//! 约束（脊柱 AD-1）：feature 之间不互相依赖，只依赖 `platform` 的端口 trait。

pub mod registration;
