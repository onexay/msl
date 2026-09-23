//! Flow-controlled byte streams over vsock.
//!
//! Virtualization.framework's vsock device blocks (and with it every vsock
//! connection and eventually a vCPU) if the host stops reading a connection.
//! So every guest<->host byte stream carries frames, and a sender never has
//! more than WINDOW bytes the receiver hasn't delivered yet. The receiver can
//! therefore always read its socket right away; real backpressure moves to the
//! local producer/consumer (a pipe, pty or TCP socket).
//!
//! Frame: [kind u8][len u32 BE][payload]. kind: 0 = data, 1 = credit (payload
//! u32 BE: bytes delivered), 2 = eof (this direction is finished).
//! Both directions start with WINDOW bytes of credit.

use std::collections::VecDeque;
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::sync::{Arc, Condvar, Mutex};

pub const WINDOW: usize = 1 << 20;
const MAX_FRAME: usize = 64 << 10;
const CREDIT_BATCH: usize = 128 << 10;
const DATA: u8 = 0;
const CREDIT: u8 = 1;
const EOF: u8 = 2;

fn write_frame(w: &Mutex<File>, kind: u8, payload: &[u8]) -> io::Result<()> {
    let mut hdr = [0u8; 5];
    hdr[0] = kind;
    hdr[1..].copy_from_slice(&(payload.len() as u32).to_be_bytes());
    let mut f = w.lock().unwrap();
    f.write_all(&hdr)?;
    f.write_all(payload)
}

/// Next frame, or None at a clean end of stream.
fn read_frame(r: &mut File, buf: &mut Vec<u8>) -> io::Result<Option<u8>> {
    let mut hdr = [0u8; 5];
    let mut got = 0;
    while got < 5 {
        match r.read(&mut hdr[got..])? {
            0 if got == 0 => return Ok(None),
            0 => return Err(io::ErrorKind::UnexpectedEof.into()),
            n => got += n,
        }
    }
    let len = u32::from_be_bytes([hdr[1], hdr[2], hdr[3], hdr[4]]) as usize;
    if len > MAX_FRAME.max(4) {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "frame too large"));
    }
    buf.resize(len, 0);
    r.read_exact(buf)?;
    Ok(Some(hdr[0]))
}

/// Send-side credit.
struct Credit {
    state: Mutex<(usize, bool)>, // (available, peer gone)
    cv: Condvar,
}

impl Credit {
    fn take(&self, want: usize) -> Option<usize> {
        let mut g = self.state.lock().unwrap();
        while g.0 == 0 && !g.1 {
            g = self.cv.wait(g).unwrap();
        }
        if g.1 && g.0 == 0 {
            return None;
        }
        let n = want.min(g.0);
        g.0 -= n;
        Some(n)
    }
    fn add(&self, n: usize) {
        self.state.lock().unwrap().0 += n;
        self.cv.notify_all();
    }
    fn kill(&self) {
        self.state.lock().unwrap().1 = true;
        self.cv.notify_all();
    }
}

enum Item {
    Data(Vec<u8>),
    Eof,
}

/// Completion signals for a bridge.
pub struct Bridge {
    /// Fires once everything read from `local_in` has been sent (and eof sent).
    pub sent: std::sync::mpsc::Receiver<()>,
    /// Fires when the whole bridge is finished.
    #[allow(dead_code)]
    pub done: std::sync::mpsc::Receiver<()>,
    reading_since: Arc<Mutex<Option<std::time::Instant>>>,
}

impl Bridge {
    /// How long the sender has been waiting on its local input with nothing
    /// pending (not waiting for credit). Used to give up on output that a
    /// background process keeps open.
    pub fn input_idle(&self) -> std::time::Duration {
        self.reading_since.lock().unwrap().map(|t| t.elapsed()).unwrap_or_default()
    }
}

/// Bridge a framed vsock connection with local endpoints: bytes read from
/// `local_in` go to the peer; bytes from the peer are written to `local_out`
/// (sockets get `shutdown(SHUT_WR)` at the peer's eof, other fds are closed).
pub fn bridge(vsock: File, local_in: Option<File>, local_out: Option<File>) -> io::Result<Bridge> {
    let writer = Arc::new(Mutex::new(vsock.try_clone()?));
    let mut reader = vsock.try_clone()?;
    // Keep `vsock` itself alive for the final shutdown: using a bare fd number
    // after the File is dropped would hit whatever reused that number.
    let vsock = Arc::new(vsock);
    let credit = Arc::new(Credit { state: Mutex::new((WINDOW, false)), cv: Condvar::new() });
    let queue = Arc::new((Mutex::new(VecDeque::<Item>::new()), Condvar::new()));
    let (sent_tx, sent_rx) = std::sync::mpsc::channel();
    let (done_tx, done_rx) = std::sync::mpsc::channel();
    // Finished when: our sender is done, and the peer's data has been delivered.
    let remaining = Arc::new(Mutex::new(2u8));
    let finish = {
        let remaining = remaining.clone();
        move || {
            let mut r = remaining.lock().unwrap();
            *r -= 1;
            if *r == 0 {
                unsafe { libc::shutdown(vsock.as_raw_fd(), libc::SHUT_RDWR) };
                let _ = done_tx.send(());
            }
        }
    };
    let finish = Arc::new(Mutex::new(Some(finish)));
    let call_finish = {
        let f = finish.clone();
        move || {
            if let Some(f) = f.lock().unwrap().as_ref() {
                f()
            }
        }
    };

    let reading_since = Arc::new(Mutex::new(None));
    // Sender: local_in -> data frames (within credit) -> eof.
    {
        let writer = writer.clone();
        let credit = credit.clone();
        let call_finish = call_finish.clone();
        let reading_since = reading_since.clone();
        std::thread::spawn(move || {
            if let Some(mut input) = local_in {
                let mut buf = vec![0u8; MAX_FRAME];
                'outer: loop {
                    *reading_since.lock().unwrap() = Some(std::time::Instant::now());
                    let r = input.read(&mut buf);
                    *reading_since.lock().unwrap() = None;
                    let n = match r {
                        Ok(0) | Err(_) => break,
                        Ok(n) => n,
                    };
                    let mut off = 0;
                    while off < n {
                        let Some(c) = credit.take(n - off) else { break 'outer };
                        if write_frame(&writer, DATA, &buf[off..off + c]).is_err() {
                            break 'outer;
                        }
                        off += c;
                    }
                }
            }
            let _ = write_frame(&writer, EOF, &[]);
            let _ = sent_tx.send(());
            call_finish();
        });
    }

    // Local writer: queued peer data -> local_out, then grant credit.
    {
        let queue = queue.clone();
        let writer = writer.clone();
        let call_finish = call_finish.clone();
        std::thread::spawn(move || {
            let mut out = local_out;
            let mut owed = 0usize;
            loop {
                let item = {
                    let (m, cv) = &*queue;
                    let mut q = m.lock().unwrap();
                    while q.is_empty() {
                        q = cv.wait(q).unwrap();
                    }
                    let item = q.pop_front().unwrap();
                    let more = !q.is_empty();
                    (item, more)
                };
                match item {
                    (Item::Data(d), more) => {
                        if let Some(o) = out.as_mut() {
                            if o.write_all(&d).is_err() {
                                out = None; // local side gone: keep draining so the peer never stalls
                            }
                        }
                        owed += d.len();
                        if owed >= CREDIT_BATCH || !more {
                            let _ = write_frame(&writer, CREDIT, &(owed as u32).to_be_bytes());
                            owed = 0;
                        }
                    }
                    (Item::Eof, _) => {
                        if let Some(o) = out.take() {
                            unsafe { libc::shutdown(o.as_raw_fd(), libc::SHUT_WR) };
                        }
                        break;
                    }
                }
            }
            call_finish();
        });
    }

    // Receiver: always drains the vsock socket (the point of all this).
    std::thread::spawn(move || {
        let mut buf = Vec::with_capacity(MAX_FRAME);
        let push = |item: Item| {
            let (m, cv) = &*queue;
            m.lock().unwrap().push_back(item);
            cv.notify_one();
        };
        let mut peer_eof = false;
        loop {
            match read_frame(&mut reader, &mut buf) {
                Ok(Some(DATA)) => push(Item::Data(std::mem::take(&mut buf))),
                Ok(Some(CREDIT)) if buf.len() == 4 => credit.add(u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize),
                Ok(Some(EOF)) => {
                    if !peer_eof {
                        peer_eof = true;
                        push(Item::Eof);
                    }
                }
                _ => break,
            }
        }
        credit.kill();
        if !peer_eof {
            push(Item::Eof);
        }
    });

    Ok(Bridge { sent: sent_rx, done: done_rx, reading_since })
}

/// A pipe whose read end is sent to the peer (`sink` is the write end, e.g. for tar).
pub fn sender(vsock: File) -> io::Result<(File, Bridge)> {
    let (r, w) = std::io::pipe()?;
    let b = bridge(vsock, Some(File::from(std::os::fd::OwnedFd::from(r))), None)?;
    Ok((File::from(std::os::fd::OwnedFd::from(w)), b))
}

/// A pipe fed with the peer's bytes (`source` is the read end, e.g. for untar).
pub fn receiver(vsock: File) -> io::Result<(File, Bridge)> {
    let (r, w) = std::io::pipe()?;
    let b = bridge(vsock, None, Some(File::from(std::os::fd::OwnedFd::from(w))))?;
    Ok((File::from(std::os::fd::OwnedFd::from(r)), b))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixStream;

    fn pair() -> (File, File) {
        let (a, b) = UnixStream::pair().unwrap();
        (File::from(std::os::fd::OwnedFd::from(a)), File::from(std::os::fd::OwnedFd::from(b)))
    }

    #[test]
    fn transfers_more_than_the_window_both_ways() {
        let (a, b) = pair();
        let (a_sink, a_b) = sender(a).unwrap();
        let (mut b_src, b_b) = receiver(b).unwrap();
        let payload: Vec<u8> = (0..(5 * WINDOW + 123)).map(|i| (i % 251) as u8).collect();
        let p2 = payload.clone();
        let t = std::thread::spawn(move || {
            let mut s = a_sink;
            s.write_all(&p2).unwrap();
        });
        let mut got = Vec::new();
        b_src.read_to_end(&mut got).unwrap();
        t.join().unwrap();
        assert_eq!(got, payload);
        a_b.done.recv().unwrap();
        b_b.done.recv().unwrap();
    }

    #[test]
    fn slow_consumer_does_not_block_the_socket_reader() {
        // The receiver must keep reading the socket (credits keep flowing)
        // even while the local consumer is not reading.
        let (a, b) = pair();
        let (a_sink, _a_b) = sender(a).unwrap();
        let (mut b_src, _b_b) = receiver(b).unwrap();
        let writer = std::thread::spawn(move || {
            let mut s = a_sink;
            s.write_all(&vec![7u8; 3 * WINDOW]).unwrap();
        });
        std::thread::sleep(std::time::Duration::from_millis(300)); // consumer paused
        let mut got = Vec::new();
        b_src.read_to_end(&mut got).unwrap();
        writer.join().unwrap();
        assert_eq!(got.len(), 3 * WINDOW);
    }
}
