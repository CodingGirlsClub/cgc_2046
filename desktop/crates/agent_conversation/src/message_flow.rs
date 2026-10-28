//! 双栈共用的消息流纯逻辑（Stage 0 引入，Stage 1 从 `app` 迁入 `agent_ui`）。
//!
//! 收口三件行为，避免 native 与 ACP 各写一份：
//! - 哪些消息挂消息操作栏（Copy This Agent Response / Scroll to User Message /
//!   Scroll to Top）；
//! - `Copy This Agent Response` 复制哪段文本；
//! - `Scroll to User Message` 落到哪条用户消息。
//!
//! 渲染仍在各自视图里（Agent 类型与状态不同），这里只放与视图模型无关的判定。
//! 两套视图各自构造 [`RowView`]（提供「行分类」与「assistant 文本」两个窄函数），
//! 不要求视图模型实现本 crate 的 trait（避免跨 crate trait/孤儿规则耦合）。
//!
//! 规则对齐 Zed（#61245 + #61362）：
//! - 操作栏只挂在**回合末**的 assistant 消息上，而不是每个工具调用边界；
//! - 历史消息的操作栏在流式生成时仍可见，只有底部那条在生成中/等审批时隐藏；
//! - `Copy This Agent Response` 复制**整回合**文本（上一用户消息之后、下一条
//!   用户消息之前的所有 assistant 文本），跳过 thinking；
//! - `Scroll to Top` 只在线程底部出现。
//!
//! 与 Zed 的有意偏离：末行是「刚发出、还没回复」的用户消息时，我们不补底部
//! fallback 条（Zed 会渲染一条），因为那会在同一屏出现两条视觉重复的操作栏；
//! per-message 条与 fallback 条也做了去重，不会指向同一条 assistant。

/// 消息行种类（与具体视图模型无关）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RowKind {
    User,
    Assistant,
    Thinking,
    Tool,
    Permission,
    /// system / error 这类状态行。
    Status,
}

/// 一条消息操作栏要展示什么。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ActionPlan {
    /// `Scroll to User Message` 的目标（该回复之前最近一条用户消息）。
    pub scroll_to_user: Option<usize>,
    /// 只有线程底部的那条才出现 `Scroll to Top`。
    pub scroll_to_top: bool,
}

/// 线程底部、且回合末不是 assistant 消息时的兜底操作栏（Zed #61245 的
/// last-assistant fallback；例如取消时停在工具卡）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TrailingPlan {
    /// 复制哪条 assistant 消息所属回合的文本。
    pub assistant_index: usize,
    pub scroll_to_user: Option<usize>,
}

/// 对一段「消息行」的只读视图。
///
/// `kind_of` 把任意视图模型的行映射成 [`RowKind`]；`assistant_text` 只在
/// assistant 行返回 Markdown 原文。用函数指针而不是 trait，让两套视图模型
/// 无需反向依赖本 crate（native 的 `UiMessage` 在 `agent_host`，ACP 的
/// `ChatEntry` 在 `app`，都不能实现本 crate 的 trait）。
pub struct RowView<'a, T> {
    rows: &'a [T],
    kind_of: fn(&T) -> RowKind,
    assistant_text: for<'x> fn(&'x T) -> Option<&'x str>,
}

impl<'a, T> RowView<'a, T> {
    pub fn new(
        rows: &'a [T],
        kind_of: fn(&T) -> RowKind,
        assistant_text: for<'x> fn(&'x T) -> Option<&'x str>,
    ) -> Self {
        Self {
            rows,
            kind_of,
            assistant_text,
        }
    }

    pub fn rows(&self) -> &'a [T] {
        self.rows
    }

    fn kind_at(&self, index: usize) -> Option<RowKind> {
        self.rows.get(index).map(self.kind_of)
    }

    /// 回合末判定：后面遇到下一条用户消息 → 是回合末；后面还有 assistant 或工具
    /// 调用 → 不是；其它行（thinking / 权限 / 状态）跳过。线程末尾返回 `None`，
    /// 由调用方按「是否正在生成」兜底（对齐 Zed `entry_is_finalized_turn_end`）。
    pub fn finalized_turn_end(&self, index: usize) -> Option<bool> {
        if self.kind_at(index)? != RowKind::Assistant {
            return Some(false);
        }
        for row in self.rows.get(index + 1..)? {
            match (self.kind_of)(row) {
                RowKind::User => return Some(true),
                RowKind::Assistant | RowKind::Tool => return Some(false),
                RowKind::Thinking | RowKind::Permission | RowKind::Status => {}
            }
        }
        None
    }

    /// 第 `index` 行之前最近的一条用户消息。
    pub fn previous_user_index(&self, index: usize) -> Option<usize> {
        self.rows
            .get(..index)?
            .iter()
            .rposition(|row| (self.kind_of)(row) == RowKind::User)
    }

    /// 第 `index` 行所属回合的回复文本：从该回合用户消息之后到下一条用户消息
    /// 之前，拼接所有非空 assistant 文本（跳过 thinking）。
    pub fn turn_copy_text(&self, index: usize) -> Option<String> {
        if self.kind_at(index)? == RowKind::User {
            return None;
        }
        let start = self
            .previous_user_index(index)
            .map(|user_index| user_index + 1)
            .unwrap_or(0);
        let end = self
            .rows
            .get(index + 1..)?
            .iter()
            .position(|row| (self.kind_of)(row) == RowKind::User)
            .map(|offset| index + 1 + offset)
            .unwrap_or(self.rows.len());
        let parts: Vec<&str> = self.rows[start..end]
            .iter()
            .filter_map(|row| (self.assistant_text)(row))
            .filter(|text| !text.trim().is_empty())
            .collect();
        if parts.is_empty() {
            None
        } else {
            Some(parts.join("\n\n"))
        }
    }

    /// 某条 assistant 消息是否该挂消息操作栏，以及挂哪些按钮。
    ///
    /// `generating` = 当前回合是否在跑（native: busy；ACP: phase == Streaming）；
    /// `needs_confirmation` = 是否有待处理审批（native: pending_permission；
    /// ACP: 存在未解决的权限条目）。
    pub fn action_plan(
        &self,
        index: usize,
        generating: bool,
        needs_confirmation: bool,
    ) -> Option<ActionPlan> {
        if self.kind_at(index)? != RowKind::Assistant {
            return None;
        }
        if (self.assistant_text)(self.rows.get(index)?).is_none_or(|text| text.trim().is_empty()) {
            return None;
        }
        // 与 Zed 一致：回合末判定返回 None（线程末尾）时按 !generating 兜底；
        // 底部条在等审批时整条隐藏（历史消息的条保持可见）。
        //
        // thinking / 权限 / 状态行不是 Zed 意义上的 entry（在 Zed 里分别是 chunk、
        // 独立 permission store、notice），它们出现在 assistant 之后时不应把该
        // assistant 挤出「底部」，否则末尾残留一条已解决的权限行会让 Scroll to Top
        // 整轮消失。
        let is_bottom = self.rows[index + 1..].iter().all(|row| {
            matches!(
                (self.kind_of)(row),
                RowKind::Thinking | RowKind::Permission | RowKind::Status
            )
        });
        if is_bottom && needs_confirmation {
            return None;
        }
        let is_turn_end = self.finalized_turn_end(index).unwrap_or(!generating);
        if !is_turn_end {
            return None;
        }
        Some(ActionPlan {
            scroll_to_user: self.previous_user_index(index),
            scroll_to_top: is_bottom,
        })
    }

    /// 线程末尾兜底操作栏：最后一行不是 assistant（也不是「刚发出、还没回复」的
    /// 用户消息）时，在底部补一条，复制最近一条 assistant 所属回合的文本。
    pub fn trailing_plan(
        &self,
        generating: bool,
        needs_confirmation: bool,
    ) -> Option<TrailingPlan> {
        let last = self.rows.last()?;
        if matches!((self.kind_of)(last), RowKind::Assistant | RowKind::User) {
            return None;
        }
        if generating || needs_confirmation {
            return None;
        }
        let assistant_index = self
            .rows
            .iter()
            .rposition(|row| (self.kind_of)(row) == RowKind::Assistant)?;
        // 该 assistant 已经能挂 per-message 操作栏时不再补底部条，避免同一回合出现两条。
        if self
            .action_plan(assistant_index, generating, needs_confirmation)
            .is_some()
        {
            return None;
        }
        Some(TrailingPlan {
            assistant_index,
            scroll_to_user: self.previous_user_index(assistant_index),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{ActionPlan, RowKind, RowView, TrailingPlan};

    #[derive(Clone, Copy)]
    struct TestRow {
        kind: RowKind,
        text: &'static str,
    }

    fn kind_of(row: &TestRow) -> RowKind {
        row.kind
    }

    fn assistant_text(row: &TestRow) -> Option<&str> {
        (row.kind == RowKind::Assistant).then_some(row.text)
    }

    fn view(rows: &[TestRow]) -> RowView<'_, TestRow> {
        RowView::new(rows, kind_of, assistant_text)
    }

    impl TestRow {
        fn user(text: &'static str) -> Self {
            Self {
                kind: RowKind::User,
                text,
            }
        }

        fn assistant(text: &'static str) -> Self {
            Self {
                kind: RowKind::Assistant,
                text,
            }
        }

        fn tool() -> Self {
            Self {
                kind: RowKind::Tool,
                text: "",
            }
        }

        fn thinking(text: &'static str) -> Self {
            Self {
                kind: RowKind::Thinking,
                text,
            }
        }

        fn permission() -> Self {
            Self {
                kind: RowKind::Permission,
                text: "",
            }
        }

        fn status() -> Self {
            Self {
                kind: RowKind::Status,
                text: "",
            }
        }
    }

    #[test]
    fn finalized_turn_end_only_marks_last_assistant_before_next_user() {
        let rows = [
            TestRow::user("q1"),
            TestRow::assistant("a1"),
            TestRow::tool(),
            TestRow::assistant("a2"),
            TestRow::user("q2"),
            TestRow::assistant("a3"),
        ];
        let rows = view(&rows);
        assert_eq!(
            rows.finalized_turn_end(1),
            Some(false),
            "工具调用后还有回复"
        );
        assert_eq!(rows.finalized_turn_end(3), Some(true), "下一条用户消息前");
        assert_eq!(rows.finalized_turn_end(5), None, "线程末尾交给调用方兜底");
        assert_eq!(
            rows.finalized_turn_end(0),
            Some(false),
            "用户消息不是回合末"
        );
    }

    #[test]
    fn thinking_and_permission_rows_are_skipped_when_scanning_turn_end() {
        let rows = [
            TestRow::user("q"),
            TestRow::assistant("a"),
            TestRow::thinking("t"),
            TestRow::permission(),
            TestRow::user("next"),
        ];
        assert_eq!(view(&rows).finalized_turn_end(1), Some(true));
    }

    #[test]
    fn previous_user_index_finds_latest_prior_user() {
        let rows = [
            TestRow::user("u1"),
            TestRow::assistant("a1"),
            TestRow::thinking("t"),
            TestRow::user("u2"),
            TestRow::assistant("a2"),
        ];
        let rows = view(&rows);
        assert_eq!(rows.previous_user_index(4), Some(3));
        assert_eq!(rows.previous_user_index(1), Some(0));
        assert_eq!(rows.previous_user_index(0), None);
        assert_eq!(rows.previous_user_index(99), None);
    }

    #[test]
    fn turn_copy_text_collects_whole_turn_and_skips_thinking() {
        let rows = [
            TestRow::user("q1"),
            TestRow::assistant("answer one"),
            TestRow::thinking("private reasoning"),
            TestRow::tool(),
            TestRow::assistant("answer two"),
            TestRow::user("q2"),
            TestRow::assistant("answer three"),
        ];
        let rows = view(&rows);
        assert_eq!(
            rows.turn_copy_text(1).as_deref(),
            Some("answer one\n\nanswer two")
        );
        assert_eq!(
            rows.turn_copy_text(4).as_deref(),
            Some("answer one\n\nanswer two")
        );
        assert_eq!(rows.turn_copy_text(6).as_deref(), Some("answer three"));
        assert_eq!(rows.turn_copy_text(0), None, "用户消息没有 agent response");
        assert_eq!(rows.turn_copy_text(99), None, "越界不 panic");
    }

    #[test]
    fn turn_copy_text_returns_none_for_blank_assistant() {
        let rows = [TestRow::user("q"), TestRow::assistant("   ")];
        assert_eq!(view(&rows).turn_copy_text(1), None);
    }

    #[test]
    fn action_plan_shows_only_at_turn_end_and_hides_bottom_while_generating() {
        let rows = [
            TestRow::user("q1"),
            TestRow::assistant("a1"),
            TestRow::tool(),
            TestRow::assistant("a2"),
        ];
        let rows = view(&rows);
        // 回合中（工具后还有回复）：a1 不是回合末，不挂。
        assert_eq!(rows.action_plan(1, true, false), None);
        // 线程末尾 + 生成中：底部条整条隐藏。
        assert_eq!(rows.action_plan(3, true, false), None);
        // 线程末尾 + 等审批：同样隐藏。
        assert_eq!(rows.action_plan(3, false, true), None);
        // 线程末尾 + 空闲：Copy + Scroll to User + Scroll to Top。
        let plan = rows.action_plan(3, false, false).expect("尾部条");
        assert_eq!(plan.scroll_to_user, Some(0));
        assert!(plan.scroll_to_top);
    }

    #[test]
    fn action_plan_keeps_history_visible_while_generating() {
        let rows = [
            TestRow::user("q1"),
            TestRow::assistant("a1"),
            TestRow::user("q2"),
            TestRow::assistant("a2"),
        ];
        let rows = view(&rows);
        let plan = rows.action_plan(1, true, false).expect("历史消息的操作栏");
        assert_eq!(plan.scroll_to_user, Some(0));
        assert!(!plan.scroll_to_top, "Scroll to Top 只在线程底部出现");
    }

    #[test]
    fn action_plan_ignores_blank_assistant() {
        let rows = [TestRow::user("q"), TestRow::assistant("  \n ")];
        assert_eq!(view(&rows).action_plan(1, false, false), None);
    }

    #[test]
    fn trailing_non_entry_rows_do_not_hide_bottom_controls() {
        // ACP 权限解析后条目仍留在 messages 里；它不应把最后一条 assistant
        // 挤出「底部」，否则 Scroll to Top 整轮消失。
        let rows = [
            TestRow::user("q"),
            TestRow::assistant("a"),
            TestRow::permission(),
            TestRow::status(),
        ];
        let rows = view(&rows);
        let plan = rows
            .action_plan(1, false, false)
            .expect("末尾残留权限/状态行仍算底部");
        assert!(plan.scroll_to_top);
        assert_eq!(
            rows.action_plan(1, false, true),
            None,
            "等审批时底部条仍整条隐藏"
        );
        assert_eq!(
            rows.trailing_plan(false, false),
            None,
            "per-message 条已覆盖时不重复补底部条"
        );

        let rows_thinking = [
            TestRow::user("q"),
            TestRow::assistant("a"),
            TestRow::thinking("t"),
        ];
        let rows_thinking = view(&rows_thinking);
        assert!(
            rows_thinking
                .action_plan(1, false, false)
                .expect("thinking 尾行仍算底部")
                .scroll_to_top
        );
        assert_eq!(rows_thinking.trailing_plan(false, false), None);
    }

    #[test]
    fn turn_copy_text_handles_first_row_assistant_and_empty_rows() {
        let single = [TestRow::assistant("a1")];
        assert_eq!(view(&single).turn_copy_text(0).as_deref(), Some("a1"));
        let first_row = [
            TestRow::assistant("a1"),
            TestRow::user("q"),
            TestRow::assistant("a2"),
        ];
        assert_eq!(view(&first_row).turn_copy_text(0).as_deref(), Some("a1"));
        let empty: [TestRow; 0] = [];
        assert_eq!(view(&empty).turn_copy_text(0), None);
    }

    #[test]
    fn trailing_plan_covers_turn_ended_on_tool_call() {
        let rows = [TestRow::user("q"), TestRow::assistant("a"), TestRow::tool()];
        let rows = view(&rows);
        let plan = rows.trailing_plan(false, false).expect("兜底条");
        assert_eq!(
            plan,
            TrailingPlan {
                assistant_index: 1,
                scroll_to_user: Some(0)
            }
        );
        // 生成中 / 等审批时兜底条隐藏；最后一行是 assistant 时由 action_plan 负责。
        assert_eq!(rows.trailing_plan(true, false), None);
        assert_eq!(rows.trailing_plan(false, true), None);
        let ends_on_assistant_rows = [TestRow::user("q"), TestRow::assistant("a")];
        assert_eq!(
            view(&ends_on_assistant_rows).trailing_plan(false, false),
            None
        );
        let ends_on_user_rows = [
            TestRow::user("q"),
            TestRow::assistant("a"),
            TestRow::user("q2"),
        ];
        assert_eq!(view(&ends_on_user_rows).trailing_plan(false, false), None);
        // 末尾是状态行时，per-message 操作栏已经覆盖（copy/scroll-user），不重复补条。
        let ends_on_status_rows = [
            TestRow::user("q"),
            TestRow::assistant("a"),
            TestRow::status(),
        ];
        let ends_on_status = view(&ends_on_status_rows);
        assert_eq!(ends_on_status.trailing_plan(false, false), None);
        assert!(
            ends_on_status.action_plan(1, false, false).is_some(),
            "状态行末尾由 per-message 条覆盖"
        );
        // ActionPlan 是公开结构，断言一次字段可读。
        let plan: ActionPlan = ends_on_status.action_plan(1, false, false).expect("plan");
        assert_eq!(plan.scroll_to_user, Some(0));
    }
}
