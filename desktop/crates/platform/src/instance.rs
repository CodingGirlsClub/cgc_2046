//! 单实例协调：第一个进程成为 owner，后续进程把启动参数交给 owner 后退出。
//!
//! 用本地 socket 做跨平台 handoff：Unix 是用户数据目录下的 socket 文件，Windows 是
//! 命名管道。这里不监听 TCP 端口，也不把 payload 放进命令行之外的全局位置。
//! listener 线程只做 I/O；UI 侧通过 `Instance::try_recv` 取消息后在主线程处理。

use std::io::{Read, Write};
use std::path::Path;
use std::sync::mpsc::{self, Receiver};
use std::time::Duration;

use interprocess::local_socket::prelude::*;
use interprocess::local_socket::{ListenerOptions, Stream};

pub const MAX_PAYLOAD_BYTES: usize = 8 * 1024;
const MAX_URLS: usize = 16;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InstanceMessage {
    pub urls: Vec<String>,
}

pub enum InstanceStart {
    Owner(Instance),
    HandedOff,
}

pub struct Instance {
    receiver: Receiver<InstanceMessage>,
}

impl Instance {
    /// 非阻塞取一条 handoff 消息；没有消息时返回 `None`。
    pub fn try_recv(&self) -> Option<InstanceMessage> {
        self.receiver.try_recv().ok()
    }

    /// 测试/启动阶段使用；生产 UI 用非阻塞轮询。
    pub fn recv_timeout(&self, timeout: Duration) -> Option<InstanceMessage> {
        self.receiver.recv_timeout(timeout).ok()
    }
}

/// 尝试成为 owner；如果同环境已有 owner，则把参数 handoff 过去并返回 `HandedOff`。
pub fn claim(
    state_dir: &Path,
    environment: &str,
    urls: Vec<String>,
) -> std::io::Result<InstanceStart> {
    std::fs::create_dir_all(state_dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(state_dir, std::fs::Permissions::from_mode(0o700));
    }

    match create_listener(state_dir, environment) {
        Ok(listener) => start_owner(listener),
        Err(error) if is_address_in_use(&error) => {
            if connect_and_hand_off(state_dir, environment, &urls).is_ok() {
                return Ok(InstanceStart::HandedOff);
            }
            // 没有活着的 owner：清掉上一次异常退出留下的 Unix socket 后重试一次。
            #[cfg(unix)]
            {
                let _ = std::fs::remove_file(socket_path(state_dir));
            }
            match create_listener(state_dir, environment) {
                Ok(listener) => start_owner(listener),
                Err(error) => Err(error),
            }
        }
        Err(error) => Err(error),
    }
}

fn start_owner(listener: interprocess::local_socket::Listener) -> std::io::Result<InstanceStart> {
    let (sender, receiver) = mpsc::channel();
    std::thread::Builder::new()
        .name("cgc-instance-listener".to_string())
        .spawn(move || listen(listener, sender))
        .map_err(|error| std::io::Error::other(error.to_string()))?;
    Ok(InstanceStart::Owner(Instance { receiver }))
}

fn is_address_in_use(error: &std::io::Error) -> bool {
    error.kind() == std::io::ErrorKind::AddrInUse
        || matches!(error.raw_os_error(), Some(48 | 98 | 231))
        || error
            .to_string()
            .to_ascii_lowercase()
            .contains("already in use")
}

fn listen(listener: interprocess::local_socket::Listener, sender: mpsc::Sender<InstanceMessage>) {
    loop {
        let stream = match listener.accept() {
            Ok(stream) => stream,
            Err(_) => return,
        };
        let stream = stream;
        let mut payload = String::new();
        if stream
            .take(MAX_PAYLOAD_BYTES as u64)
            .read_to_string(&mut payload)
            .is_err()
        {
            continue;
        }
        let Some(urls) = parse_payload(&payload) else {
            continue;
        };
        if sender.send(InstanceMessage { urls }).is_err() {
            return;
        }
    }
}

fn parse_payload(raw: &str) -> Option<Vec<String>> {
    let value: serde_json::Value = serde_json::from_str(raw).ok()?;
    let urls = value.get("urls")?.as_array()?;
    if urls.len() > MAX_URLS {
        return None;
    }
    let urls = urls
        .iter()
        .filter_map(|url| url.as_str())
        .filter(|url| !url.is_empty())
        .map(str::to_string)
        .collect::<Vec<_>>();
    Some(urls)
}

fn payload(urls: &[String]) -> String {
    serde_json::json!({ "urls": urls }).to_string()
}

#[cfg(unix)]
fn socket_path(state_dir: &Path) -> std::path::PathBuf {
    use std::hash::{Hash, Hasher};

    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    state_dir.hash(&mut hasher);
    std::env::temp_dir().join(format!("cgc2046-{:016x}.sock", hasher.finish()))
}

#[cfg(unix)]
fn create_listener(
    state_dir: &Path,
    _environment: &str,
) -> std::io::Result<interprocess::local_socket::Listener> {
    use interprocess::local_socket::GenericFilePath;
    use std::os::unix::fs::PermissionsExt;

    let path = socket_path(state_dir);
    let name = path
        .clone()
        .to_fs_name::<GenericFilePath>()
        .map_err(|error| std::io::Error::other(error.to_string()))?;
    let listener = ListenerOptions::new()
        .name(name)
        .create_sync()
        .map_err(|error| std::io::Error::other(error.to_string()))?;
    // Local socket files in /tmp must not be connectable by other users.
    let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    Ok(listener)
}

#[cfg(unix)]
fn connect_and_hand_off(
    state_dir: &Path,
    _environment: &str,
    urls: &[String],
) -> std::io::Result<()> {
    use interprocess::local_socket::GenericFilePath;

    let path = socket_path(state_dir);
    let name = path
        .to_fs_name::<GenericFilePath>()
        .map_err(|error| std::io::Error::other(error.to_string()))?;
    let mut stream =
        Stream::connect(name).map_err(|error| std::io::Error::other(error.to_string()))?;
    write_payload(&mut stream, urls)
}

#[cfg(windows)]
fn instance_name(environment: &str) -> String {
    let user = std::env::var("USERNAME").unwrap_or_else(|_| "default".to_string());
    format!("cgc2046.instance.{environment}.{user}")
}

#[cfg(windows)]
fn create_listener(
    _state_dir: &Path,
    environment: &str,
) -> std::io::Result<interprocess::local_socket::Listener> {
    use interprocess::local_socket::GenericNamespaced;

    let name = instance_name(environment);
    let name = name
        .to_ns_name::<GenericNamespaced>()
        .map_err(|error| std::io::Error::other(error.to_string()))?;
    ListenerOptions::new().name(name).create_sync()
}

#[cfg(windows)]
fn connect_and_hand_off(
    _state_dir: &Path,
    environment: &str,
    urls: &[String],
) -> std::io::Result<()> {
    use interprocess::local_socket::GenericNamespaced;

    let name = instance_name(environment);
    let name = name
        .to_ns_name::<GenericNamespaced>()
        .map_err(|error| std::io::Error::other(error.to_string()))?;
    let mut stream =
        Stream::connect(name).map_err(|error| std::io::Error::other(error.to_string()))?;
    write_payload(&mut stream, urls)
}

fn write_payload(stream: &mut Stream, urls: &[String]) -> std::io::Result<()> {
    stream.write_all(payload(urls).as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_state_dir(name: &str) -> std::path::PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        std::env::temp_dir().join(format!(
            "cgc-instance-{name}-{}-{stamp}",
            std::process::id()
        ))
    }

    #[cfg(unix)]
    #[test]
    fn stale_unix_socket_is_reclaimed() {
        let state_dir = temp_state_dir("stale");
        std::fs::create_dir_all(&state_dir).expect("state dir");
        let path = socket_path(&state_dir);
        std::fs::create_dir_all(path.parent().expect("socket parent")).expect("socket parent");
        {
            // A listener that exits without unlinking leaves a stale socket file behind.
            let stale = std::os::unix::net::UnixListener::bind(&path).expect("bind stale socket");
            drop(stale);
        }
        let start = claim(&state_dir, "test", Vec::new()).expect("claim after stale socket");
        assert!(matches!(start, InstanceStart::Owner(_)));
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_dir_all(state_dir);
    }

    #[test]
    fn second_claim_hands_off_to_owner() {
        let state_dir = temp_state_dir("handoff");
        let start = claim(&state_dir, "test", Vec::new()).expect("claim owner");
        let InstanceStart::Owner(instance) = start else {
            panic!("first claim must own");
        };

        let second = claim(
            &state_dir,
            "test",
            vec!["cgc://courses/00000000-0000-0000-0000-000000000001".to_string()],
        )
        .expect("second claim");
        assert!(matches!(second, InstanceStart::HandedOff));

        let message = instance
            .recv_timeout(Duration::from_secs(3))
            .expect("owner receives handoff");
        assert_eq!(
            message.urls,
            vec!["cgc://courses/00000000-0000-0000-0000-000000000001".to_string()]
        );

        let _ = std::fs::remove_dir_all(state_dir);
    }
}
