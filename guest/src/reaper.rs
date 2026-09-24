// SPDX-License-Identifier: Apache-2.0
//! Single reaper for a process that is PID 1 or a subreaper.
//!
//! Exactly one thread calls `waitpid(-1)`. Everyone else asks the reaper for a
//! child's exit status by pid; nothing else may wait on children (so never use
//! `Child::wait` or `tokio::process`).

use nix::sys::wait::{WaitStatus, waitpid};
use nix::unistd::Pid;
use std::collections::HashMap;
use std::sync::{Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};
use tokio::sync::oneshot;

#[derive(Default)]
struct Inner {
    exited: HashMap<i32, i32>,
    waiters: HashMap<i32, Vec<oneshot::Sender<i32>>>,
}

struct State {
    inner: Mutex<Inner>,
    cv: Condvar,
}

fn state() -> &'static State {
    static S: OnceLock<State> = OnceLock::new();
    S.get_or_init(|| State { inner: Mutex::new(Inner::default()), cv: Condvar::new() })
}

/// Run forever on the calling thread.
pub fn run() -> ! {
    loop {
        match waitpid(Pid::from_raw(-1), None) {
            Ok(WaitStatus::Exited(pid, code)) => record(pid.as_raw(), code),
            Ok(WaitStatus::Signaled(pid, sig, _)) => record(pid.as_raw(), 128 + sig as i32),
            Ok(_) => {}
            Err(nix::errno::Errno::ECHILD) => std::thread::sleep(Duration::from_millis(50)),
            Err(_) => {}
        }
    }
}

pub fn spawn_thread() {
    std::thread::Builder::new().name("reaper".into()).spawn(|| run()).expect("reaper thread");
}

fn record(pid: i32, code: i32) {
    let s = state();
    let mut g = s.inner.lock().unwrap();
    match g.waiters.remove(&pid) {
        Some(txs) => {
            for tx in txs {
                let _ = tx.send(code);
            }
        }
        None => {
            g.exited.insert(pid, code);
        }
    }
    s.cv.notify_all();
}

/// Async wait for `pid` to exit.
pub fn wait_async(pid: i32) -> oneshot::Receiver<i32> {
    let (tx, rx) = oneshot::channel();
    let mut g = state().inner.lock().unwrap();
    if let Some(code) = g.exited.remove(&pid) {
        let _ = tx.send(code);
    } else {
        g.waiters.entry(pid).or_default().push(tx);
    }
    rx
}

/// Blocking wait for `pid` to exit; `None` on timeout.
pub fn wait(pid: i32, timeout: Option<Duration>) -> Option<i32> {
    let s = state();
    let deadline = timeout.map(|t| Instant::now() + t);
    let mut g = s.inner.lock().unwrap();
    loop {
        if let Some(code) = g.exited.remove(&pid) {
            return Some(code);
        }
        match deadline {
            None => g = s.cv.wait(g).unwrap(),
            Some(d) => {
                let now = Instant::now();
                if now >= d {
                    return None;
                }
                g = s.cv.wait_timeout(g, d - now).unwrap().0;
            }
        }
    }
}
