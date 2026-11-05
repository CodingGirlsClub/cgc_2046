//! ACP 的受控 stdio 进程：SDK 3.4 的 AcpAgentConfig 不支持 env_clear/cwd。
//! 协议编解码仍使用 SDK Lines；这里只负责启动环境、stdio 边界与进程回收。

use std::collections::VecDeque;
use std::future::Future;
use std::process::Stdio;
use std::task::Poll;
use std::time::Duration;

use agent_client_protocol::{Agent, Client, ConnectTo, Error, Lines};
use futures::channel::oneshot;
use futures::future::Shared;
use futures::io::{AsyncBufReadExt, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use futures::{FutureExt, StreamExt};

use crate::agent::command::{configure_process_group, terminate_process_group};
use crate::agent::launch::LaunchPlan;

pub(super) struct ManagedProcess {
    pub plan: LaunchPlan,
    /// Tells the client loop how the supervised process ended.
    pub completion: Option<oneshot::Sender<Result<(), String>>>,
}

struct OwnedChild(async_process::Child);

impl OwnedChild {
    fn terminate(&mut self) {
        terminate_process_group(self.0.id());
        let _ = self.0.kill();
    }
}

impl Drop for OwnedChild {
    fn drop(&mut self) {
        self.terminate();
    }
}

// SDK 3.4 keeps its AcpAgent write guard private. Bound this stdio write while
// leaving JSON-RPC encoding and dispatch in the SDK's Lines transport.
async fn write_line_with_eof_timeout<W: AsyncWrite + Unpin>(
    writer: &mut W,
    line: &str,
    eof: Shared<oneshot::Receiver<()>>,
    eof_seen: &mut bool,
    grace: Duration,
) -> std::io::Result<()> {
    let write = async {
        writer.write_all(line.as_bytes()).await?;
        writer.write_all(b"\n").await?;
        writer.flush().await
    };
    futures::pin_mut!(write);
    if *eof_seen {
        return finish_write(write, grace).await;
    }
    let closed = eof.fuse();
    futures::pin_mut!(closed);
    match futures::future::select(write, closed).await {
        futures::future::Either::Left((result, _)) => result,
        futures::future::Either::Right((closed, write)) => {
            if closed.is_ok() {
                *eof_seen = true;
                finish_write(write, grace).await
            } else {
                // Reader cancellation must not be mistaken for physical EOF.
                write.await
            }
        }
    }
}

async fn finish_write<F>(write: F, grace: Duration) -> std::io::Result<()>
where
    F: Future<Output = std::io::Result<()>> + Unpin,
{
    let deadline = super::sleep(grace);
    futures::pin_mut!(deadline);
    match futures::future::select(write, deadline).await {
        futures::future::Either::Left((result, _)) => result,
        futures::future::Either::Right(_) => Err(std::io::Error::new(
            std::io::ErrorKind::TimedOut,
            "agent closed stdout before pending protocol output drained",
        )),
    }
}

fn internal(error: impl std::fmt::Display) -> Error {
    Error::internal_error().data(error.to_string())
}

fn check_exit(status: std::io::Result<std::process::ExitStatus>) -> Result<(), Error> {
    let status = status.map_err(internal)?;
    if status.success() {
        Ok(())
    } else {
        Err(internal(format!("agent exited with {status}")))
    }
}

impl ConnectTo<Client> for ManagedProcess {
    async fn connect_to(self, client: impl ConnectTo<Agent>) -> Result<(), Error> {
        let plan = self.plan;
        let completion = self.completion;
        let mut command = std::process::Command::new(plan.program);
        command
            .args(plan.args)
            .current_dir(plan.cwd)
            .env_clear()
            .envs(plan.env);
        configure_process_group(&mut command);
        let mut command = async_process::Command::from(command);
        command
            .kill_on_drop(true)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = OwnedChild(command.spawn().map_err(internal)?);
        let stdin = child.0.stdin.take().expect("piped stdin");
        let stdout = child.0.stdout.take().expect("piped stdout");
        let (closed, stdout_closed) = oneshot::channel();
        let eof = stdout_closed.shared();
        let mut incoming = BufReader::new(stdout).lines();
        let mut closed = Some(closed);
        let incoming = futures::stream::poll_fn(move |context| {
            let next = incoming.poll_next_unpin(context);
            if matches!(next, Poll::Ready(None)) {
                if let Some(closed) = closed.take() {
                    let _ = closed.send(());
                }
            }
            next
        });
        let mut stderr = child.0.stderr.take().expect("piped stderr");
        let mut tail = VecDeque::new();
        let grace = std::time::Duration::from_secs(1);
        let outgoing = Box::pin(futures::sink::unfold(
            (stdin, eof.clone(), false),
            move |(mut writer, eof, mut eof_seen), line: String| async move {
                write_line_with_eof_timeout(&mut writer, &line, eof.clone(), &mut eof_seen, grace)
                    .await?;
                Ok::<_, std::io::Error>((writer, eof, eof_seen))
            },
        ));
        let result = {
            let connection = async {
                let (outcome, status) = async {
                    let protocol =
                        ConnectTo::<Client>::connect_to(Lines::new(outgoing, incoming), client);
                    let exit = child.0.status();
                    let stdout_eof = async move {
                        if eof.await.is_err() {
                            // Dropping the reader cancels the signal; only an
                            // explicit send represents physical EOF.
                            futures::future::pending::<()>().await;
                        }
                    };
                    let protocol = protocol.fuse();
                    let exit = exit.fuse();
                    let stdout_eof = stdout_eof.fuse();
                    futures::pin_mut!(protocol, exit, stdout_eof);
                    futures::select_biased! {
                        result = protocol => {
                            let status = if result.is_ok() {
                                let deadline = super::sleep(grace);
                                futures::pin_mut!(deadline);
                                match futures::future::select(exit.as_mut(), deadline).await {
                                    futures::future::Either::Left((status, _)) => Some(status),
                                    futures::future::Either::Right(_) => None,
                                }
                            } else {
                                None
                            };
                            (result, status)
                        },
                        status = exit => {
                            let deadline = super::sleep(grace);
                            futures::pin_mut!(deadline);
                            let outcome = match futures::future::select(protocol.as_mut(), deadline).await {
                                futures::future::Either::Left((result, _)) => result,
                                futures::future::Either::Right(_) => Ok(()),
                            };
                            (outcome, Some(status))
                        }
                        _ = stdout_eof => {
                            // Let frames already read from stdout reach the client
                            // before the transport ends.
                            let deadline = super::sleep(grace);
                            futures::pin_mut!(deadline);
                            let drained = match futures::future::select(protocol.as_mut(), deadline).await {
                                futures::future::Either::Left((result, _)) => result,
                                futures::future::Either::Right(_) => Ok(()),
                            };
                            if drained.is_err() {
                                (drained, None)
                            } else {
                                let deadline = super::sleep(grace);
                                futures::pin_mut!(deadline);
                                let status = match futures::future::select(exit.as_mut(), deadline).await {
                                    futures::future::Either::Left((status, _)) => Some(status),
                                    futures::future::Either::Right(_) => None,
                                };
                                (Ok(()), status)
                            }
                        }
                    }
                }
                .await;
                let reaped = status.is_some();
                let result = match status {
                    Some(status) => check_exit(status).and(outcome),
                    None => outcome,
                };
                child.terminate();
                if !reaped {
                    let _ = child.0.status().await;
                }
                result
            };
            let diagnostics = async {
                let mut buffer = [0; 8192];
                while let Ok(count) = stderr.read(&mut buffer).await {
                    if count == 0 {
                        break;
                    }
                    let overflow = (tail.len() + count).saturating_sub(64 * 1024);
                    tail.drain(..overflow);
                    tail.extend(&buffer[..count]);
                }
            };
            futures::pin_mut!(connection, diagnostics);
            match futures::future::select(connection, diagnostics).await {
                futures::future::Either::Left((result, diagnostics)) => {
                    let deadline = super::sleep(grace);
                    futures::pin_mut!(deadline);
                    let _ = futures::future::select(diagnostics, deadline).await;
                    result
                }
                futures::future::Either::Right(((), connection)) => connection.await,
            }
        };
        let diagnostics = String::from_utf8_lossy(tail.make_contiguous());
        let result =
            result.map_err(|error| internal(format!("{error}; agent stderr: {diagnostics}")));
        if let Some(completion) = completion {
            let outcome = match &result {
                Ok(()) => Ok(()),
                Err(error) => Err(format!("acp connection: {error}")),
            };
            let _ = completion.send(outcome);
        }
        result
    }
}
