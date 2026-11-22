use std::collections::HashSet;
use std::path::{Component, Path};

use crate::checkpoint::{CheckpointError, CheckpointManager, MAX_FILE_BYTES};
use crate::git_cli::stderr;

impl CheckpointManager {
    /// 用持久索引把工作区同步进树；先查询路径列表并在 Rust 侧过滤，只把允许的文件交给 `git add`。
    /// 这样超大文件、二进制后缀与构建/依赖目录永远不会被 hash 进 `.git/objects/`。
    pub(crate) fn populate_index(&self) -> Result<(), CheckpointError> {
        let cached = match self.read_cached_paths() {
            Ok(paths) => paths,
            Err(_) => {
                // 索引可能被外部进程写坏：删掉重来一次。
                let _ = std::fs::remove_file(&self.index_path);
                let read_tree = self.git_with_index(&self.index_path, ["read-tree", "--empty"])?;
                if !read_tree.status.success() {
                    return Err(CheckpointError::Git(stderr(&read_tree)));
                }
                self.read_cached_paths()?
            }
        };

        let others = self.list_index_paths_z(&[
            "ls-files",
            "--others",
            "--exclude-standard",
            "-z",
            "--",
            ".",
        ])?;
        let newly_ignored: HashSet<String> = if cached.is_empty() {
            HashSet::new()
        } else {
            self.list_index_paths_z(&[
                "ls-files",
                "--cached",
                "--ignored",
                "--exclude-standard",
                "-z",
                "--",
                ".",
            ])?
            .into_iter()
            .collect()
        };

        let mut to_remove = Vec::new();
        let mut to_stage = Vec::new();

        for path in cached {
            if newly_ignored.contains(&path) || !self.should_stage_worktree_path(&path) {
                to_remove.push(path);
            } else {
                to_stage.push(path);
            }
        }
        for path in others {
            if self.should_stage_worktree_path(&path) {
                to_stage.push(path);
            }
        }

        if !to_remove.is_empty() {
            let stdin_bytes = encode_nul_paths(&to_remove);
            let rm = self.git_with_index_stdin(
                &self.index_path,
                &[
                    "rm",
                    "--cached",
                    "--ignore-unmatch",
                    "--quiet",
                    "--pathspec-from-file=-",
                    "--pathspec-file-nul",
                ],
                &stdin_bytes,
            )?;
            if !rm.status.success() {
                return Err(CheckpointError::Git(stderr(&rm)));
            }
        }

        if !to_stage.is_empty() {
            let stdin_bytes = encode_nul_paths(&to_stage);
            let add = self.git_with_index_stdin(
                &self.index_path,
                &[
                    "add",
                    "--all",
                    "--pathspec-from-file=-",
                    "--pathspec-file-nul",
                ],
                &stdin_bytes,
            )?;
            if !add.status.success() {
                return Err(CheckpointError::Git(stderr(&add)));
            }
        }
        Ok(())
    }

    fn read_cached_paths(&self) -> Result<Vec<String>, CheckpointError> {
        if !self.index_path.exists() {
            let read_tree = self.git_with_index(&self.index_path, ["read-tree", "--empty"])?;
            if !read_tree.status.success() {
                return Err(CheckpointError::Git(stderr(&read_tree)));
            }
        }
        self.list_index_paths_z(&["ls-files", "--cached", "-z", "--", "."])
    }

    fn list_index_paths_z(&self, args: &[&str]) -> Result<Vec<String>, CheckpointError> {
        let output = self.git_with_index_stdin(&self.index_path, args, &[])?;
        if !output.status.success() {
            return Err(CheckpointError::Git(stderr(&output)));
        }
        Ok(parse_nul_paths(&output.stdout))
    }

    fn should_stage_worktree_path(&self, path: &str) -> bool {
        if should_skip(path) {
            return false;
        }
        let full_path = self.repo.join(path);
        match std::fs::symlink_metadata(&full_path) {
            Ok(metadata) => !metadata.is_dir() && metadata.len() <= MAX_FILE_BYTES,
            Err(_) => false,
        }
    }
}

fn parse_nul_paths(bytes: &[u8]) -> Vec<String> {
    bytes
        .split(|&byte| byte == 0)
        .filter(|slice| !slice.is_empty())
        .map(|slice| String::from_utf8_lossy(slice).into_owned())
        .collect()
}

fn encode_nul_paths(paths: &[String]) -> Vec<u8> {
    let mut out = Vec::new();
    for path in paths {
        out.extend_from_slice(path.as_bytes());
        out.push(0);
    }
    out
}

fn should_skip(path: &str) -> bool {
    const SKIP_DIRS: &[&str] = &[
        "node_modules",
        "target",
        ".venv",
        "__pycache__",
        ".next",
        ".cache",
        ".git",
    ];
    const BINARY_EXTENSIONS: &[&str] = &[
        "zip", "gz", "tgz", "7z", "rar", "png", "jpg", "jpeg", "gif", "webp", "pdf", "mp4", "mov",
        "mp3", "wav", "woff", "woff2", "ttf", "otf", "dylib", "so", "dll", "exe",
    ];
    if Path::new(path).components().any(|component| {
        matches!(
            component,
            Component::Normal(segment)
                if segment
                    .to_str()
                    .is_some_and(|name| SKIP_DIRS.contains(&name))
        )
    }) {
        return true;
    }
    let extension = Path::new(path)
        .extension()
        .map(|extension| extension.to_string_lossy().to_ascii_lowercase());
    extension
        .as_deref()
        .is_some_and(|extension| BINARY_EXTENSIONS.contains(&extension))
}
