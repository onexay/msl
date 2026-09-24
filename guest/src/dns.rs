// SPDX-License-Identifier: Apache-2.0
//! DNS tunneling (WSL's `dnsTunneling`): a stub resolver on 10.255.255.254:53
//! (UDP and TCP) that relays every query to the Mac over vsock, where msld
//! answers it with macOS's own resolver (VPN/split DNS, /etc/resolver, .local).
//!
//! Wire format to the host (vsock CID 2, port 53): one query per connection,
//! 2-byte big-endian length + DNS message, answered the same way.

use std::net::{Ipv4Addr, SocketAddr};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, UdpSocket};

pub const STUB_ADDR: Ipv4Addr = Ipv4Addr::new(10, 255, 255, 254);
const HOST_CID: u32 = 2;
const HOST_DNS_PORT: u32 = 53;

/// Put the stub address on the loopback interface (as `lo:1`).
pub fn configure_address() -> std::io::Result<()> {
    unsafe {
        let fd = libc::socket(libc::AF_INET, libc::SOCK_DGRAM | libc::SOCK_CLOEXEC, 0);
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }
        let mut ifr: libc::ifreq = std::mem::zeroed();
        for (i, b) in b"lo:1".iter().enumerate() {
            ifr.ifr_name[i] = *b as libc::c_char;
        }
        let set = |ifr: &mut libc::ifreq, req: libc::c_ulong, addr: Ipv4Addr| {
            let sin = &mut ifr.ifr_ifru.ifru_addr as *mut libc::sockaddr as *mut libc::sockaddr_in;
            (*sin).sin_family = libc::AF_INET as libc::sa_family_t;
            (*sin).sin_addr.s_addr = u32::from(addr).to_be();
            libc::ioctl(fd, req as _, ifr as *mut libc::ifreq)
        };
        let r1 = set(&mut ifr, libc::SIOCSIFADDR as libc::c_ulong, STUB_ADDR);
        let r2 = set(&mut ifr, libc::SIOCSIFNETMASK as libc::c_ulong, Ipv4Addr::new(255, 255, 255, 255));
        ifr.ifr_ifru.ifru_flags = (libc::IFF_UP | libc::IFF_RUNNING) as libc::c_short;
        let r3 = libc::ioctl(fd, libc::SIOCSIFFLAGS as _, &ifr);
        let err = std::io::Error::last_os_error();
        libc::close(fd);
        if r1 < 0 || r2 < 0 || r3 < 0 {
            return Err(err);
        }
    }
    Ok(())
}

async fn ask_host(query: &[u8]) -> std::io::Result<Vec<u8>> {
    let mut s = tokio_vsock::VsockStream::connect(tokio_vsock::VsockAddr::new(HOST_CID, HOST_DNS_PORT)).await?;
    s.write_all(&(query.len() as u16).to_be_bytes()).await?;
    s.write_all(query).await?;
    let mut len = [0u8; 2];
    s.read_exact(&mut len).await?;
    let mut resp = vec![0u8; u16::from_be_bytes(len) as usize];
    s.read_exact(&mut resp).await?;
    Ok(resp)
}

/// SERVFAIL for `query` (used when the host can't be reached).
fn servfail(query: &[u8]) -> Vec<u8> {
    let mut r = query.to_vec();
    if r.len() >= 4 {
        r[2] = 0x80 | (query[2] & 0x01); // QR, keep RD
        r[3] = 0x82; // RA, RCODE=2
    }
    r
}

pub fn spawn() -> std::io::Result<()> {
    configure_address()?;
    let addr = SocketAddr::from((STUB_ADDR, 53));
    let udp = std::net::UdpSocket::bind(addr)?;
    udp.set_nonblocking(true)?;
    let udp = std::sync::Arc::new(UdpSocket::from_std(udp)?);
    let tcp = std::net::TcpListener::bind(addr)?;
    tcp.set_nonblocking(true)?;
    let tcp = TcpListener::from_std(tcp)?;

    tokio::spawn(async move {
        let mut buf = vec![0u8; 4096];
        loop {
            let Ok((n, peer)) = udp.recv_from(&mut buf).await else { continue };
            let q = buf[..n].to_vec();
            let udp = udp.clone();
            tokio::spawn(async move {
                let resp = ask_host(&q).await.unwrap_or_else(|_| servfail(&q));
                let _ = udp.send_to(&resp, peer).await;
            });
        }
    });
    tokio::spawn(async move {
        loop {
            let Ok((mut s, _)) = tcp.accept().await else { continue };
            tokio::spawn(async move {
                loop {
                    let mut len = [0u8; 2];
                    if s.read_exact(&mut len).await.is_err() {
                        return;
                    }
                    let mut q = vec![0u8; u16::from_be_bytes(len) as usize];
                    if s.read_exact(&mut q).await.is_err() {
                        return;
                    }
                    let resp = ask_host(&q).await.unwrap_or_else(|_| servfail(&q));
                    if s.write_all(&(resp.len() as u16).to_be_bytes()).await.is_err() || s.write_all(&resp).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    Ok(())
}
