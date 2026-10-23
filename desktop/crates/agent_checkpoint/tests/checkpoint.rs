use std::path::{Path, PathBuf};
use std::process::Command;

use cgc_agent_checkpoint::CheckpointManager;

fn temp_workspace(tag: &str) -> PathBuf {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let serial = COUNTER.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!(
        "cgc-checkpoint-{}-{tag}-{serial}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("workspace");
    dir
}

fn run_git(repo: &Path, args: &[&str]) -> std::process::Output {
    Command::new("git")
        .arg("-C")
        .arg(repo)
        .env("GIT_AUTHOR_NAME", "Test")
        .env("GIT_AUTHOR_EMAIL", "test@example.com")
        .env("GIT_COMMITTER_NAME", "Test")
        .env("GIT_COMMITTER_EMAIL", "test@example.com")
        .args(args)
        .output()
        .expect("git")
}

fn tree_files(repo: &Path, sha: &str) -> Vec<String> {
    let output = run_git(repo, &["ls-tree", "-r", "--name-only", sha]);
    assert!(
        output.status.success(),
        "ls-tree: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(str::to_string)
        .collect()
}

#[test]
fn open_requires_a_repository() {
    let workspace = temp_workspace("not-repo");
    let error = CheckpointManager::open(&workspace).unwrap_err();
    assert!(matches!(
        error,
        cgc_agent_checkpoint::CheckpointError::NotRepo(_)
    ));
}

#[test]
fn snapshots_are_listed_under_hidden_refs() {
    let workspace = temp_workspace("snapshot");
    let manager = CheckpointManager::initialize(&workspace).expect("init");
    std::fs::write(workspace.join("a.txt"), "one").expect("write");
    let checkpoint = manager.snapshot("thread-1", 1).expect("snapshot");
    assert!(checkpoint.sha.len() >= 7);
    assert_eq!(checkpoint.ref_name, "refs/cgc/checkpoints/thread-1/1");
    let listed = manager.list("thread-1").expect("list");
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].sha, checkpoint.sha);
    let files = tree_files(&workspace, &checkpoint.sha);
    assert!(files.contains(&"a.txt".to_string()));
}

#[test]
fn diff_shows_worktree_changes_and_restore_reverts_them() {
    let workspace = temp_workspace("restore");
    let manager = CheckpointManager::initialize(&workspace).expect("init");
    std::fs::write(workspace.join("a.txt"), "one").expect("write");
    let first = manager.snapshot("thread-1", 1).expect("snapshot 1");
    std::fs::write(workspace.join("a.txt"), "two").expect("write");
    let diff = manager.diff(&first).expect("diff");
    assert!(diff.contains("-one"), "diff: {diff}");
    assert!(diff.contains("+two"), "diff: {diff}");
    manager.restore(&first).expect("restore");
    assert_eq!(
        std::fs::read_to_string(workspace.join("a.txt")).unwrap(),
        "one"
    );
}

#[test]
fn large_and_binary_files_are_excluded() {
    let workspace = temp_workspace("exclude");
    let manager = CheckpointManager::initialize(&workspace).expect("init");
    std::fs::write(workspace.join("small.txt"), "ok").expect("small");
    std::fs::write(workspace.join("image.png"), [0u8; 16]).expect("png");
    std::fs::write(workspace.join("big.bin"), vec![0u8; 3 * 1024 * 1024]).expect("big");
    let checkpoint = manager.snapshot("thread-1", 1).expect("snapshot");
    let files = tree_files(&workspace, &checkpoint.sha);
    assert!(files.contains(&"small.txt".to_string()));
    assert!(!files.contains(&"image.png".to_string()));
    assert!(!files.contains(&"big.bin".to_string()));
}

#[test]
fn prune_keeps_only_max_refs() {
    let workspace = temp_workspace("prune");
    let manager = CheckpointManager::initialize(&workspace)
        .expect("init")
        .with_max_refs(3);
    std::fs::write(workspace.join("a.txt"), "x").expect("write");
    for seq in 1..=5 {
        manager.snapshot("thread-1", seq).expect("snapshot");
    }
    let listed = manager.list("thread-1").expect("list");
    let seqs: Vec<u64> = listed.iter().map(|checkpoint| checkpoint.seq).collect();
    assert_eq!(seqs, vec![3, 4, 5]);
}

#[test]
fn head_drift_invalidates_checkpoint_base() {
    let workspace = temp_workspace("drift");
    let manager = CheckpointManager::initialize(&workspace).expect("init");
    std::fs::write(workspace.join("a.txt"), "one").expect("write");
    let checkpoint = manager.snapshot("thread-1", 1).expect("snapshot");
    assert!(manager.is_valid(&checkpoint).expect("valid"));
    assert!(run_git(&workspace, &["add", "-A"]).status.success());
    assert!(run_git(&workspace, &["commit", "-m", "user commit"])
        .status
        .success());
    assert!(!manager.is_valid(&checkpoint).expect("valid after commit"));
}

#[test]
fn changed_files_lists_worktree_differences() {
    let workspace = temp_workspace("changes");
    let manager = CheckpointManager::initialize(&workspace).expect("init");
    std::fs::write(workspace.join("a.txt"), "one").expect("write");
    let checkpoint = manager.snapshot("thread-1", 1).expect("snapshot");
    std::fs::write(workspace.join("a.txt"), "two").expect("modify");
    std::fs::write(workspace.join("b.txt"), "new").expect("add");
    let changes = manager.changed_files(&checkpoint).expect("changes");
    assert!(changes
        .iter()
        .any(|change| change.path == "a.txt" && change.status == "M"));
    assert!(changes
        .iter()
        .any(|change| change.path == "b.txt" && change.status == "A"));
}

#[test]
fn restore_file_reverts_only_that_file() {
    let workspace = temp_workspace("restore-file");
    let manager = CheckpointManager::initialize(&workspace).expect("init");
    std::fs::write(workspace.join("a.txt"), "one").expect("write a");
    std::fs::write(workspace.join("b.txt"), "one").expect("write b");
    let checkpoint = manager.snapshot("thread-1", 1).expect("snapshot");
    std::fs::write(workspace.join("a.txt"), "two").expect("modify a");
    std::fs::write(workspace.join("b.txt"), "two").expect("modify b");
    manager
        .restore_file(&checkpoint, "a.txt")
        .expect("restore a");
    assert_eq!(
        std::fs::read_to_string(workspace.join("a.txt")).unwrap(),
        "one"
    );
    assert_eq!(
        std::fs::read_to_string(workspace.join("b.txt")).unwrap(),
        "two"
    );
}

#[test]
fn restore_file_rejects_path_escape() {
    let workspace = temp_workspace("restore-escape");
    let manager = CheckpointManager::initialize(&workspace).expect("init");
    std::fs::write(workspace.join("a.txt"), "one").expect("write");
    let checkpoint = manager.snapshot("thread-1", 1).expect("snapshot");
    let error = manager
        .restore_file(&checkpoint, "../outside.txt")
        .unwrap_err();
    assert!(matches!(
        error,
        cgc_agent_checkpoint::CheckpointError::InvalidPath(_)
    ));
}
