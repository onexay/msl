//! gRPC-over-vsock plumbing and one-shot vsock data ports.

use crate::sys;
use std::fs::File;
use std::os::fd::{AsRawFd, FromRawFd};
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio_vsock::{VMADDR_CID_ANY, VsockAddr, VsockListener, VsockStream};
use tonic::transport::server::Connected;

const VMADDR_PORT_ANY: u32 = u32::MAX;
const DATA_ACCEPT_TIMEOUT: Duration = Duration::from_secs(15);

/// A vsock stream usable as a tonic server connection.
pub struct Conn(VsockStream);

impl Connected for Conn {
    type ConnectInfo = ();
    fn connect_info(&self) -> Self::ConnectInfo {}
}

impl AsyncRead for Conn {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.0).poll_read(cx, buf)
    }
}

impl AsyncWrite for Conn {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<std::io::Result<usize>> {
        Pin::new(&mut self.0).poll_write(cx, buf)
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.0).poll_flush(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.0).poll_shutdown(cx)
    }
}

/// Stream of incoming connections on a fixed vsock port, for `serve_with_incoming`.
pub fn incoming(port: u32) -> std::io::Result<impl futures_util::Stream<Item = std::io::Result<Conn>>> {
    let listener = VsockListener::bind(VsockAddr::new(VMADDR_CID_ANY, port))?;
    Ok(futures_util::stream::unfold(listener, |l| async move {
        let next = l.accept().await.map(|(s, _)| Conn(s));
        Some((next, l))
    }))
}

/// An ephemeral vsock port that accepts exactly one connection.
pub struct DataPort {
    listener: VsockListener,
    pub port: u32,
}

impl DataPort {
    pub fn bind() -> std::io::Result<Self> {
        let listener = VsockListener::bind(VsockAddr::new(VMADDR_CID_ANY, VMADDR_PORT_ANY))?;
        let port = listener.local_addr()?.port();
        Ok(Self { listener, port })
    }

    /// Accept the single connection and hand it back as a *blocking* `File`
    /// (suitable for std I/O threads or as a child's stdio fd).
    pub async fn accept(self) -> std::io::Result<File> {
        let (stream, _) = tokio::time::timeout(DATA_ACCEPT_TIMEOUT, self.listener.accept())
            .await
            .map_err(|_| std::io::Error::new(std::io::ErrorKind::TimedOut, "host did not connect to data port"))??;
        // dup, drop tokio's copy, then clear O_NONBLOCK on the (shared) description.
        let fd = unsafe { libc::dup(stream.as_raw_fd()) };
        drop(stream);
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }
        sys::set_blocking(fd);
        sys::set_cloexec(fd, true);
        Ok(unsafe { File::from_raw_fd(fd) })
    }
}

pub fn status(e: impl std::fmt::Display) -> tonic::Status {
    tonic::Status::internal(e.to_string())
}
