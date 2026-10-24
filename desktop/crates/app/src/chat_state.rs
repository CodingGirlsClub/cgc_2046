//! 对话本地状态：只保存每课会话指针与 agent 偏好，不保存任何对话内容。

fn chat_state_path() -> std::path::PathBuf {
    if let Some(path) = std::env::var_os("CGC_CHAT_STATE_FILE") {
        return path.into();
    }
    cgc_platform::paths::AppPaths::from_env().chat_state_file()
}

pub(crate) fn read_chat_state() -> serde_json::Value {
    std::fs::read_to_string(chat_state_path())
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or_else(|| serde_json::json!({ "pointers": {}, "prefs": {} }))
}

pub(crate) fn write_chat_state(state: &serde_json::Value) {
    write_chat_state_to(&chat_state_path(), state);
}

pub(crate) fn write_chat_state_to(path: &std::path::Path, state: &serde_json::Value) {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(raw) = serde_json::to_string_pretty(state) {
        let _ = std::fs::write(path, raw);
    }
}

pub(crate) fn load_chat_pointer(course_id: &str, agent_id: &str) -> Option<String> {
    let state = read_chat_state();
    let pointer = state.get("pointers")?.get(course_id)?;
    if pointer.get("agent")?.as_str()? != agent_id {
        return None;
    }
    pointer.get("sessionId")?.as_str().map(str::to_string)
}

pub(crate) fn save_chat_pointer(course_id: &str, agent: &str, session_id: &str) {
    let mut state = read_chat_state();
    if let Some(pointers) = state.get_mut("pointers") {
        pointers[course_id] = serde_json::json!({ "agent": agent, "sessionId": session_id });
    }
    write_chat_state(&state);
}

pub(crate) fn clear_chat_pointer(course_id: &str) {
    let mut state = read_chat_state();
    if let Some(pointers) = state.get_mut("pointers") {
        if let Some(object) = pointers.as_object_mut() {
            object.remove(course_id);
        }
    }
    write_chat_state(&state);
}

pub(crate) fn load_installed_agents() -> std::collections::BTreeMap<String, String> {
    read_chat_state()
        .get("installed_agents")
        .and_then(|value| value.as_object())
        .map(|agents| {
            agents
                .iter()
                .filter_map(|(id, version)| {
                    version
                        .as_str()
                        .map(|version| (id.clone(), version.to_string()))
                })
                .collect()
        })
        .unwrap_or_default()
}

pub(crate) fn save_installed_agent(id: &str, version: &str) {
    let mut state = read_chat_state();
    state["installed_agents"][id] = serde_json::json!(version);
    write_chat_state(&state);
}

pub(crate) fn load_selected_agent() -> Option<String> {
    read_chat_state()
        .get("selected_agent")?
        .as_str()
        .map(str::to_string)
}

pub(crate) fn load_native_chat_mode() -> Option<bool> {
    read_chat_state().get("native_chat_mode")?.as_bool()
}

pub(crate) fn save_native_chat_mode(enabled: bool) {
    let mut state = read_chat_state();
    state["native_chat_mode"] = serde_json::json!(enabled);
    write_chat_state(&state);
}

pub(crate) fn save_selected_agent(agent: &str) {
    let mut state = read_chat_state();
    state["selected_agent"] = serde_json::json!(agent);
    write_chat_state(&state);
}

pub(crate) fn load_chat_pref(agent: &str, config_id: &str) -> Option<String> {
    read_chat_state()
        .get("prefs")?
        .get(agent)?
        .get(config_id)?
        .as_str()
        .map(str::to_string)
}

pub(crate) fn save_chat_pref(agent: &str, config_id: &str, value: &str) {
    let mut state = read_chat_state();
    if !state.get("prefs").is_some_and(serde_json::Value::is_object) {
        state["prefs"] = serde_json::json!({});
    }
    state["prefs"][agent][config_id] = serde_json::json!(value);
    write_chat_state(&state);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chat_state_persists_only_pointers_and_prefs() {
        let dir = std::env::temp_dir().join(format!("cgc-chat-state-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("mkdir");
        let path = dir.join("chat_state.json");
        let mut state = serde_json::json!({ "pointers": {}, "prefs": {} });
        state["pointers"]["course-1"] =
            serde_json::json!({ "agent": "omp", "sessionId": "session-1" });
        state["prefs"]["omp"]["model"] = serde_json::json!("gpt-6");
        write_chat_state_to(&path, &state);
        let raw = std::fs::read_to_string(&path).expect("read");
        assert!(raw.contains("session-1"));
        assert!(raw.contains("gpt-6"));
        for forbidden in [
            "messages",
            "content",
            "answer",
            "user_text",
            "assistant_text",
        ] {
            assert!(
                !raw.contains(forbidden),
                "chat content key leaked: {forbidden}"
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
