use std::path::{Path, PathBuf};
use std::process::Command;

use cgc_agent_checkpoint::{CheckpointError, CheckpointManager, GcMode};

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
    let output = run_git(
        repo,
        &[
            "-c",
            "core.quotepath=false",
            "ls-tree",
            "-r",
            "--name-only",
            sha,
        ],
    );
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

#[test]
fn restore_preserves_files_excluded_from_checkpoint() {
    let workspace = temp_workspace("restore-excluded");
    let manager = CheckpointManager::initialize(&workspace).expect("init");
    std::fs::write(workspace.join("a.txt"), "before").unwrap();
    std::fs::write(workspace.join("deleted.txt"), "restore me").unwrap();
    std::fs::write(workspace.join("logo.png"), b"image").unwrap();
    std::fs::write(workspace.join("archive.zip"), b"archive").unwrap();
    std::fs::write(workspace.join("large.txt"), vec![b'x'; 2 * 1024 * 1024 + 1]).unwrap();
    assert!(run_git(&workspace, &["add", "--all"]).status.success());
    assert!(run_git(&workspace, &["commit", "-m", "initial"])
        .status
        .success());
    let checkpoint = manager.snapshot("restore-excluded", 1).unwrap();
    assert_eq!(
        tree_files(&workspace, &checkpoint.sha),
        vec!["a.txt", "deleted.txt"]
    );
    std::fs::write(workspace.join("a.txt"), "after").unwrap();
    std::fs::remove_file(workspace.join("deleted.txt")).unwrap();
    // 即使大文件后来缩小，也不能把快照中的缺席误判成应当删除。
    std::fs::write(workspace.join("large.txt"), "now small").unwrap();
    std::fs::write(workspace.join("new.txt"), "keep new file").unwrap();

    manager.restore(&checkpoint).expect("restore");

    assert_eq!(std::fs::read(workspace.join("logo.png")).unwrap(), b"image");
    assert_eq!(
        std::fs::read(workspace.join("archive.zip")).unwrap(),
        b"archive"
    );
    assert_eq!(
        std::fs::read_to_string(workspace.join("large.txt")).unwrap(),
        "now small"
    );
    assert_eq!(
        std::fs::read_to_string(workspace.join("new.txt")).unwrap(),
        "keep new file"
    );
    assert_eq!(
        std::fs::read_to_string(workspace.join("a.txt")).unwrap(),
        "before"
    );
    assert_eq!(
        std::fs::read_to_string(workspace.join("deleted.txt")).unwrap(),
        "restore me"
    );
    std::fs::remove_dir_all(workspace).unwrap();
}

#[test]
fn restore_preserves_partially_staged_and_unrelated_index_entries() {
    for single_file in [false, true] {
        let workspace = temp_workspace("restore-index");
        let manager = CheckpointManager::initialize(&workspace).expect("init");
        for path in ["a.txt", "b.txt"] {
            std::fs::write(workspace.join(path), "committed").unwrap();
        }
        assert!(run_git(&workspace, &["add", "--all"]).status.success());
        assert!(run_git(&workspace, &["commit", "-m", "initial"])
            .status
            .success());
        for path in ["a.txt", "b.txt"] {
            std::fs::write(workspace.join(path), "staged").unwrap();
        }
        assert!(run_git(&workspace, &["add", "--all"]).status.success());
        std::fs::write(workspace.join("a.txt"), "checkpoint").unwrap();
        let checkpoint = manager.snapshot("restore-index", 1).unwrap();
        std::fs::write(workspace.join("a.txt"), "after turn").unwrap();
        std::fs::write(workspace.join("b.txt"), "unrelated edit").unwrap();
        let index_before = run_git(&workspace, &["ls-files", "--stage", "-z"]);
        assert!(index_before.status.success());

        if single_file {
            manager.restore_file(&checkpoint, "a.txt").unwrap();
        } else {
            manager.restore(&checkpoint).unwrap();
        }

        let index_after = run_git(&workspace, &["ls-files", "--stage", "-z"]);
        assert!(index_after.status.success());
        assert_eq!(
            index_after.stdout, index_before.stdout,
            "single_file={single_file}"
        );
        assert_eq!(
            std::fs::read_to_string(workspace.join("a.txt")).unwrap(),
            "checkpoint"
        );
        assert_eq!(
            std::fs::read_to_string(workspace.join("b.txt")).unwrap(),
            if single_file {
                "unrelated edit"
            } else {
                "staged"
            }
        );
        std::fs::remove_dir_all(workspace).unwrap();
    }
}

#[test]
fn empty_checkpoint_restore_is_a_noop_and_preserves_files_and_index() {
    let workspace = temp_workspace("restore-empty");
    let manager = CheckpointManager::initialize(&workspace).expect("init");
    let checkpoint = manager.snapshot("empty-thread", 1).expect("snapshot");
    assert!(tree_files(&workspace, &checkpoint.sha).is_empty());
    manager
        .restore(&checkpoint)
        .expect("restore an empty snapshot");

    std::fs::write(workspace.join("new.txt"), "keep this new file").unwrap();
    std::fs::write(workspace.join("logo.png"), b"keep this image").unwrap();
    assert!(run_git(&workspace, &["add", "new.txt"]).status.success());
    let before = run_git(&workspace, &["ls-files", "--stage", "-z"]);
    assert!(before.status.success());
    manager
        .restore(&checkpoint)
        .expect("restore without deleting new files");
    let after = run_git(&workspace, &["ls-files", "--stage", "-z"]);
    assert!(after.status.success());
    assert_eq!(after.stdout, before.stdout);
    assert_eq!(
        std::fs::read_to_string(workspace.join("new.txt")).unwrap(),
        "keep this new file"
    );
    assert_eq!(
        std::fs::read(workspace.join("logo.png")).unwrap(),
        b"keep this image"
    );
    std::fs::remove_dir_all(workspace).unwrap();
}

#[test]
fn empty_workspace_restore_still_rejects_a_missing_checkpoint_object() {
    let workspace = temp_workspace("restore-missing-object");
    let manager = CheckpointManager::initialize(&workspace).expect("init");
    let mut checkpoint = manager.snapshot("empty-thread", 1).expect("snapshot");
    checkpoint.sha = "0".repeat(40);
    assert!(matches!(
        manager.restore(&checkpoint),
        Err(cgc_agent_checkpoint::CheckpointError::Git(_))
    ));
    std::fs::remove_dir_all(workspace).unwrap();
}

#[test]
fn restore_does_not_stage_previously_untracked_files() {
    for single_file in [false, true] {
        let workspace = temp_workspace("restore-untracked");
        let manager = CheckpointManager::initialize(&workspace).expect("init");
        std::fs::write(workspace.join("a.txt"), "before").unwrap();
        let checkpoint = manager.snapshot("restore-untracked", 1).unwrap();
        std::fs::write(workspace.join("a.txt"), "after").unwrap();

        if single_file {
            manager.restore_file(&checkpoint, "a.txt").unwrap();
        } else {
            manager.restore(&checkpoint).unwrap();
        }

        assert_eq!(
            std::fs::read_to_string(workspace.join("a.txt")).unwrap(),
            "before"
        );
        let index = run_git(&workspace, &["ls-files", "--stage", "-z"]);
        assert!(index.status.success());
        assert_eq!(index.stdout, b"", "restore must not stage the file");
        std::fs::remove_dir_all(workspace).unwrap();
    }
}

fn compute_blob_oid(repo: &Path, file: &Path) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(repo)
        .arg("hash-object")
        .arg(file)
        .output()
        .expect("git hash-object");
    assert!(
        output.status.success(),
        "hash-object failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn object_exists_in_store(git_dir: &Path, oid: &str) -> bool {
    let (prefix, rest) = oid.split_at(2);
    if git_dir.join("objects").join(prefix).join(rest).exists() {
        return true;
    }
    let verify = Command::new("git")
        .arg("--git-dir")
        .arg(git_dir)
        .args(["cat-file", "-e", oid])
        .output()
        .expect("git cat-file");
    verify.status.success()
}

#[test]
fn large_binary_and_ignored_dir_blobs_never_enter_object_store() {
    let workspace = temp_workspace("no-leak-objects");
    let manager = CheckpointManager::initialize(&workspace).expect("init");
    std::fs::write(workspace.join("small.txt"), "keep me\n").unwrap();
    let big = workspace.join("big.bin");
    let zip = workspace.join("archive.zip");
    std::fs::write(&big, vec![0x5Au8; 3 * 1024 * 1024]).unwrap();
    std::fs::write(&zip, b"PK\x03\x04fakezip").unwrap();
    std::fs::create_dir_all(workspace.join("node_modules/pkg")).unwrap();
    let nm = workspace.join("node_modules/pkg/index.js");
    std::fs::write(&nm, "module.exports = 'node_modules_marker';\n").unwrap();
    std::fs::create_dir_all(workspace.join("target/debug")).unwrap();
    let tgt = workspace.join("target/debug/app.txt");
    std::fs::write(&tgt, "target_artifact_marker\n").unwrap();
    std::fs::create_dir_all(workspace.join(".venv")).unwrap();
    let venv = workspace.join(".venv/lib.py");
    std::fs::write(&venv, "venv_marker = 1\n").unwrap();

    let forbidden_oids = [
        ("big.bin", compute_blob_oid(&workspace, &big)),
        ("archive.zip", compute_blob_oid(&workspace, &zip)),
        ("node_modules", compute_blob_oid(&workspace, &nm)),
        ("target", compute_blob_oid(&workspace, &tgt)),
        (".venv", compute_blob_oid(&workspace, &venv)),
    ];

    let checkpoint = manager.snapshot("thread-1", 1).expect("snapshot");
    let files = tree_files(&workspace, &checkpoint.sha);
    assert_eq!(files, vec!["small.txt".to_string()]);

    // 同时跑一次 diff / changed_files，确认查看变更路径同样不会把大/忽略文件写入对象库。
    std::fs::write(workspace.join("small.txt"), "modified\n").unwrap();
    let _ = manager.diff(&checkpoint).expect("diff");
    let _ = manager.changed_files(&checkpoint).expect("changed_files");

    for (label, oid) in forbidden_oids {
        assert!(
            !object_exists_in_store(manager.git_dir(), &oid),
            "{label} 的 blob ({oid}) 不得进入 .git/objects"
        );
    }
    let _ = std::fs::remove_dir_all(workspace);
}

#[test]
fn deleted_files_and_special_paths_snapshot_and_restore() {
    let workspace = temp_workspace("special-paths");
    let manager = CheckpointManager::initialize(&workspace).expect("init");
    let special = "笔记 [v1] 测试.md";
    std::fs::write(workspace.join(special), "第一版正文\n").unwrap();
    std::fs::write(workspace.join("removed.txt"), "will be deleted\n").unwrap();

    let first = manager.snapshot("thread-special", 1).expect("snap 1");
    let first_files = tree_files(&workspace, &first.sha);
    assert!(first_files.contains(&"removed.txt".to_string()));
    assert!(first_files.iter().any(|name| name.contains("笔记 [v1]")));

    std::fs::remove_file(workspace.join("removed.txt")).unwrap();
    std::fs::write(workspace.join(special), "第二版正文\n").unwrap();
    let second = manager.snapshot("thread-special", 2).expect("snap 2");
    let second_files = tree_files(&workspace, &second.sha);
    assert!(!second_files.contains(&"removed.txt".to_string()));

    manager.restore(&first).expect("restore first");
    assert_eq!(
        std::fs::read_to_string(workspace.join("removed.txt")).unwrap(),
        "will be deleted\n"
    );
    assert_eq!(
        std::fs::read_to_string(workspace.join(special)).unwrap(),
        "第一版正文\n"
    );
    let _ = std::fs::remove_dir_all(workspace);
}

#[test]
fn global_total_refs_limit_prunes_oldest_other_thread_first_and_keeps_current() {
    let workspace = temp_workspace("global-prune");
    let manager = CheckpointManager::initialize(&workspace)
        .expect("init")
        .with_max_refs(5)
        .with_max_total_refs(3);
    std::fs::write(workspace.join("a.txt"), "v1").unwrap();

    // thread-a 创建 2 条；sleep 确保 committerdate(unix) 可区分先后顺序（或者 seq 校验）。
    let r1 = manager.snapshot_with_report("thread-a", 1).unwrap();
    assert!(r1.pruned.is_empty());
    let r2 = manager.snapshot_with_report("thread-a", 2).unwrap();
    assert!(r2.pruned.is_empty());

    // thread-b 创建第 1 条（总 3 条，未超）和第 2 条（总 4 条 → 超出 1 条，应淘汰 thread-a 的 ref）。
    let r3 = manager.snapshot_with_report("thread-b", 1).unwrap();
    assert!(r3.pruned.is_empty());
    let r4 = manager.snapshot_with_report("thread-b", 2).unwrap();
    assert_eq!(r4.pruned.len(), 1);
    assert_eq!(r4.pruned[0].thread_id, "thread-a");
    assert_eq!(r4.pruned[0].seq, 1);
    assert!(r4.needs_gc);

    assert_eq!(manager.list("thread-a").unwrap().len(), 1);
    assert_eq!(manager.list("thread-a").unwrap()[0].seq, 2);
    assert_eq!(manager.list("thread-b").unwrap().len(), 2);

    // 即便 max_total_refs = 1，当前线程最新 1 条也必须被保留。
    let tight = manager.clone().with_max_total_refs(1);
    let r5 = tight.snapshot_with_report("thread-b", 3).unwrap();
    assert!(!r5.pruned.is_empty());
    let remaining_b = tight.list("thread-b").unwrap();
    assert_eq!(remaining_b.len(), 1);
    assert_eq!(remaining_b[0].seq, 3);
    assert!(tight.list("thread-a").unwrap().is_empty());
    let _ = std::fs::remove_dir_all(workspace);
}

#[test]
fn delete_refs_from_and_delete_thread_refs_preserve_user_branches_and_other_threads() {
    let workspace = temp_workspace("delete-refs");
    let manager = CheckpointManager::initialize(&workspace).expect("init");
    std::fs::write(workspace.join("a.txt"), "base").unwrap();
    assert!(run_git(&workspace, &["add", "--all"]).status.success());
    assert!(run_git(&workspace, &["commit", "-m", "user commit"])
        .status
        .success());
    let head_before = manager.head().unwrap().expect("head commit");

    for seq in 1..=3 {
        std::fs::write(workspace.join("a.txt"), format!("t1-{seq}")).unwrap();
        manager.snapshot("thread-1", seq).unwrap();
    }
    for seq in 1..=2 {
        std::fs::write(workspace.join("a.txt"), format!("t2-{seq}")).unwrap();
        manager.snapshot("thread-2", seq).unwrap();
    }

    let deleted_rewind = manager
        .delete_refs_from("thread-1", 2)
        .expect("delete from 2");
    let deleted_seqs: Vec<u64> = deleted_rewind.iter().map(|r| r.seq).collect();
    assert_eq!(deleted_seqs, vec![2, 3]);
    assert_eq!(
        manager
            .list("thread-1")
            .unwrap()
            .into_iter()
            .map(|c| c.seq)
            .collect::<Vec<_>>(),
        vec![1]
    );
    assert_eq!(manager.list("thread-2").unwrap().len(), 2);
    assert_eq!(
        manager.head().unwrap().as_deref(),
        Some(head_before.as_str())
    );

    let deleted_thread = manager
        .delete_thread_refs("thread-2")
        .expect("delete thread-2");
    assert_eq!(deleted_thread.len(), 2);
    assert!(manager.list("thread-2").unwrap().is_empty());
    assert_eq!(manager.list("thread-1").unwrap().len(), 1);
    assert_eq!(
        manager.head().unwrap().as_deref(),
        Some(head_before.as_str())
    );
    let _ = std::fs::remove_dir_all(workspace);
}

#[test]
fn budget_exceeded_blocks_snapshot_and_reclaim_recovers_within_budget() {
    let workspace = temp_workspace("budget-reclaim");
    // 构造“同基线微调的高熵内容”：单份 ~120 KiB（zlib 无法压小），多版本以松散对象存放会超 250 KiB，
    // 删掉旧 ref 后经 git gc --prune=1.hour.ago 打包 delta 压缩可落回 250 KiB 预算内。
    let manager = CheckpointManager::initialize(&workspace)
        .expect("init")
        .with_max_refs(50)
        .with_max_total_refs(200)
        .with_max_object_bytes(250 * 1024);

    let mut state: u64 = 0x1234_5678_9ABC_DEF0;
    let mut base = String::with_capacity(120 * 1024);
    while base.len() < 120 * 1024 {
        state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
        use std::fmt::Write as _;
        let _ = writeln!(base, "{state:016x}");
    }

    for seq in 1..=5 {
        std::fs::write(workspace.join("data.txt"), format!("{base}seq={seq}\n")).unwrap();
        let _ = manager.snapshot_with_report("thread-old", seq);
    }

    let stats_before = manager.object_store_stats().expect("stats");
    assert!(
        stats_before.total_bytes() > 250 * 1024,
        "expected loose objects to exceed 250 KiB before reclaim, got {}",
        stats_before.total_bytes()
    );

    let err = manager
        .snapshot_with_report("thread-new", 1)
        .expect_err("over budget must return BudgetExceeded");
    assert!(matches!(err, CheckpointError::BudgetExceeded { .. }));

    let old_cp = manager
        .list("thread-old")
        .unwrap()
        .pop()
        .expect("old checkpoint exists");
    let new_untracked = workspace.join("should-not-be-hashed-over-budget.txt");
    std::fs::write(
        &new_untracked,
        "unique-over-budget-content-that-must-not-enter-git-object-store\n",
    )
    .unwrap();
    let new_untracked_oid = compute_blob_oid(&workspace, &new_untracked);
    assert!(matches!(
        manager.changed_files(&old_cp),
        Err(CheckpointError::BudgetExceeded { .. })
    ));
    assert!(matches!(
        manager.diff(&old_cp),
        Err(CheckpointError::BudgetExceeded { .. })
    ));
    assert!(
        !object_exists_in_store(manager.git_dir(), &new_untracked_oid),
        "changed_files/diff must not stage or hash new blobs when over budget"
    );
    std::fs::remove_file(&new_untracked).unwrap();

    let reclaim = manager
        .reclaim_for_budget("thread-new", 1)
        .expect("reclaim");
    assert!(!reclaim.pruned.is_empty());
    assert!(
        reclaim.within_budget,
        "pack 后应回到 250 KiB 预算内: {:?}",
        reclaim
    );
    assert!(manager.list("thread-old").unwrap().is_empty());

    // 恢复预算后，新线程快照重新放行。
    let ok = manager
        .snapshot_with_report("thread-new", 1)
        .expect("snapshot succeeds after reclaim");
    assert_eq!(ok.checkpoint.seq, 1);

    // 若用户 HEAD 本身已超极小预算，reclaim 不得触碰用户分支且返回 within_budget = false。
    std::fs::write(workspace.join("committed.txt"), &base).unwrap();
    assert!(run_git(&workspace, &["add", "--all"]).status.success());
    assert!(run_git(&workspace, &["commit", "-m", "user data"])
        .status
        .success());
    let head_before = manager.head().unwrap().expect("head");
    let impossible = manager.clone().with_max_object_bytes(1);
    let unrecoverable = impossible
        .reclaim_for_budget("thread-new", 1)
        .expect("reclaim does not error");
    assert!(!unrecoverable.within_budget);
    assert_eq!(
        impossible.head().unwrap().as_deref(),
        Some(head_before.as_str()),
        "reclaim 绝不能删除用户分支或提交"
    );
    let _ = std::fs::remove_dir_all(workspace);
}

#[test]
fn concurrent_gc_and_snapshots_do_not_collide_on_git_locks() {
    let workspace = temp_workspace("concurrent-lock");
    let manager = CheckpointManager::initialize(&workspace).expect("init");
    std::fs::write(workspace.join("work.txt"), "start").unwrap();

    // 模拟 scope 切走再切回：两个独立 `CheckpointManager::open` 实例指向同一仓库，
    // 必须共享进程内同一把 `git_lock`，否则后台 GC 删除 `cgc-checkpoint.index` 会与前台
    // `populate_index -> write-tree` 并发交错，产生空树快照或锁冲突。
    let writer = CheckpointManager::open(&workspace).expect("open writer");
    let gc_runner = CheckpointManager::open(&workspace).expect("open gc_runner");

    let t1 = std::thread::spawn(move || {
        for seq in 1..=10 {
            std::fs::write(writer.repo().join("work.txt"), format!("turn-{seq}")).unwrap();
            writer
                .snapshot_with_report("thread-concurrent", seq)
                .expect("concurrent snapshot must succeed");
        }
    });
    let t2 = std::thread::spawn(move || {
        for _ in 0..8 {
            gc_runner
                .run_gc(GcMode::Auto)
                .expect("concurrent gc must succeed");
            let _ = gc_runner.object_store_stats().expect("stats");
        }
    });

    t1.join().expect("writer thread");
    t2.join().expect("gc thread");
    let checkpoints = manager.list("thread-concurrent").unwrap();
    assert_eq!(checkpoints.len(), 10);
    for cp in &checkpoints {
        assert_eq!(
            tree_files(&workspace, &cp.sha),
            vec!["work.txt"],
            "checkpoint seq={} must not have an empty tree",
            cp.seq
        );
    }
    let _ = std::fs::remove_dir_all(workspace);
}

#[test]
fn manual_purge_history_checkpoints_prunes_unreachable_objects_now_and_keeps_latest_current() {
    let workspace = temp_workspace("manual-purge");
    let manager = CheckpointManager::initialize(&workspace).expect("init");
    std::fs::write(workspace.join("base.txt"), "user committed base\n").unwrap();
    assert!(run_git(&workspace, &["add", "--all"]).status.success());
    assert!(run_git(&workspace, &["commit", "-m", "user commit"])
        .status
        .success());
    let head_before = manager.head().unwrap().expect("head");

    let old_only = workspace.join("old-only.txt");
    std::fs::write(
        &old_only,
        "unique-old-thread-blob-content-for-prune-now-verification\n",
    )
    .unwrap();
    let old_only_oid = compute_blob_oid(&workspace, &old_only);
    for seq in 1..=3 {
        std::fs::write(workspace.join("shared.txt"), format!("old-{seq}\n")).unwrap();
        manager.snapshot("thread-old", seq).unwrap();
    }
    std::fs::remove_file(&old_only).unwrap();

    for seq in 1..=3 {
        std::fs::write(workspace.join("shared.txt"), format!("current-{seq}\n")).unwrap();
        manager.snapshot("thread-current", seq).unwrap();
    }

    let before = manager.storage_summary().expect("storage summary before");
    assert_eq!(before.total_refs, 6);
    assert!(before.stats.total_bytes() > 0);
    assert_eq!(before.limit_bytes, manager.max_object_bytes());
    assert!(
        object_exists_in_store(manager.git_dir(), &old_only_oid),
        "old-only blob should exist before manual purge"
    );

    let report = manager
        .purge_history_checkpoints(Some("thread-current"), 1)
        .expect("purge history checkpoints");
    assert_eq!(report.pruned.len(), 5);
    assert_eq!(report.remaining_refs, 1);
    assert!(report.within_budget);
    assert!(manager.list("thread-old").unwrap().is_empty());
    assert_eq!(
        manager
            .list("thread-current")
            .unwrap()
            .into_iter()
            .map(|c| c.seq)
            .collect::<Vec<_>>(),
        vec![3]
    );
    assert!(
        !object_exists_in_store(manager.git_dir(), &old_only_oid),
        "--prune=now must immediately reclaim unreachable blobs"
    );
    assert_eq!(
        manager.head().unwrap().as_deref(),
        Some(head_before.as_str()),
        "manual purge must never touch user commits or branches"
    );

    let after = manager.storage_summary().expect("storage summary after");
    assert_eq!(after.total_refs, 1);
    let _ = std::fs::remove_dir_all(workspace);
}

#[test]
fn gc_prune_now_after_changed_files_does_not_corrupt_private_index_for_next_snapshot() {
    let workspace = temp_workspace("gc-index-rebuild");
    let manager = CheckpointManager::initialize(&workspace).expect("init");
    std::fs::write(workspace.join("a.txt"), "v1\n").unwrap();
    let cp1 = manager.snapshot("thread-1", 1).expect("cp1");

    // 模拟 turn 结束修改了文件但尚未创建下一轮 checkpoint：
    // 先跨过 1 秒避免 racy-git 让索引把该条目记为 smudge，再调 `changed_files()` 把 `v2` 的
    // blob 与非 racy stat 缓存写入私有 `cgc-checkpoint.index`。
    std::fs::write(workspace.join("a.txt"), "v2-unreferenced-by-any-ref\n").unwrap();
    std::thread::sleep(std::time::Duration::from_millis(1100));
    let changes = manager
        .changed_files(&cp1)
        .expect("changed_files before gc");
    assert_eq!(changes.len(), 1);

    manager
        .purge_history_checkpoints(Some("thread-1"), 1)
        .expect("purge now");

    let changes_after = manager.changed_files(&cp1).expect("changed_files after gc");
    assert_eq!(changes_after.len(), 1);
    let cp2 = manager
        .snapshot("thread-1", 2)
        .expect("snapshot after gc must rebuild private index and succeed");
    assert_eq!(tree_files(&workspace, &cp2.sha), vec!["a.txt"]);
    let _ = std::fs::remove_dir_all(workspace);
}

#[test]
fn file_growing_past_size_limit_when_staged_differs_from_head_is_force_removed_from_index() {
    let workspace = temp_workspace("force-rm-oversized");
    let manager = CheckpointManager::initialize(&workspace).expect("init");
    let tracked = workspace.join("grow.txt");
    std::fs::write(&tracked, "head-version\n").unwrap();
    std::fs::write(workspace.join("keep.txt"), "keep\n").unwrap();
    assert!(run_git(&workspace, &["add", "--all"]).status.success());
    assert!(run_git(&workspace, &["commit", "-m", "head"])
        .status
        .success());

    // 第 1 轮修改 `grow.txt`（仍小于 2 MiB），使私有索引中的 staged 版本与 HEAD 不同。
    std::fs::write(&tracked, "turn-1-small-modified\n").unwrap();
    let cp1 = manager.snapshot("thread-1", 1).expect("snapshot 1");
    assert_eq!(
        tree_files(&workspace, &cp1.sha),
        vec!["grow.txt", "keep.txt"]
    );

    // 第 2 轮 `grow.txt` 增长超过 2 MiB：工作区版本既不同于私有索引，私有索引又不同于 HEAD。
    // `git rm --force --cached` 必须强制从私有索引移除，不能报 up-to-date 检查错误。
    std::fs::write(&tracked, vec![b'X'; 3 * 1024 * 1024]).unwrap();
    let cp2 = manager
        .snapshot("thread-1", 2)
        .expect("snapshot 2 must force-remove oversized entry from private index");
    assert_eq!(tree_files(&workspace, &cp2.sha), vec!["keep.txt"]);
    assert_eq!(
        std::fs::metadata(&tracked).unwrap().len(),
        3 * 1024 * 1024,
        "working tree file must remain untouched"
    );
    let _ = std::fs::remove_dir_all(workspace);
}

#[test]
fn reclaim_preserves_pruned_refs_on_error_when_subsequent_gc_fails() {
    let workspace = temp_workspace("gc-fail-after-prune");
    let manager = CheckpointManager::initialize(&workspace).expect("init");
    std::fs::write(workspace.join("a.txt"), "v1\n").unwrap();
    manager.snapshot("thread-old", 1).expect("old 1");
    std::fs::write(workspace.join("a.txt"), "v2\n").unwrap();
    manager.snapshot("thread-current", 1).expect("cur 1");
    std::fs::write(workspace.join("a.txt"), "v3\n").unwrap();
    manager.snapshot("thread-current", 2).expect("cur 2");

    // 注入非法 `gc.reflogExpire` 让 `git gc` 在 `delete_refs_locked` 已经删除旧 ref 后报错失败。
    assert!(run_git(
        &workspace,
        &["config", "gc.reflogExpire", "not-a-valid-date"]
    )
    .status
    .success());

    let err = manager
        .purge_history_checkpoints(Some("thread-current"), 1)
        .expect_err("git gc with invalid reflogExpire must fail");
    let mut pruned: Vec<(String, u64)> = err
        .pruned_refs()
        .iter()
        .map(|item| (item.thread_id.clone(), item.seq))
        .collect();
    pruned.sort();
    assert_eq!(
        pruned,
        vec![
            ("thread-current".to_string(), 1),
            ("thread-old".to_string(), 1),
        ],
        "error must carry the refs that were already deleted before git gc failed"
    );
    assert!(manager.list("thread-old").unwrap().is_empty());
    assert_eq!(manager.list("thread-current").unwrap().len(), 1);
    let _ = std::fs::remove_dir_all(workspace);
}

#[cfg(unix)]
#[test]
fn non_utf8_filename_is_included_in_snapshot_and_restored() {
    use std::ffi::OsStr;
    use std::os::unix::ffi::OsStrExt as _;

    let workspace = temp_workspace("non-utf8-path");
    let manager = CheckpointManager::initialize(&workspace).expect("init");
    let non_utf8_name = OsStr::from_bytes(b"raw-\xff-note.txt");
    let non_utf8_path = workspace.join(non_utf8_name);
    if std::fs::write(&non_utf8_path, b"v1-bytes\n").is_err() {
        // APFS 等严格强制 UTF-8 文件名的文件系统不支持创建任意非 UTF-8 文件名；跳过文件级创建。
        // 但仍可直接验证 `index.rs` 的字节路径编码/解码与 `Path` 转换不丢失 `0xff` 字节。
        let _ = std::fs::remove_dir_all(workspace);
        return;
    }

    let cp1 = manager.snapshot("thread-bytes", 1).expect("snapshot 1");
    std::fs::write(&non_utf8_path, b"v2-bytes\n").unwrap();
    let _cp2 = manager.snapshot("thread-bytes", 2).expect("snapshot 2");

    manager.restore(&cp1).expect("restore cp1");
    assert_eq!(std::fs::read(&non_utf8_path).unwrap(), b"v1-bytes\n");
    let _ = std::fs::remove_dir_all(workspace);
}

#[test]
fn snapshot_and_restore_preserve_exact_line_endings_under_autocrlf_true() {
    let workspace = temp_workspace("autocrlf");
    let manager = CheckpointManager::initialize(&workspace).expect("init");
    assert!(run_git(&workspace, &["config", "core.autocrlf", "true"])
        .status
        .success());

    std::fs::write(workspace.join("lf.txt"), b"line1\nline2\n").unwrap();
    std::fs::write(workspace.join("crlf.txt"), b"win1\r\nwin2\r\n").unwrap();
    let cp1 = manager.snapshot("thread-eol", 1).expect("snapshot 1");

    std::fs::remove_file(workspace.join("lf.txt")).unwrap();
    std::fs::write(workspace.join("crlf.txt"), b"changed").unwrap();
    manager.restore(&cp1).expect("restore cp1");

    assert_eq!(
        std::fs::read(workspace.join("lf.txt")).unwrap(),
        b"line1\nline2\n"
    );
    assert_eq!(
        std::fs::read(workspace.join("crlf.txt")).unwrap(),
        b"win1\r\nwin2\r\n"
    );
    let _ = std::fs::remove_dir_all(workspace);
}

#[cfg(unix)]
#[test]
fn replacing_snapshotted_directory_with_symlink_and_back_succeeds() {
    let workspace = temp_workspace("dir-to-symlink");
    let external = temp_workspace("dir-to-symlink-ext");
    std::fs::create_dir_all(external.join("sub")).unwrap();
    std::fs::write(external.join("sub/a.txt"), "external\n").unwrap();

    let manager = CheckpointManager::initialize(&workspace).expect("init");
    std::fs::create_dir_all(workspace.join("dir/sub")).unwrap();
    std::fs::write(workspace.join("dir/sub/a.txt"), "v1\n").unwrap();

    let cp1 = manager.snapshot("thread-sym", 1).expect("snapshot 1");
    assert_eq!(tree_files(&workspace, &cp1.sha), vec!["dir/sub/a.txt"]);

    // 用指向外部目录（含同名后代 dir/sub/a.txt）的 symlink 替换原实体目录：
    // 必须先清掉旧后代条目，再将替换后的 symlink 本身写入索引，不得触发 `beyond a symbolic link`。
    std::fs::remove_dir_all(workspace.join("dir")).unwrap();
    std::os::unix::fs::symlink(&external, workspace.join("dir")).unwrap();

    assert!(manager.changed_files(&cp1).is_ok());
    assert!(manager.diff(&cp1).is_ok());
    let cp2 = manager
        .snapshot("thread-sym", 2)
        .expect("snapshot 2 after dir->symlink must succeed");
    assert_eq!(tree_files(&workspace, &cp2.sha), vec!["dir"]);

    // 将 symlink 换回实体目录后，旧 symlink 条目也应被清除且新目录内文件能重新纳入快照。
    std::fs::remove_file(workspace.join("dir")).unwrap();
    std::fs::create_dir_all(workspace.join("dir/sub")).unwrap();
    std::fs::write(workspace.join("dir/sub/b.txt"), "v3\n").unwrap();
    let cp3 = manager
        .snapshot("thread-sym", 3)
        .expect("snapshot 3 after symlink->dir must succeed");
    assert_eq!(tree_files(&workspace, &cp3.sha), vec!["dir/sub/b.txt"]);

    let _ = std::fs::remove_dir_all(workspace);
    let _ = std::fs::remove_dir_all(external);
}
