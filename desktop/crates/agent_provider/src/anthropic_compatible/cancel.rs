//! ureq's transport API cannot interrupt an in-flight write_all. Keep one duplicate
//! TCP handle and shut it down when the completion consumer drops. Never retry a
//! partially written body. The connector retains ureq 3.4's TCP timeout, address
//! fallback and buffer contracts; rerun socket/TLS/proxy checks on dependency upgrades.

use futures::Stream;
use std::{
    io::{self, Read, Write},
    net::{Shutdown, TcpStream},
    pin::Pin,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    task::{Context, Poll},
    time::Duration,
};
use ureq::unversioned::transport::{
    Buffers, ConnectionDetails, Connector, Either, LazyBuffers, NextTimeout, Transport,
};

#[derive(Debug, Default)]
struct CancelState {
    cancelled: AtomicBool,
    socket: Mutex<Option<TcpStream>>,
}

#[derive(Clone, Debug, Default)]
pub(super) struct Cancel(Arc<CancelState>);

impl Cancel {
    fn check(&self) -> Result<(), ureq::Error> {
        if self.0.cancelled.load(Ordering::Acquire) {
            return Err(
                io::Error::new(io::ErrorKind::ConnectionAborted, "request cancelled").into(),
            );
        }
        Ok(())
    }

    fn watch(&self, stream: &TcpStream) -> Result<(), ureq::Error> {
        let duplicate = stream.try_clone()?;
        let mut socket = self
            .0
            .socket
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if let Err(error) = self.check() {
            let _ = duplicate.shutdown(Shutdown::Both);
            return Err(error);
        }
        *socket = Some(duplicate);
        Ok(())
    }

    pub(super) fn release(&self) {
        drop(
            self.0
                .socket
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .take(),
        );
    }

    fn cancel(&self) {
        self.0.cancelled.store(true, Ordering::Release);
        if let Some(socket) = self
            .0
            .socket
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .take()
        {
            let _ = socket.shutdown(Shutdown::Both);
        }
    }
}

pub(super) struct CancelOnDrop<S> {
    pub(super) inner: S,
    pub(super) cancel: Cancel,
}
impl<S: Stream + Unpin> Stream for CancelOnDrop<S> {
    type Item = S::Item;
    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        Pin::new(&mut self.get_mut().inner).poll_next(cx)
    }
}
impl<S> Drop for CancelOnDrop<S> {
    fn drop(&mut self) {
        self.cancel.cancel();
    }
}

#[derive(Debug)]
pub(super) struct CancellingTcpConnector {
    pub(super) cancel: Cancel,
}
impl<In: Transport> Connector<In> for CancellingTcpConnector {
    type Out = Either<In, SocketTransport>;
    fn connect(
        &self,
        details: &ConnectionDetails,
        chained: Option<In>,
    ) -> Result<Option<Self::Out>, ureq::Error> {
        if let Some(inner) = chained {
            return Ok(Some(Either::A(inner)));
        }
        self.cancel.check()?;
        let socket = self.connect_socket(details)?;
        if details.config.no_delay() {
            socket.set_nodelay(true)?;
        }
        self.cancel.watch(&socket)?;
        Ok(Some(Either::B(SocketTransport {
            socket,
            buffers: LazyBuffers::new(
                details.config.input_buffer_size(),
                details.config.output_buffer_size(),
            ),
            read_timeout: None,
            write_timeout: None,
        })))
    }
}

impl CancellingTcpConnector {
    fn connect_socket(&self, details: &ConnectionDetails) -> Result<TcpStream, ureq::Error> {
        let total_weight = 2.0 * (1.0 - 0.5_f64.powi(details.addrs.len() as i32));
        let mut weight = 1.0;
        let mut last_error = None;
        for address in &details.addrs {
            self.cancel.check()?;
            let wait = details.timeout.not_zero().map(|budget| {
                Duration::from_millis(
                    (budget.as_secs_f64() * weight / total_weight * 1000.0) as u64,
                )
                .max(Duration::from_millis(10))
            });
            let connected = match wait {
                Some(wait) => TcpStream::connect_timeout(address, wait),
                None => TcpStream::connect(address),
            };
            match connected {
                Ok(socket) => return Ok(socket),
                Err(error) if address_specific(&error) => {
                    last_error = Some(ureq::Error::from(error));
                    continue;
                }
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
                    ) =>
                {
                    if (details.current_time)() >= details.now + details.timeout.after {
                        return Err(ureq::Error::Timeout(details.timeout.reason));
                    }
                    last_error = Some(ureq::Error::Timeout(ureq::Timeout::Connect));
                }
                Err(error) => return Err(error.into()),
            }
            weight /= 2.0;
        }
        Err(last_error.unwrap_or_else(|| {
            io::Error::new(
                io::ErrorKind::ConnectionRefused,
                "no resolved address connected",
            )
            .into()
        }))
    }
}

fn address_specific(error: &io::Error) -> bool {
    #[cfg(windows)]
    if error.raw_os_error() == Some(10013) {
        return true;
    }
    matches!(
        error.kind(),
        io::ErrorKind::ConnectionRefused
            | io::ErrorKind::HostUnreachable
            | io::ErrorKind::NetworkUnreachable
            | io::ErrorKind::AddrNotAvailable
    )
}

pub(super) struct SocketTransport {
    socket: TcpStream,
    buffers: LazyBuffers,
    read_timeout: Option<Duration>,
    write_timeout: Option<Duration>,
}

impl std::fmt::Debug for SocketTransport {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SocketTransport")
            .field("peer", &self.socket.peer_addr().ok())
            .finish()
    }
}
impl Transport for SocketTransport {
    fn buffers(&mut self) -> &mut dyn Buffers {
        &mut self.buffers
    }

    fn transmit_output(&mut self, amount: usize, timeout: NextTimeout) -> Result<(), ureq::Error> {
        set_timeout(
            &self.socket,
            &mut self.write_timeout,
            timeout,
            TcpStream::set_write_timeout,
        )?;
        io_result(
            self.socket.write_all(&self.buffers.output()[..amount]),
            timeout,
        )
    }

    fn await_input(&mut self, timeout: NextTimeout) -> Result<bool, ureq::Error> {
        set_timeout(
            &self.socket,
            &mut self.read_timeout,
            timeout,
            TcpStream::set_read_timeout,
        )?;
        let amount = io_result(self.socket.read(self.buffers.input_append_buf()), timeout)?;
        self.buffers.input_appended(amount);
        Ok(amount > 0)
    }

    fn is_open(&mut self) -> bool {
        if self.socket.set_nonblocking(true).is_err() {
            return false;
        }
        let idle = matches!(self.socket.peek(&mut [0]), Err(error) if error.kind() == io::ErrorKind::WouldBlock);
        self.socket.set_nonblocking(false).is_ok() && idle
    }
}

fn set_timeout(
    socket: &TcpStream,
    previous: &mut Option<Duration>,
    timeout: NextTimeout,
    set: fn(&TcpStream, Option<Duration>) -> io::Result<()>,
) -> io::Result<()> {
    let wait = timeout.not_zero().map(|duration| *duration);
    if *previous != wait {
        set(socket, wait)?;
        *previous = wait;
    }
    Ok(())
}

fn io_result<T>(result: io::Result<T>, timeout: NextTimeout) -> Result<T, ureq::Error> {
    match result {
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
            ) =>
        {
            Err(ureq::Error::Timeout(timeout.reason))
        }
        result => result.map_err(ureq::Error::from),
    }
}
