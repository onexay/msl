// SPDX-License-Identifier: Apache-2.0
import CMSLSupport
import Foundation
import IOKit.pwr_mgt
import IOKit

/// Power notifications use their own queue: an RPC must never delay acknowledging sleep.
final class ClockMonitor {
    private let queue = DispatchQueue(label: "msl.clock.events")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var connection: io_connect_t = 0
    private var clockToken: Int32 = -1
    private let changed: () -> Void
    private let notificationName: String

    init(notificationName: String = "com.apple.system.clock_set", changed: @escaping () -> Void) {
        self.notificationName = notificationName
        self.changed = changed
        queue.setSpecific(key: queueKey, value: true)
    }

    func start() {
        connection = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { context, _, message, argument in
            guard let context else { return }
            let monitor = Unmanaged<ClockMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.powerChanged(message, argument: argument)
        }, &notifier)
        if connection != 0, let port {
            IONotificationPortSetDispatchQueue(port, queue)
        } else {
            log("clock: could not subscribe to host wake notifications")
        }
        let result = msl_observe_clock(notificationName, &clockToken, queue) { [weak self] in self?.changed() }
        if result != 0 {
            clockToken = -1
            log("clock: could not subscribe to host clock changes (\(result))")
        }
    }

    func powerChanged(_ message: UInt32, argument: UnsafeMutableRawPointer?) {
        switch message {
        case MSLHostCanSleep, MSLHostWillSleep:
            IOAllowPowerChange(connection, Int(bitPattern: argument))
        case MSLHostDidWake:
            changed()
        default:
            break
        }
    }

    private func stop() {
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if let port { IONotificationPortDestroy(port) }
        if connection != 0 { IOServiceClose(connection) }
        if clockToken >= 0 { msl_cancel_clock_observer(clockToken) }
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) == true { stop() }
        else { queue.sync { stop() } }
    }
}
