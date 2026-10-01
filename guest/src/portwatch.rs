// SPDX-License-Identifier: Apache-2.0
//! Wake-ups for the listening-port watcher, from the kernel instead of a timer.
//!
//! A sock_ops program on the root cgroup (so every distro, which all share the
//! VM's network namespace) sees each TCP `listen(2)` (BPF_SOCK_OPS_TCP_LISTEN_CB)
//! and turns on the state callback for that socket, so it also sees the
//! listener leave LISTEN. Either way it writes a record to a ring buffer, and
//! the watcher, asleep on the buffer's fd, rescans /proc/net/tcp{,6}. The
//! program is a handful of raw BPF instructions: no libbpf, no BTF, no JIT
//! needed (the interpreter is plenty at this rate).

use std::io::{Error, Result};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

const BPF_MAP_CREATE: libc::c_long = 0;
const BPF_PROG_LOAD: libc::c_long = 5;
const BPF_PROG_ATTACH: libc::c_long = 8;
const BPF_MAP_TYPE_RINGBUF: u32 = 27;
const BPF_PROG_TYPE_SOCK_OPS: u32 = 13;
const BPF_CGROUP_SOCK_OPS: u32 = 3;
const BPF_F_ALLOW_MULTI: u32 = 2;

// struct bpf_sock_ops: `op` at 0, `args[0]` at 4.
const SOCK_OPS_STATE_CB: i32 = 10;
const SOCK_OPS_TCP_LISTEN_CB: i32 = 11;
const SOCK_OPS_STATE_CB_FLAG: i32 = 4;
const TCP_LISTEN: i32 = 10;
const HELPER_SOCK_OPS_CB_FLAGS_SET: i32 = 59;
const HELPER_RINGBUF_OUTPUT: i32 = 130;

/// One BPF instruction (struct bpf_insn).
#[repr(C)]
#[derive(Clone, Copy)]
struct Insn {
    code: u8,
    regs: u8, // dst | src << 4
    off: i16,
    imm: i32,
}

const fn insn(code: u8, dst: u8, src: u8, off: i16, imm: i32) -> Insn {
    Insn { code, regs: dst | (src << 4), off, imm }
}

/// The program. Returns 1 (carry on) in every case.
///   r6 = ctx
///   if op == TCP_LISTEN_CB: bpf_sock_ops_cb_flags_set(ctx, STATE_CB_FLAG); emit
///   if op == STATE_CB && old state == LISTEN: emit
///   emit: bpf_ringbuf_output(map, &1u64, 8, 0)
fn program(map_fd: i32) -> Vec<Insn> {
    vec![
        insn(0xbf, 6, 1, 0, 0),                             // 0: r6 = r1
        insn(0x61, 2, 1, 0, 0),                             // 1: r2 = *(u32 *)(r1 + 0)   op
        insn(0x15, 2, 0, 4, SOCK_OPS_TCP_LISTEN_CB),        // 2: if r2 == LISTEN_CB goto 7
        insn(0x55, 2, 0, 14, SOCK_OPS_STATE_CB),            // 3: if r2 != STATE_CB goto 18
        insn(0x61, 2, 6, 4, 0),                             // 4: r2 = *(u32 *)(r6 + 4)   args[0], old state
        insn(0x55, 2, 0, 12, TCP_LISTEN),                   // 5: if r2 != TCP_LISTEN goto 18
        insn(0x05, 0, 0, 3, 0),                             // 6: goto 10
        insn(0xbf, 1, 6, 0, 0),                             // 7: r1 = r6
        insn(0xb7, 2, 0, 0, SOCK_OPS_STATE_CB_FLAG),        // 8: r2 = STATE_CB_FLAG
        insn(0x85, 0, 0, 0, HELPER_SOCK_OPS_CB_FLAGS_SET),  // 9: call bpf_sock_ops_cb_flags_set
        insn(0x7a, 10, 0, -8, 1),                           // 10: *(u64 *)(r10 - 8) = 1
        insn(0x18, 1, 1, 0, map_fd),                        // 11: r1 = map (ld_imm64, pseudo map fd)
        insn(0x00, 0, 0, 0, 0),                             // 12:   (second half)
        insn(0xbf, 2, 10, 0, 0),                            // 13: r2 = r10
        insn(0x07, 2, 0, 0, -8),                            // 14: r2 += -8
        insn(0xb7, 3, 0, 0, 8),                             // 15: r3 = 8
        insn(0xb7, 4, 0, 0, 0),                             // 16: r4 = 0
        insn(0x85, 0, 0, 0, HELPER_RINGBUF_OUTPUT),         // 17: call bpf_ringbuf_output
        insn(0xb7, 0, 0, 0, 1),                             // 18: r0 = 1
        insn(0x95, 0, 0, 0, 0),                             // 19: exit
    ]
}

fn bpf<T>(cmd: libc::c_long, attr: &mut T) -> Result<i32> {
    let r = unsafe { libc::syscall(libc::SYS_bpf, cmd, attr as *mut T, std::mem::size_of::<T>()) };
    if r < 0 { Err(Error::last_os_error()) } else { Ok(r as i32) }
}

/// The ring buffer the program writes to, mapped for reading its positions.
pub struct Events {
    map: OwnedFd,
    consumer: *mut u64, // consumer_pos (first page, read-write)
    producer: *const u64, // producer_pos (second page, read-only)
    page: usize,
    _prog: OwnedFd,
}

// The mapped positions are only touched through atomics.
unsafe impl Send for Events {}
unsafe impl Sync for Events {}

impl Events {
    /// Load the program and attach it to the root cgroup (/sys/fs/cgroup).
    pub fn attach() -> Result<Events> {
        let page = unsafe { libc::sysconf(libc::_SC_PAGESIZE) } as usize;

        #[repr(C)]
        #[derive(Default)]
        struct MapCreate { map_type: u32, key_size: u32, value_size: u32, max_entries: u32 }
        // The data area must be a power of two and a multiple of the page size.
        let mut a = MapCreate { map_type: BPF_MAP_TYPE_RINGBUF, max_entries: page as u32, ..Default::default() };
        let map = unsafe { OwnedFd::from_raw_fd(bpf(BPF_MAP_CREATE, &mut a)?) };

        let insns = program(map.as_raw_fd());
        let license = c"Apache-2.0";
        let mut log = vec![0u8; 4096];
        #[repr(C)]
        struct ProgLoad { prog_type: u32, insn_cnt: u32, insns: u64, license: u64, log_level: u32, log_size: u32, log_buf: u64 }
        let mut p = ProgLoad {
            prog_type: BPF_PROG_TYPE_SOCK_OPS,
            insn_cnt: insns.len() as u32,
            insns: insns.as_ptr() as u64,
            license: license.as_ptr() as u64,
            log_level: 1,
            log_size: log.len() as u32,
            log_buf: log.as_mut_ptr() as u64,
        };
        let prog = match bpf(BPF_PROG_LOAD, &mut p) {
            Ok(fd) => unsafe { OwnedFd::from_raw_fd(fd) },
            Err(e) => {
                let msg = String::from_utf8_lossy(&log[..log.iter().position(|b| *b == 0).unwrap_or(0)]).trim().to_string();
                return Err(Error::new(e.kind(), format!("{e}; verifier: {msg}")));
            }
        };

        let cgroup = std::fs::File::open("/sys/fs/cgroup")?;
        #[repr(C)]
        struct ProgAttach { target_fd: u32, attach_bpf_fd: u32, attach_type: u32, attach_flags: u32 }
        let mut at = ProgAttach {
            target_fd: cgroup.as_raw_fd() as u32,
            attach_bpf_fd: prog.as_raw_fd() as u32,
            attach_type: BPF_CGROUP_SOCK_OPS,
            attach_flags: BPF_F_ALLOW_MULTI,
        };
        bpf(BPF_PROG_ATTACH, &mut at)?;

        let map_page = |off: usize, prot: libc::c_int| -> Result<*mut libc::c_void> {
            let p = unsafe { libc::mmap(std::ptr::null_mut(), page, prot, libc::MAP_SHARED, map.as_raw_fd(), off as libc::off_t) };
            if p == libc::MAP_FAILED { Err(Error::last_os_error()) } else { Ok(p) }
        };
        let consumer = map_page(0, libc::PROT_READ | libc::PROT_WRITE)? as *mut u64;
        let producer = map_page(page, libc::PROT_READ)? as *const u64;
        Ok(Events { map, consumer, producer, page, _prog: prog })
    }

    /// Drop every pending record (only their arrival matters); true if there were any.
    pub fn drain(&self) -> bool {
        use std::sync::atomic::{AtomicU64, Ordering};
        unsafe {
            let prod = (*(self.producer as *const AtomicU64)).load(Ordering::Acquire);
            let cons = &*(self.consumer as *const AtomicU64);
            let had = cons.load(Ordering::Relaxed) != prod;
            cons.store(prod, Ordering::Release);
            had
        }
    }
}

impl AsRawFd for Events {
    fn as_raw_fd(&self) -> std::os::fd::RawFd {
        self.map.as_raw_fd()
    }
}

impl Drop for Events {
    fn drop(&mut self) {
        unsafe {
            libc::munmap(self.consumer as *mut libc::c_void, self.page);
            libc::munmap(self.producer as *mut libc::c_void, self.page);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jumps_land_where_the_comments_say() {
        let p = program(3);
        assert_eq!(p.len(), 20);
        let target = |i: usize| (i as i64 + 1 + p[i].off as i64) as usize;
        assert_eq!(target(2), 7); // listen
        assert_eq!(target(3), 18); // out
        assert_eq!(target(5), 18); // out
        assert_eq!(target(6), 10); // emit
        assert_eq!(p[11].regs, 1 | 1 << 4); // ld_imm64 r1, BPF_PSEUDO_MAP_FD
        assert_eq!(p[11].imm, 3);
        assert_eq!((p[19].code, p[18].imm), (0x95, 1));
        assert_eq!(std::mem::size_of::<Insn>(), 8);
    }
}
