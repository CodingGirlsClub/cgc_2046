use super::*;
use std::collections::HashMap;

fn probe(
    explicit: Option<&str>,
    desktop: &[&str],
    path: &[&str],
    bundled: Option<&str>,
    versions: &[(&str, &str)],
) -> RuntimeProbe {
    let versions: HashMap<PathBuf, String> = versions
        .iter()
        .map(|(path, version)| (PathBuf::from(path), (*version).to_string()))
        .collect();
    probe_dsh_runtime_with(
        explicit.map(PathBuf::from),
        desktop.iter().map(PathBuf::from),
        path.iter().map(PathBuf::from),
        bundled.map(str::to_string),
        |candidate| versions.get(candidate).cloned(),
    )
}

#[test]
fn probe_prefers_explicit_then_desktop_then_path_then_bundled() {
    let explicit = probe(
        Some("/explicit/dsh"),
        &["/desktop/dsh"],
        &["/path/dsh"],
        Some("0.2.1-rc.5"),
        &[
            ("/explicit/dsh", "0.3.0"),
            ("/desktop/dsh", "0.2.2"),
            ("/path/dsh", "0.1.9"),
        ],
    );
    assert_eq!(explicit.source, RuntimeSource::Explicit);
    assert_eq!(explicit.version.as_deref(), Some("0.3.0"));
    assert_eq!(
        explicit.launch_arg(),
        Some("bundled"),
        "openma always uses its packaged runtime; DSH Desktop is display-only"
    );

    let desktop = probe(
        None,
        &["/desktop/dsh"],
        &["/path/dsh"],
        Some("0.2.1-rc.5"),
        &[("/desktop/dsh", "0.2.2"), ("/path/dsh", "0.1.9")],
    );
    assert_eq!(desktop.source, RuntimeSource::DshDesktop);
    assert_eq!(desktop.path.as_deref(), Some(Path::new("/desktop/dsh")));
    assert_eq!(desktop.launch_arg(), Some("bundled"));

    let path = probe(
        None,
        &[],
        &["/path/dsh"],
        Some("0.2.1-rc.5"),
        &[("/path/dsh", "0.1.9")],
    );
    assert_eq!(path.source, RuntimeSource::Path);
    assert_eq!(path.launch_arg(), Some("bundled"));

    let bundled = probe(None, &[], &[], Some("0.2.1-rc.5"), &[]);
    assert_eq!(bundled.source, RuntimeSource::Bundled);
    assert_eq!(bundled.version.as_deref(), Some("0.2.1-rc.5"));
    assert_eq!(bundled.launch_arg(), Some("bundled"));
}

#[test]
fn probe_falls_through_unusable_candidates_and_reports_missing() {
    let path_probe = probe(
        Some("/broken/dsh"),
        &["/desktop/dsh"],
        &["/path/dsh"],
        None,
        &[("/path/dsh", "0.1.9")],
    );
    assert_eq!(path_probe.source, RuntimeSource::Path);

    let missing = self::probe(Some("/broken/dsh"), &[], &[], None, &[]);
    assert_eq!(missing.source, RuntimeSource::Missing);
    assert!(!missing.found);
    assert!(!missing.external_found());
    assert_eq!(missing.launch_arg(), Some("bundled"));
}

#[test]
fn desktop_wrapper_and_missing_both_launch_bundled() {
    let desktop = probe(
        None,
        &["/desktop/dsh"],
        &[],
        Some("0.2.1-rc.5"),
        &[("/desktop/dsh", "0.2.2")],
    );
    assert_eq!(desktop.source, RuntimeSource::DshDesktop);
    assert_eq!(desktop.launch_arg(), Some("bundled"));

    let missing = self::probe(None, &[], &[], None, &[]);
    assert_eq!(missing.source, RuntimeSource::Missing);
    assert_eq!(missing.launch_arg(), Some("bundled"));
}

#[test]
fn explicit_bundled_literal_selects_bundled() {
    let probe = probe(Some("bundled"), &[], &[], Some("0.2.1-rc.5"), &[]);
    assert_eq!(probe.source, RuntimeSource::Bundled);
    assert_eq!(probe.launch_arg(), Some("bundled"));
}

#[test]
fn version_matrix_warns_above_tested_but_does_not_block() {
    assert_eq!(dsh_version_status("0.1.6"), DshVersionStatus::BelowMinimum);
    assert_eq!(
        dsh_version_status("0.1.7-rc.2"),
        DshVersionStatus::Supported
    );
    assert_eq!(
        dsh_version_status("0.2.1-rc.5"),
        DshVersionStatus::Supported
    );
    assert_eq!(
        dsh_version_status("0.2.2-rc.1"),
        DshVersionStatus::AboveTested
    );
    assert_eq!(
        dsh_version_status("not-a-version"),
        DshVersionStatus::Unknown
    );
}

#[cfg(unix)]
#[test]
fn dsh_home_is_created_with_owner_only_permissions() {
    use std::os::unix::fs::PermissionsExt;
    let dir = std::env::temp_dir().join(format!(
        "cgc-dsh-home-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    ensure_dsh_home(&dir).expect("create dsh home");
    let mode = std::fs::metadata(&dir)
        .expect("metadata")
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(mode, 0o700);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn bundled_version_is_read_from_installed_adapter_vendor_metadata() {
    use crate::registry::manifest::Registry;
    let dir = std::env::temp_dir().join(format!(
        "cgc-dsh-bundled-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let node_root = dir.join("node24");
    let vendor =
        dir.join("agents/deepseek/0.4.41/node_modules/@openma/deepseek-harness-acp/vendor");
    std::fs::create_dir_all(&vendor).expect("vendor dir");
    std::fs::write(
        vendor.join("runtime.json"),
        r#"{"archive":"dsh-runtime.tgz","dsh":"0.2.1-rc.5","sha256":"x"}"#,
    )
    .expect("runtime metadata");
    let entry = Registry::builtin()
        .expect("registry")
        .get("deepseek")
        .expect("dsh entry")
        .clone();
    let probe = bundled_probe(&entry, Some(&NodeRuntime::new(&node_root)));
    assert_eq!(probe.source, RuntimeSource::Bundled);
    assert_eq!(probe.version.as_deref(), Some("0.2.1-rc.5"));
    assert_eq!(probe.launch_arg(), Some("bundled"));
    let _ = std::fs::remove_dir_all(&dir);
}
