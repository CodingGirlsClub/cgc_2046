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

        let newly_ignored: HashSet<Vec<u8>> = if cached.is_empty() {
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

        // 先从私有索引强制清除失效条目（含被符号链接或普通文件替换后的旧目录后代），
        // 再扫描 `--others`，避免目录↔文件/symlink 替换冲突卡住索引更新。
        if !to_remove.is_empty() {
            let stdin_bytes = encode_nul_paths(&to_remove);
            let rm = self.git_with_index_stdin(
                &self.index_path,
                &["update-index", "--force-remove", "-z", "--stdin"],
                &stdin_bytes,
            )?;
            if !rm.status.success() {
                return Err(CheckpointError::Git(stderr(&rm)));
            }
        }

        let others = self.list_index_paths_z(&[
            "ls-files",
            "--others",
            "--exclude-standard",
            "-z",
            "--",
            ".",
        ])?;
        for path in others {
            if self.should_stage_worktree_path(&path) {
                to_stage.push(path);
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

    fn read_cached_paths(&self) -> Result<Vec<Vec<u8>>, CheckpointError> {
        if !self.index_path.exists() {
            let read_tree = self.git_with_index(&self.index_path, ["read-tree", "--empty"])?;
            if !read_tree.status.success() {
                return Err(CheckpointError::Git(stderr(&read_tree)));
            }
        }
        self.list_index_paths_z(&["ls-files", "--cached", "-z", "--", "."])
    }

    fn list_index_paths_z(&self, args: &[&str]) -> Result<Vec<Vec<u8>>, CheckpointError> {
        let output = self.git_with_index_stdin(&self.index_path, args, &[])?;
        if !output.status.success() {
            return Err(CheckpointError::Git(stderr(&output)));
        }
        Ok(parse_nul_paths(&output.stdout))
    }

    fn should_stage_worktree_path(&self, raw_path: &[u8]) -> bool {
        let Some(rel_path) = bytes_to_rel_path(raw_path) else {
            return false;
        };
        if should_skip(rel_path) {
            return false;
        }
        let mut components = Vec::new();
        for component in rel_path.components() {
            match component {
                Component::Normal(segment) => components.push(segment),
                Component::CurDir => {}
                _ => return false,
            }
        }
        let Some((leaf, ancestors)) = components.split_last() else {
            return false;
        };
        let mut cursor = self.repo.clone();
        for ancestor in ancestors {
            cursor.push(ancestor);
            let Ok(metadata) = std::fs::symlink_metadata(&cursor) else {
                return false;
            };
            if !metadata.file_type().is_dir() {
                return false;
            }
        }
        cursor.push(leaf);
        match std::fs::symlink_metadata(&cursor) {
            Ok(metadata) => {
                let file_type = metadata.file_type();
                (file_type.is_file() || file_type.is_symlink()) && metadata.len() <= MAX_FILE_BYTES
            }
            Err(_) => false,
        }
    }
}

fn parse_nul_paths(bytes: &[u8]) -> Vec<Vec<u8>> {
    bytes
        .split(|&byte| byte == 0)
        .filter(|slice| !slice.is_empty())
        .map(|slice| slice.to_vec())
        .collect()
}

fn encode_nul_paths(paths: &[Vec<u8>]) -> Vec<u8> {
    let mut out = Vec::new();
    for path in paths {
        out.extend_from_slice(path);
        out.push(0);
    }
    out
}

#[cfg(unix)]
fn bytes_to_rel_path(bytes: &[u8]) -> Option<&Path> {
    use std::os::unix::ffi::OsStrExt as _;
    Some(Path::new(std::ffi::OsStr::from_bytes(bytes)))
}

#[cfg(not(unix))]
fn bytes_to_rel_path(bytes: &[u8]) -> Option<&Path> {
    std::str::from_utf8(bytes).ok().map(Path::new)
}

fn should_skip(path: &Path) -> bool {
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
    if path.components().any(|component| {
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
    let extension = path
        .extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| extension.to_ascii_lowercase());
    extension
        .as_deref()
        .is_some_and(|extension| BINARY_EXTENSIONS.contains(&extension))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_and_encode_nul_paths_preserve_raw_non_utf8_bytes() {
        let raw = b"valid.txt\0dir/bad-\xff-name.txt\0";
        let parsed = parse_nul_paths(raw);
        assert_eq!(
            parsed,
            vec![b"valid.txt".to_vec(), b"dir/bad-\xff-name.txt".to_vec()]
        );
        assert_eq!(encode_nul_paths(&parsed), raw);
        #[cfg(unix)]
        {
            use std::os::unix::ffi::OsStrExt as _;
            let path = bytes_to_rel_path(&parsed[1]).expect("unix raw bytes path");
            assert_eq!(path.as_os_str().as_bytes(), b"dir/bad-\xff-name.txt");
            assert!(!should_skip(path));
        }
    }
}
