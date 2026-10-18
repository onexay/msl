// SPDX-License-Identifier: Apache-2.0
import CMSLSupport
import Foundation
import MSLCore
import Testing
@testable import MSLService

@Suite struct ClockMonitorTests {
    @Test func waitsForWakeCompletion() {
        var changes = 0
        let monitor = ClockMonitor { changes += 1 }
        monitor.powerChanged(MSLHostWillWake, argument: nil)
        monitor.powerChanged(MSLHostWillNotSleep, argument: nil)
        #expect(changes == 0)
        monitor.powerChanged(MSLHostDidWake, argument: nil)
        #expect(changes == 1)
    }

    @Test func receivesClockChangesWithoutAMainRunLoop() throws {
        let delivered = DispatchSemaphore(value: 0)
        // Only the OS can post Apple's protected clock notification.
        let name = "dev.msl.tests.clock.\(UUID().uuidString)"
        let monitor = ClockMonitor(notificationName: name) { delivered.signal() }
        monitor.start()
        let notify = Process()
        notify.executableURL = URL(fileURLWithPath: "/usr/bin/notifyutil")
        notify.arguments = ["-p", name]
        try notify.run()
        notify.waitUntilExit()
        #expect(notify.terminationStatus == 0)
        #expect(delivered.wait(timeout: .now() + 3) == .success)
        withExtendedLifetime(monitor) {}
    }

    @Test func clockEventsDoNotBootAStoppedVM() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = Service(paths: Paths(environment: ["MSL_HOME": root.path, "MSL_VIEW_DIR": root.appendingPathComponent("view").path]))
        service.syncClockIfRunning()
        #expect(!service.vm.isRunning)
    }
}
