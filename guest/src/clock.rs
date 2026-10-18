// SPDX-License-Identifier: Apache-2.0
//! The VM owns wall-clock correction; every distro shares CLOCK_REALTIME.

use std::io;

fn rtc_seconds(path: &str) -> io::Result<i64> {
    let text = std::fs::read_to_string(path)?;
    text.trim().parse::<i64>().ok().filter(|&s| s > 0)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "invalid RTC time"))
}

fn needs_correction(rtc: i64, now: libc::timespec) -> bool {
    // The RTC has one-second resolution. Do not turn its quantization into
    // repeated backwards steps when the system clock is already close.
    (i128::from(rtc) * 1_000_000_000
        - (i128::from(now.tv_sec) * 1_000_000_000 + i128::from(now.tv_nsec))).abs() >= 2_000_000_000
}

pub fn sync() -> io::Result<()> {
    let rtc = rtc_seconds("/sys/class/rtc/rtc0/since_epoch")?;
    let mut now = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    if unsafe { libc::clock_gettime(libc::CLOCK_REALTIME, &mut now) } < 0 {
        return Err(io::Error::last_os_error());
    }
    if needs_correction(rtc, now) {
        let target = libc::timespec { tv_sec: rtc, tv_nsec: 0 };
        if unsafe { libc::clock_settime(libc::CLOCK_REALTIME, &target) } < 0 {
            return Err(io::Error::last_os_error());
        }
        crate::sys::log(&format!("clock: corrected from {} to {rtc} (virtual RTC)", now.tv_sec));
    }
    Ok(())
}

#[cfg(test)]
#[path = "../../tests/guest/clock.rs"]
mod tests;
