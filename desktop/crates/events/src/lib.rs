//! CGC Desktop 的 `events` feature crate。
//!
//! 约束（脊柱 AD-1）：feature 之间不互相依赖，只依赖 `platform` 的端口 trait。

pub mod detail;
pub mod enroll;
pub mod enrollments;
pub mod list;
pub mod orders;
pub mod registration;
