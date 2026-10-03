// SPDX-License-Identifier: Apache-2.0
// msl-portd: localhost forwarding's relay, like WSL's wslrelay.exe. msld starts
// it when the first port is forwarded and passes it each port's listening
// sockets and, for each connection it accepts, a vsock stream to the guest's
// forwarder (see RelayMessage). It copies the bytes, so msld never carries
// them, and it needs no entitlements.
import Foundation
import MSLCore

RelayHelper { client, vsock, done in
    FramedBridge(vsock: vsock, localIn: client, localOut: client, shutdownOnEOF: true, ownsLocal: true, onClose: done)
}.run()
