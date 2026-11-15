use super::*;
use std::collections::HashMap;

fn temp_dir(tag: &str) -> PathBuf {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let dir = std::env::temp_dir().join(format!(
        "cgc-dsh-plugin-{}-{tag}-{}",
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp dir");
    dir
}

fn write_dsh_cli(path: &Path) {
    std::fs::write(path, b"#!/bin/sh\n").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
    }
}

fn write_profile(home: &Path, version: &str) {
    let profile = profile_dir(home);
    std::fs::create_dir_all(&profile).expect("profile dir");
    std::fs::write(
        profile.join("package.json"),
        format!(
            r#"{{"name":"dsh-profile-acp","dependencies":{{"{DSH_PLUGIN_PACKAGE}":"{version}"}}}}"#
        ),
    )
    .expect("package.json");
}

fn env_with(pairs: &[(&str, PathBuf)]) -> HashMap<String, PathBuf> {
    pairs
        .iter()
        .map(|(key, value)| (key.to_string(), value.clone()))
        .collect()
}

#[test]
fn probe_requires_dsh_cli_and_installed_profile() {
    let root = temp_dir("probe");
    let home = root.join("dsh-home");
    let dsh = root.join("bin").join("dsh");
    std::fs::create_dir_all(dsh.parent().unwrap()).unwrap();
    write_dsh_cli(&dsh);
    let env = env_with(&[("DSH_HOME", home.clone()), ("DSH_CLI", dsh.clone())]);

    let read = |key: &str| env.get(key).cloned();
    assert_eq!(probe_with(read), None, "profile 未安装时不能算 plugin 可用");

    write_profile(&home, "0.4.41");
    assert_eq!(
        probe_with(read),
        Some(DshPlugin {
            dsh,
            home,
            version: "0.4.41".to_string(),
        })
    );
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn probe_falls_back_to_local_bin_and_home_dot_dsh() {
    let root = temp_dir("fallback");
    let home = root.join("user");
    let dsh = home.join(".local").join("bin").join("dsh");
    std::fs::create_dir_all(dsh.parent().unwrap()).unwrap();
    write_dsh_cli(&dsh);
    write_profile(&home.join(".dsh"), "0.4.41");
    let env = env_with(&[("HOME", home.clone())]);
    let read = |key: &str| env.get(key).cloned();

    let plugin = probe_with(read).expect("plugin via ~/.local/bin/dsh");
    assert_eq!(plugin.dsh, dsh);
    assert_eq!(plugin.home, home.join(".dsh"));
    let _ = std::fs::remove_dir_all(&root);
}

#[cfg(unix)]
#[test]
fn probe_skips_non_executable_dsh_candidates() {
    use std::os::unix::fs::PermissionsExt;

    let root = temp_dir("non-executable");
    let home = root.join("home");
    write_profile(&home, "0.4.41");
    let blocked = root.join("blocked/dsh");
    let usable = root.join("usable/dsh");
    for (path, mode) in [(&blocked, 0o600), (&usable, 0o700)] {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, b"#!/bin/sh\n").unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).unwrap();
    }
    let search =
        std::env::join_paths([blocked.parent().unwrap(), usable.parent().unwrap()]).unwrap();
    for explicit in [None, Some(blocked.clone())] {
        let mut env = env_with(&[("DSH_HOME", home.clone()), ("PATH", search.clone().into())]);
        if let Some(explicit) = explicit {
            env.insert("DSH_CLI".into(), explicit);
        }
        assert_eq!(probe_with(|key| env.get(key).cloned()).unwrap().dsh, usable);
    }
    let env = env_with(&[("DSH_HOME", home), ("DSH_CLI", blocked)]);
    assert_eq!(probe_with(|key| env.get(key).cloned()), None);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn title_generation_preserves_profile_and_is_idempotent() {
    for existing in [None, Some(""), Some("- id: other-plugin\n  disabled: true")] {
        let home = temp_dir("title-default");
        write_profile(&home, "0.4.41");
        let path = profile_dir(&home).join("cordis.patch.yml");
        if let Some(text) = existing {
            std::fs::write(&path, text).unwrap();
        }
        let plugin = DshPlugin {
            dsh: home.join("dsh"),
            home: home.clone(),
            version: "0.4.41".to_string(),
        };

        assert!(ensure_title_plugin_enabled(&plugin).unwrap());
        let enabled = std::fs::read_to_string(&path).unwrap();
        assert!(enabled.starts_with(existing.unwrap_or_default()));
        let entries: Vec<Value> = serde_saphyr::from_str(&enabled).unwrap();
        assert_eq!(
            entries.last().unwrap(),
            &serde_json::json!({"id": "session-title-llm", "disabled": false})
        );
        assert!(!ensure_title_plugin_enabled(&plugin).unwrap());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), enabled);
        std::fs::remove_dir_all(home).unwrap();
    }
}

#[test]
fn title_generation_supports_flow_sequence_profiles() {
    for existing in [
        "# profile overrides\n[]\n# keep trailing comment\n",
        "# profile overrides\n[{ id: other-plugin, disabled: true }]\n# keep trailing comment\n",
    ] {
        let home = temp_dir("title-flow");
        write_profile(&home, "0.4.41");
        let path = profile_dir(&home).join("cordis.patch.yml");
        std::fs::write(&path, existing).unwrap();
        let plugin = DshPlugin {
            dsh: home.join("dsh"),
            home: home.clone(),
            version: "0.4.41".to_string(),
        };

        assert!(ensure_title_plugin_enabled(&plugin).unwrap());
        let enabled = std::fs::read_to_string(&path).unwrap();
        let entries: Vec<Value> = serde_saphyr::from_str(&enabled).unwrap();
        assert_eq!(
            entries.last().unwrap(),
            &serde_json::json!({"id": "session-title-llm", "disabled": false})
        );
        assert!(enabled.starts_with("# profile overrides\n"));
        assert!(enabled.ends_with("# keep trailing comment\n"));
        if !existing.contains("[]") {
            assert_eq!(
                entries[0],
                serde_json::json!({"id": "other-plugin", "disabled": true})
            );
        }
        assert!(!ensure_title_plugin_enabled(&plugin).unwrap());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), enabled);
        std::fs::remove_dir_all(home).unwrap();
    }
}

#[test]
fn title_generation_respects_explicit_yaml_configuration() {
    for existing in [
        "- id: session-title-llm\n  disabled: true\n",
        "- id: session-title-llm\n  disabled: false\n",
        "- id: 'session-title-llm'\n  disabled: true\n",
        "- id: \"session-title-llm\" # user choice\n  disabled: true\n",
        "- disabled: true\n  id: session-title-llm\n",
        "- { id: session-title-llm, disabled: true }\n",
    ] {
        let home = temp_dir("title-explicit");
        write_profile(&home, "0.4.41");
        let path = profile_dir(&home).join("cordis.patch.yml");
        std::fs::write(&path, existing).unwrap();
        let plugin = DshPlugin {
            dsh: home.join("dsh"),
            home: home.clone(),
            version: "0.4.41".to_string(),
        };

        assert!(!ensure_title_plugin_enabled(&plugin).unwrap());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), existing);
        std::fs::remove_dir_all(home).unwrap();
    }
}

#[test]
fn title_generation_rejects_unreadable_or_malformed_patch() {
    for existing in [b"- id: [broken".as_slice(), b"\xff".as_slice()] {
        let home = temp_dir("title-invalid");
        write_profile(&home, "0.4.41");
        let path = profile_dir(&home).join("cordis.patch.yml");
        std::fs::write(&path, existing).unwrap();
        let plugin = DshPlugin {
            dsh: home.join("dsh"),
            home: home.clone(),
            version: "0.4.41".to_string(),
        };

        assert!(ensure_title_plugin_enabled(&plugin).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), existing);
        std::fs::remove_dir_all(home).unwrap();
    }
}

#[test]
fn title_generation_replaces_tagged_null_profiles() {
    for existing in [
        "!!null null\n",
        "!!null ~ # keep trailing comment\n",
        "---\n!!null null\n...\n",
    ] {
        let home = temp_dir("title-null");
        write_profile(&home, "0.4.41");
        let path = profile_dir(&home).join("cordis.patch.yml");
        std::fs::write(&path, existing).unwrap();
        let plugin = DshPlugin {
            dsh: home.join("dsh"),
            home: home.clone(),
            version: "0.4.41".to_string(),
        };

        assert!(ensure_title_plugin_enabled(&plugin).unwrap());
        let enabled = std::fs::read_to_string(&path).unwrap();
        let entries: Vec<Value> = serde_saphyr::from_str(&enabled).unwrap();
        assert_eq!(
            entries,
            vec![serde_json::json!({"id": "session-title-llm", "disabled": false})]
        );
        assert!(!ensure_title_plugin_enabled(&plugin).unwrap());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), enabled);
        std::fs::remove_dir_all(home).unwrap();
    }
}

#[cfg(unix)]
#[test]
fn credential_env_maps_magpie_key_for_adapter_gate() {
    use std::os::unix::fs::PermissionsExt;
    let root = temp_dir("cred-env");
    let home = root.join("dsh-home");
    write_profile(&home, "0.4.41");
    let credentials = home.join(".credentials.yaml");
    std::fs::write(
            &credentials,
            "version: 1\nrefs:\n  MAGPIE_GATEWAY_KEY: sk-magpie\n  DEEPSEEK_API_KEY: sk-test\nrecords:\n  x/y:\n    kind: api-key\n",
        )
        .expect("credentials");
    let mut perms = std::fs::metadata(&credentials).unwrap().permissions();
    perms.set_mode(0o600);
    std::fs::set_permissions(&credentials, perms).unwrap();
    let plugin = DshPlugin {
        dsh: root.join("dsh"),
        home: home.clone(),
        version: "0.4.41".to_string(),
    };

    let env = credential_env(&plugin);
    assert_eq!(
        env.get("MAGPIE_API_KEY").map(String::as_str),
        Some("sk-magpie")
    );
    assert_eq!(
        env.get("MAGPIE_RESPONSES_API_KEY").map(String::as_str),
        Some("sk-magpie")
    );
    assert_eq!(
        env.get("MAGPIE_ANTHROPIC_API_KEY").map(String::as_str),
        Some("sk-magpie")
    );
    assert_eq!(env.len(), 3);
    let _ = std::fs::remove_dir_all(&root);
}

#[cfg(unix)]
#[test]
fn credential_env_fails_closed_on_loose_permissions() {
    use std::os::unix::fs::PermissionsExt;
    let root = temp_dir("cred-loose");
    let home = root.join("dsh-home");
    write_profile(&home, "0.4.41");
    let credentials = home.join(".credentials.yaml");
    std::fs::write(
        &credentials,
        "version: 1\nrefs:\n  MAGPIE_GATEWAY_KEY: sk-magpie\n",
    )
    .unwrap();
    let mut perms = std::fs::metadata(&credentials).unwrap().permissions();
    perms.set_mode(0o644);
    std::fs::set_permissions(&credentials, perms).unwrap();
    let plugin = DshPlugin {
        dsh: root.join("dsh"),
        home,
        version: "0.4.41".to_string(),
    };
    assert!(credential_env(&plugin).is_empty());
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn parse_credential_refs_stops_at_records() {
    let refs = parse_credential_refs(
        "version: 1\nrefs:\n  MAGPIE_GATEWAY_KEY: \"sk-quoted\"\nrecords:\n  MAGPIE_OTHER: nope\n",
    )
    .expect("refs");
    assert_eq!(
        refs.get("MAGPIE_GATEWAY_KEY").map(String::as_str),
        Some("sk-quoted")
    );
    assert!(!refs.contains_key("MAGPIE_OTHER"));
}

#[test]
fn malformed_profile_fails_closed() {
    let root = temp_dir("malformed");
    let home = root.join("dsh-home");
    let dsh = root.join("dsh");
    write_dsh_cli(&dsh);
    std::fs::create_dir_all(profile_dir(&home)).unwrap();
    std::fs::write(profile_dir(&home).join("package.json"), "{not json").unwrap();
    let env = env_with(&[("DSH_HOME", home), ("DSH_CLI", dsh)]);
    let read = |key: &str| env.get(key).cloned();
    assert_eq!(probe_with(read), None);
    let _ = std::fs::remove_dir_all(&root);
}
