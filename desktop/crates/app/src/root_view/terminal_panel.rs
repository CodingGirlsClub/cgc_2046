//! 终端实例表（B1, #1272）。
//!
//! 身份只认 `id`；`cwd` 是实例数据，同目录允许多开（UI 明示）。
//! 面板是否显示终端由 `active` 决定：切到 agent 只 `hide()`，实例与 PTY 保留。

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub(in crate::root_view) type LiveTerminalPanel =
    TerminalPanel<gpui_kit::Entity<cgc_terminal_view::TerminalView>>;

pub(in crate::root_view) struct AgentTerminal<V> {
    pub id: String,
    pub view: V,
    pub custom_title: Option<String>,
    pub live_title: Option<String>,
    pub live_cwd: Option<String>,
    pub spawn_cwd: Option<PathBuf>,
}

pub(in crate::root_view) struct TerminalPanel<V> {
    terminals: BTreeMap<String, AgentTerminal<V>>,
    /// 最近激活顺序，末尾最新；关闭 active 时回落到它。
    recent: Vec<String>,
    active: Option<String>,
    last_cwd: Option<PathBuf>,
}

impl<V> Default for TerminalPanel<V> {
    fn default() -> Self {
        Self {
            terminals: BTreeMap::new(),
            recent: Vec::new(),
            active: None,
            last_cwd: None,
        }
    }
}

impl<V> TerminalPanel<V> {
    pub fn len(&self) -> usize {
        self.terminals.len()
    }

    pub fn can_open(&self, limit: usize) -> bool {
        self.terminals.len() < limit
    }

    pub fn contains(&self, id: &str) -> bool {
        self.terminals.contains_key(id)
    }

    pub fn get(&self, id: &str) -> Option<&AgentTerminal<V>> {
        self.terminals.get(id)
    }

    pub fn get_mut(&mut self, id: &str) -> Option<&mut AgentTerminal<V>> {
        self.terminals.get_mut(id)
    }

    pub fn active_id(&self) -> Option<&str> {
        self.active.as_deref()
    }

    pub fn active(&self) -> Option<&AgentTerminal<V>> {
        self.active.as_deref().and_then(|id| self.terminals.get(id))
    }

    pub fn is_active(&self, id: &str) -> bool {
        self.active.as_deref() == Some(id)
    }

    pub fn iter(&self) -> impl Iterator<Item = &AgentTerminal<V>> {
        self.terminals.values()
    }

    /// 切到非终端内容：只隐藏，实例与 PTY 保留。
    pub fn hide(&mut self) {
        self.active = None;
    }

    pub fn activate(&mut self, id: &str) -> bool {
        if !self.terminals.contains_key(id) {
            return false;
        }
        self.active = Some(id.to_string());
        self.touch(id);
        true
    }

    pub fn insert(&mut self, terminal: AgentTerminal<V>) {
        let id = terminal.id.clone();
        self.terminals.insert(id.clone(), terminal);
        self.active = Some(id.clone());
        self.touch(&id);
    }

    pub fn remove(&mut self, id: &str) -> Option<AgentTerminal<V>> {
        let removed = self.terminals.remove(id)?;
        self.recent.retain(|recent| recent != id);
        if self.active.as_deref() == Some(id) {
            self.active = self.recent.last().cloned();
        }
        Some(removed)
    }

    /// 同一目录的存活实例数（live cwd 优先，spawn 目录兜底）。
    pub fn same_cwd_count(&self, directory: &str) -> usize {
        self.terminals
            .values()
            .filter(|terminal| {
                terminal
                    .live_cwd
                    .as_deref()
                    .filter(|cwd| !cwd.trim().is_empty())
                    .or_else(|| terminal.spawn_cwd.as_deref().and_then(Path::to_str))
                    .is_some_and(|cwd| cwd == directory)
            })
            .count()
    }

    /// 循环切换 active 实例；`forward=false` 反向。少于 2 个时无操作。
    pub fn cycle(&mut self, forward: bool) -> bool {
        let ids: Vec<&String> = self.terminals.keys().collect();
        if ids.len() < 2 {
            return false;
        }
        let current = self
            .active
            .as_ref()
            .and_then(|active| ids.iter().position(|id| *id == active));
        let next = match current {
            None if forward => 0,
            None => ids.len() - 1,
            Some(index) if forward => (index + 1) % ids.len(),
            Some(index) => (index + ids.len() - 1) % ids.len(),
        };
        let id = ids[next].clone();
        self.activate(&id)
    }

    pub fn last_cwd(&self) -> Option<&Path> {
        self.last_cwd.as_deref()
    }

    pub fn set_last_cwd(&mut self, cwd: Option<PathBuf>) {
        self.last_cwd = cwd;
    }

    fn touch(&mut self, id: &str) {
        self.recent.retain(|recent| recent != id);
        self.recent.push(id.to_string());
    }
}

#[cfg(test)]
mod tests {
    use super::{AgentTerminal, TerminalPanel};

    fn terminal(id: &str, cwd: Option<&str>) -> AgentTerminal<()> {
        AgentTerminal {
            id: id.to_string(),
            view: (),
            custom_title: None,
            live_title: None,
            live_cwd: None,
            spawn_cwd: cwd.map(std::path::PathBuf::from),
        }
    }

    #[test]
    fn cap_is_enforced_without_evicting() {
        let mut panel: TerminalPanel<()> = TerminalPanel::default();
        for index in 0..5 {
            assert!(panel.can_open(5));
            panel.insert(terminal(&format!("t{index}"), Some("/tmp/a")));
        }
        assert!(!panel.can_open(5));
        assert_eq!(panel.len(), 5, "达到上限不静默淘汰");
    }

    #[test]
    fn removing_active_falls_back_to_most_recent() {
        let mut panel: TerminalPanel<()> = TerminalPanel::default();
        panel.insert(terminal("a", Some("/tmp/a")));
        panel.insert(terminal("b", Some("/tmp/b")));
        assert_eq!(panel.active_id(), Some("b"));
        assert!(panel.activate("a"));
        assert_eq!(panel.active_id(), Some("a"));
        panel.remove("a");
        assert_eq!(
            panel.active_id(),
            Some("b"),
            "关闭当前实例后回落到最近激活的实例"
        );
        panel.remove("b");
        assert_eq!(panel.active_id(), None);
    }

    #[test]
    fn hiding_keeps_instances_alive() {
        let mut panel: TerminalPanel<()> = TerminalPanel::default();
        panel.insert(terminal("a", Some("/tmp/a")));
        panel.hide();
        assert_eq!(panel.active_id(), None);
        assert_eq!(panel.len(), 1, "切到 agent 只隐藏，不销毁");
        assert!(panel.activate("a"));
    }

    #[test]
    fn activating_unknown_id_is_rejected() {
        let mut panel: TerminalPanel<()> = TerminalPanel::default();
        assert!(!panel.activate("missing"));
        assert_eq!(panel.active_id(), None);
    }

    #[test]
    fn cycling_visits_all_instances_and_wraps() {
        let mut panel: TerminalPanel<()> = TerminalPanel::default();
        panel.insert(terminal("a", Some("/tmp/a")));
        panel.insert(terminal("b", Some("/tmp/b")));
        panel.insert(terminal("c", Some("/tmp/c")));
        assert!(panel.activate("a"));
        assert!(panel.cycle(true));
        assert_eq!(panel.active_id(), Some("b"));
        assert!(panel.cycle(true));
        assert_eq!(panel.active_id(), Some("c"));
        assert!(panel.cycle(true));
        assert_eq!(panel.active_id(), Some("a"), "循环回头");
        assert!(panel.cycle(false));
        assert_eq!(panel.active_id(), Some("c"), "反向循环");
    }

    #[test]
    fn cycling_with_one_instance_is_a_noop() {
        let mut panel: TerminalPanel<()> = TerminalPanel::default();
        panel.insert(terminal("a", Some("/tmp/a")));
        assert!(!panel.cycle(true));
        assert_eq!(panel.active_id(), Some("a"));
    }

    #[test]
    fn cycling_from_hidden_starts_at_an_end() {
        let mut panel: TerminalPanel<()> = TerminalPanel::default();
        panel.insert(terminal("a", Some("/tmp/a")));
        panel.insert(terminal("b", Some("/tmp/b")));
        panel.hide();
        assert!(panel.cycle(true));
        assert_eq!(panel.active_id(), Some("a"), "正向从第一个开始");
        panel.hide();
        assert!(panel.cycle(false));
        assert_eq!(panel.active_id(), Some("b"), "反向从最后一个开始");
    }

    #[test]
    fn same_cwd_count_prefers_live_cwd() {
        let mut panel: TerminalPanel<()> = TerminalPanel::default();
        panel.insert(terminal("a", Some("/tmp/a")));
        panel.insert(terminal("b", Some("/tmp/a")));
        panel.insert(terminal("c", Some("/tmp/c")));
        assert_eq!(panel.same_cwd_count("/tmp/a"), 2);
        assert_eq!(panel.same_cwd_count("/tmp/c"), 1);
        panel.get_mut("b").expect("b").live_cwd = Some("/tmp/a/sub".into());
        assert_eq!(panel.same_cwd_count("/tmp/a"), 1, "live cwd 优先于 spawn");
        assert_eq!(panel.same_cwd_count("/tmp/a/sub"), 1);
    }
}
