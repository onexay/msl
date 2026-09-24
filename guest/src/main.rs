// SPDX-License-Identifier: Apache-2.0
//! `msl-guest`: a single static multi-call binary for the MSL utility VM.
//!
//! Role is chosen by argv[0] (basename):
//! - `init` (the initramfs /init, PID 1)   -> utility-VM mini-init
//! - `msl-distro-init <json>`              -> per-distro namespace setup + agent
//! - `mslpath` (symlink in the distro)      -> path translation (wslpath equivalent)

mod agent;
mod archive;
mod compat;
mod config;
mod distroinit;
mod dns;
mod framed;
mod miniinit;
mod net;
mod nfs;
mod nfsview;
mod oobe;
mod paths;
mod reaper;
mod rpc;
mod session;
mod sys;
mod users;

pub mod pb {
    tonic::include_proto!("msl.v1");
}

use std::path::Path;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let argv0 = args.first().map(String::as_str).unwrap_or("");
    let role = Path::new(argv0).file_name().and_then(|s| s.to_str()).unwrap_or("");

    // `/run/msl/init msl-oobe` inside a distro (never as PID 1).
    if args.get(1).map(String::as_str) == Some("msl-oobe") && std::process::id() != 1 {
        oobe::main();
    }
    if role == "mslpath" {
        paths::mslpath_main(&args[1..]);
    }
    let result = match role {
        "msl-distro-init" => distroinit::main(&args[1..]),
        _ => miniinit::main(),
    };
    if let Err(e) = result {
        sys::log(&format!("{role}: fatal: {e}"));
        std::process::exit(1);
    }
}
