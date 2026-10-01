// SPDX-License-Identifier: Apache-2.0
import Foundation
// msld: the MSL service (wslservice.exe equivalent). Started on demand by msl.
import MSLCore
import MSLService

// A write to a socket or pipe whose reader is gone (an msl client that exited,
// a vsock the guest closed) must fail with EPIPE, not kill msld and the VM.
signal(SIGPIPE, SIG_IGN)

if let m = MSLBuild.unsupportedMacOS() {
    FileHandle.standardError.write("msld: \(m)\n".data(using: .utf8)!)
    exit(1)
}

do {
    try Service().serve()
} catch {
    FileHandle.standardError.write("msld: \(error)\n".data(using: .utf8)!)
    exit(1)
}
