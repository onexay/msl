// SPDX-License-Identifier: Apache-2.0
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

const DIAL_TIMEOUT: Duration = Duration::from_secs(15);

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

/// Connect to a host vsock port (CID 2) and write `token` first: a session
/// stream the host asked for (RunRequest.dial_back). Returned as a *blocking*
/// `File`.
pub async fn dial_host(port: u32, token: &[u8]) -> std::io::Result<File> {
    use tokio::io::AsyncWriteExt;
    const VMADDR_CID_HOST: u32 = 2;
    let mut stream = tokio::time::timeout(DIAL_TIMEOUT, VsockStream::connect(VsockAddr::new(VMADDR_CID_HOST, port)))
        .await
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::TimedOut, "host did not accept the stream"))??;
    stream.write_all(token).await?;
    let fd = unsafe { libc::dup(stream.as_raw_fd()) };
    drop(stream);
    if fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    sys::set_blocking(fd);
    sys::set_cloexec(fd, true);
    Ok(unsafe { File::from_raw_fd(fd) })
}

/// Copy `from` to `to` until eof or an error, with read and write; returns the
/// bytes written. Not std::io::copy: into a pipe it uses splice(2), which
/// holds the pipe's lock while it waits for the socket, so a process exiting
/// with that pipe as its stdin blocks in pipe_release (state D) and is never
/// reaped.
pub fn copy_plain(mut from: File, mut to: &File) -> u64 {
    use std::io::{Read, Write};
    let mut buf = vec![0u8; 256 * 1024];
    let mut total = 0u64;
    loop {
        match from.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                if to.write_all(&buf[..n]).is_err() {
                    break;
                }
                total += n as u64;
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        }
    }
    total
}

/// Keep a stream we wrote to the host open until the host has closed it:
/// Virtualization.framework can drop data still on its way to the host when
/// the guest closes first. The host closes once it has read the byte count we
/// reported on the control channel. It never writes on these streams, so a
/// read returning 0 means it closed (after 10 minutes we stop waiting).
pub fn wait_for_host_close(sock: File) {
    use std::io::Read;
    let timeout = libc::timeval { tv_sec: 600, tv_usec: 0 };
    unsafe {
        libc::setsockopt(sock.as_raw_fd(), libc::SOL_SOCKET, libc::SO_RCVTIMEO, &timeout as *const libc::timeval as *const libc::c_void,
                         std::mem::size_of::<libc::timeval>() as libc::socklen_t);
    }
    let mut buf = [0u8; 256];
    while matches!((&sock).read(&mut buf), Ok(n) if n > 0) {}
}

/// Relay a target in the VM and the host over two one-way streams:
/// `from_host` into the target (its eof shuts down the target's write side),
/// and the target into `to_host`. `done` gets the bytes written to the host
/// once the target has closed; `to_host` stays open until the host closes it.
pub fn relay(target: File, from_host: File, to_host: File, done: tokio::sync::oneshot::Sender<u64>) -> std::io::Result<()> {
    let t = target.try_clone()?;
    std::thread::spawn(move || {
        copy_plain(from_host, &t);
        unsafe { libc::shutdown(t.as_raw_fd(), libc::SHUT_WR) };
    });
    std::thread::spawn(move || {
        let n = copy_plain(target, &to_host);
        let _ = done.send(n);
        wait_for_host_close(to_host);
    });
    Ok(())
}

pub fn status(e: impl std::fmt::Display) -> tonic::Status {
    tonic::Status::internal(e.to_string())
}
