use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use super::*;
use crate::git_cli::git_command;

static COUNTER: AtomicU64 = AtomicU64::new(0);

fn temp_dir(name: &str) -> PathBuf {
    let serial = COUNTER.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!(
        "cgc-checkpoint-test-{}-{name}-{serial}",
        std::process::id()
    ))
}

fn git(dir: &Path, args: &[&str]) -> std::process::Output {
    git_command()
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .expect("run git")
}

fn git_ok(dir: &Path, args: &[&str]) {
    let output = git(dir, args);
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn init_repo(root: &Path) {
    std::fs::create_dir_all(root).expect("create repo dir");
    git_ok(root, &["init", "--quiet"]);
    // 钉死行尾转换：Windows runner（以及开了 core.autocrlf 的开发机）会在
    // checkout/restore 时把 LF 换成 CRLF，内容断言就变成 "one\r\n" vs "one\n"。
    git_ok(root, &["config", "core.autocrlf", "false"]);
    std::fs::write(root.join("a.txt"), "one\n").expect("write a.txt");
    git_ok(root, &["add", "--all"]);
    git_ok(
        root,
        &[
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.com",
            "commit",
            "--quiet",
            "-m",
            "init",
        ],
    );
}

#[test]
fn snapshot_works_in_regular_repo_even_without_file_changes() {
    let root = temp_dir("regular");
    init_repo(&root);
    let manager = CheckpointManager::open(&root).expect("open repo");

    let first = manager.snapshot("native-test", 1).expect("first snapshot");
    assert_eq!(manager.list("native-test").unwrap().len(), 1);

    // 没有改文件也要有 checkpoint（只是 diff 为空）——对齐 Zed 的每轮快照。
    let second = manager.snapshot("native-test", 2).expect("second snapshot");
    assert_eq!(manager.list("native-test").unwrap().len(), 2);
    assert!(
        manager.changed_files(&second).unwrap().is_empty(),
        "chat-only turn should have an empty diff"
    );

    std::fs::write(root.join("a.txt"), "two\n").expect("modify a.txt");
    let changes = manager.changed_files(&first).unwrap();
    assert_eq!(changes.len(), 1, "one modified file");
    assert_eq!(changes[0].path, "a.txt");
    let _third = manager.snapshot("native-test", 3).expect("third snapshot");

    // 回滚到第一轮：文件内容与 diff 都应恢复。
    manager.restore(&first).expect("restore snapshot");
    assert_eq!(
        std::fs::read_to_string(root.join("a.txt")).unwrap(),
        "one\n"
    );
    assert!(manager.changed_files(&first).unwrap().is_empty());

    // 增量索引应落在真实 git 目录里。
    assert!(manager.git_dir().join("cgc-checkpoint.index").exists());
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn snapshot_works_in_linked_worktree_subdir() {
    let main = temp_dir("main");
    let worktree = temp_dir("worktree");
    init_repo(&main);
    let worktree_s = worktree.display().to_string();
    git_ok(
        &main,
        &[
            "worktree",
            "add",
            "--quiet",
            "-b",
            "cgc-test-wt",
            &worktree_s,
        ],
    );
    let sub = worktree.join("sub");
    std::fs::create_dir_all(&sub).expect("create subdir");

    // 修复前这里会失败：worktree 根的 .git 是文件，subdir 没有 .git 目录。
    let manager = CheckpointManager::open(&sub).expect("open worktree subdir");
    assert!(
        manager.git_dir().is_absolute(),
        "git dir must be resolved absolutely"
    );
    std::fs::write(sub.join("inside.txt"), "hello\n").expect("write inside.txt");
    let checkpoint = manager
        .snapshot("native-wt", 1)
        .expect("snapshot in worktree");
    assert_eq!(manager.list("native-wt").unwrap().len(), 1);
    assert_eq!(checkpoint.seq, 1);
    assert!(manager.git_dir().join("cgc-checkpoint.index").exists());

    std::fs::write(sub.join("inside.txt"), "changed\n").expect("modify inside.txt");
    assert_eq!(manager.changed_files(&checkpoint).unwrap().len(), 1);
    let _second = manager.snapshot("native-wt", 2).expect("second snapshot");
    manager.restore(&checkpoint).expect("restore in worktree");
    assert_eq!(
        std::fs::read_to_string(sub.join("inside.txt")).unwrap(),
        "hello\n"
    );
    let _ = std::fs::remove_dir_all(main);
    let _ = std::fs::remove_dir_all(worktree);
}
