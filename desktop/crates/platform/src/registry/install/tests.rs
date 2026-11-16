use super::*;
use crate::agent::launch::NodeRuntime;
use crate::registry::manifest::Distribution;

fn entry(id: &str, package: &str, requires_dsh: bool) -> AgentEntry {
    AgentEntry {
        id: id.to_string(),
        display_name: id.to_string(),
        distribution: Distribution::Npx {
            package: package.to_string(),
            version: "1.0.0".to_string(),
            node: "24".to_string(),
        },
        launch_args: Vec::new(),
        version_args: Vec::new(),
        minimum_version: "1.0.0".to_string(),
        mcp_server_name: "mcp".to_string(),
        login_hint: "login".to_string(),
        requires: if requires_dsh {
            vec!["dsh-runtime".to_string()]
        } else {
            Vec::new()
        },
        download_hint: None,
    }
}

#[test]
fn uninstalls_package_and_isolated_dsh_home_idempotently() {
    let root = std::env::temp_dir().join(format!(
        "cgc-uninstall-{}-{}",
        std::process::id(),
        NEXT_INSTALL.fetch_add(1, Ordering::Relaxed)
    ));
    let runtime = NodeRuntime::new(root.join("node24"));
    let dsh_entry = entry("dsh-test", "@openma/deepseek-harness-acp", true);
    let package_dir = install_dir(&dsh_entry, &runtime);
    std::fs::create_dir_all(package_dir.join("node_modules")).unwrap();
    let dsh_home = root.join("dsh-home");
    std::fs::create_dir_all(&dsh_home).unwrap();
    std::fs::write(dsh_home.join("session.lock"), b"").unwrap();

    let result = uninstall_entry(&dsh_entry, Some(&runtime), Some(&dsh_home)).unwrap();
    assert!(result.removed_package);
    assert!(result.removed_dsh_home);
    assert!(!package_dir.exists(), "package directory removed");
    assert!(!dsh_home.exists(), "isolated DSH_HOME removed");

    let again = uninstall_entry(&dsh_entry, Some(&runtime), Some(&dsh_home)).unwrap();
    assert!(!again.removed_package);
    assert!(!again.removed_dsh_home);
    let _ = std::fs::remove_dir_all(&root);
}

#[cfg(unix)]
#[test]
fn plugin_install_writes_profile_without_touching_home_data() {
    use std::os::unix::fs::PermissionsExt;
    let root = std::env::temp_dir().join(format!(
        "cgc-plugin-install-{}-{}",
        std::process::id(),
        NEXT_INSTALL.fetch_add(1, Ordering::Relaxed)
    ));
    let dsh = root.join("dsh");
    std::fs::create_dir_all(&root).expect("root");
    std::fs::write(
            &dsh,
            b"#!/bin/sh\ncd \"${DSH_HOME:?}/profiles/acp\" || exit 41\nif [ \"$4\" = add ]; then printf '{\"dependencies\":{\"@openma/deepseek-harness-acp\":\"%s\"}}' \"${5##*@}\" > package.json; else printf '{\"dependencies\":{}}' > package.json; fi\n",
        )
        .unwrap();
    let mut perms = std::fs::metadata(&dsh).unwrap().permissions();
    perms.set_mode(0o755);
    std::fs::set_permissions(&dsh, perms).unwrap();
    let home = root.join("dsh-home");
    std::fs::create_dir_all(crate::agent::dsh_plugin::profile_dir(&home)).unwrap();
    std::fs::write(home.join("settings.yaml"), b"keep").unwrap();
    let mut dsh_entry = entry("dsh-test", "@openma/deepseek-harness-acp", true);
    if let Distribution::Npx { version, .. } = &mut dsh_entry.distribution {
        *version = "0.4.41".to_string();
    }
    let env = |key: &str| match key {
        "DSH_CLI" => Some(dsh.clone()),
        "DSH_HOME" => Some(home.clone()),
        _ => None,
    };
    let (target_dsh, target_home) = crate::agent::dsh_plugin::install_target_with(env)
        .expect("local CLI must be installable before the adapter is declared");
    assert!(crate::agent::dsh_plugin::probe_with(env).is_none());

    let result =
        install_plugin_entry(&dsh_entry, &target_dsh, &target_home).expect("plugin install");
    assert_eq!(result.version.as_deref(), Some("0.4.41"));
    assert_eq!(
        crate::agent::dsh_plugin::read_profile_version(&home, "@openma/deepseek-harness-acp")
            .as_deref(),
        Some("0.4.41")
    );
    let title_patch = crate::agent::dsh_plugin::profile_dir(&home).join("cordis.patch.yml");
    let enabled = std::fs::read_to_string(&title_patch).unwrap();
    let patches: Vec<serde_json::Value> = serde_saphyr::from_str(&enabled).unwrap();
    assert_eq!(
        patches,
        vec![serde_json::json!({"id": "session-title-llm", "disabled": false})]
    );
    install_plugin_entry(&dsh_entry, &target_dsh, &target_home).expect("plugin upgrade");
    assert_eq!(std::fs::read_to_string(&title_patch).unwrap(), enabled);
    assert_eq!(
        std::fs::read(home.join("settings.yaml")).unwrap(),
        b"keep",
        "plugin install must not touch user DSH data"
    );

    let plugin = crate::agent::dsh_plugin::probe_with(env).expect("installed profile");
    let removed = uninstall_plugin_entry(&dsh_entry, &plugin).expect("plugin uninstall");
    assert!(removed.removed_package);
    assert!(!removed.removed_dsh_home);
    assert!(home.exists(), "plugin uninstall must keep DSH_HOME");
    assert_eq!(
        crate::agent::dsh_plugin::read_profile_version(&home, "@openma/deepseek-harness-acp"),
        None,
        "uninstall must remove the adapter from the same custom DSH_HOME"
    );
    let manifest = crate::agent::dsh_plugin::profile_dir(&home).join("package.json");
    std::fs::write(
        manifest,
        r#"{"dependencies":{"@openma/deepseek-harness-acp":"0.4.41"}}"#,
    )
    .unwrap();
    std::fs::write(&plugin.dsh, b"#!/bin/sh\nexit 0\n").unwrap();
    let error = uninstall_plugin_entry(&dsh_entry, &plugin).expect_err("unchanged profile");
    assert!(error.to_string().contains("still declared"));
    let _ = std::fs::remove_dir_all(&root);
}

#[cfg(unix)]
#[test]
fn plugin_install_rejects_version_mismatch() {
    use std::os::unix::fs::PermissionsExt;
    let root = std::env::temp_dir().join(format!(
        "cgc-plugin-mismatch-{}-{}",
        std::process::id(),
        NEXT_INSTALL.fetch_add(1, Ordering::Relaxed)
    ));
    std::fs::create_dir_all(&root).expect("root");
    let dsh = root.join("dsh");
    std::fs::write(
            &dsh,
            b"#!/bin/sh\nprintf '{\"dependencies\":{\"@openma/deepseek-harness-acp\":\"0.0.0\"}}' > package.json\n",
        )
        .unwrap();
    let mut perms = std::fs::metadata(&dsh).unwrap().permissions();
    perms.set_mode(0o755);
    std::fs::set_permissions(&dsh, perms).unwrap();
    let home = root.join("dsh-home");
    let mut dsh_entry = entry("dsh-test", "@openma/deepseek-harness-acp", true);
    if let Distribution::Npx { version, .. } = &mut dsh_entry.distribution {
        *version = "0.4.41".to_string();
    }
    let error = install_plugin_entry(&dsh_entry, &dsh, &home).expect_err("mismatch must fail");
    assert!(error.to_string().contains("expected"), "got {error}");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn shared_local_dsh_home_is_never_removed() {
    let root = std::env::temp_dir().join(format!(
        "cgc-uninstall-shared-{}-{}",
        std::process::id(),
        NEXT_INSTALL.fetch_add(1, Ordering::Relaxed)
    ));
    let runtime = NodeRuntime::new(root.join("node24"));
    let dsh_entry = entry("dsh-test", "@openma/deepseek-harness-acp", true);
    let package_dir = install_dir(&dsh_entry, &runtime);
    std::fs::create_dir_all(package_dir.join("node_modules")).unwrap();
    let shared_home = root.join("local-dsh");
    std::fs::create_dir_all(&shared_home).unwrap();
    std::fs::write(shared_home.join("settings.yaml"), b"llm").unwrap();

    // 共享模式由调用方传 None：卸载只删 CGC 安装包。
    let result = uninstall_entry(&dsh_entry, Some(&runtime), None).unwrap();
    assert!(result.removed_package);
    assert!(!result.removed_dsh_home);
    assert!(
        shared_home.join("settings.yaml").exists(),
        "shared DSH data must survive uninstall"
    );
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn non_dsh_uninstall_keeps_dsh_home() {
    let root = std::env::temp_dir().join(format!(
        "cgc-uninstall-plain-{}-{}",
        std::process::id(),
        NEXT_INSTALL.fetch_add(1, Ordering::Relaxed)
    ));
    let runtime = NodeRuntime::new(root.join("node24"));
    let plain = entry("codex-test", "@agentclientprotocol/codex-acp", false);
    let dsh_home = root.join("dsh-home");
    std::fs::create_dir_all(&dsh_home).unwrap();
    let result = uninstall_entry(&plain, Some(&runtime), Some(&dsh_home)).unwrap();
    assert!(!result.removed_dsh_home);
    assert!(dsh_home.exists());
    let _ = std::fs::remove_dir_all(&root);
}
