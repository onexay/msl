// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import MSLCore
import Virtualization

/// Online install support: manifest fetch and cached, verified `.wsl` downloads.
enum Online {
    static var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("msl/downloads", isDirectory: true)
    }

    static func manifest() -> Manifest {
        let url = Manifest.url
        do {
            let data = url.isFileURL ? try Data(contentsOf: url) : try fetch(url)
            return try Manifest.parse(data)
        } catch {
            fail("Failed to fetch the distribution list from '\(url.absoluteString)'. \(error.localizedDescription)", ErrorCode.service)
        }
    }

    static func fetch(_ url: URL) throws -> Data {
        let sem = DispatchSemaphore(value: 0)
        let box = Box<Result<Data, Error>>()
        URLSession.shared.dataTask(with: url) { data, resp, err in
            if let err { box.value = .failure(err) }
            else if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                box.value = .failure(URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]))
            } else { box.value = .success(data ?? Data()) }
            sem.signal()
        }.resume()
        sem.wait()
        return try box.value!.get()
    }

    static var rosettaInstalled: Bool { VZLinuxRosettaDirectoryShare.availability == .installed }

    /// Download (or reuse from cache) and verify; returns the local file.
    /// Prefers the arm64 image; x86_64-only distributions run through Rosetta.
    static func download(_ entry: Manifest.Entry) -> URL {
        if let refusal = Manifest.installRefusal(entry, rosetta: rosettaInstalled) {
            fail(refusal, ErrorCode.unsupported)
        }
        let dl = (entry.Arm64Url ?? entry.Amd64Url)!
        guard let expected = manifestSHA256(dl.Sha256) else {
            fail("The distribution list has an invalid SHA-256 for '\(entry.Name)'.", ErrorCode.service)
        }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let dest = cacheDir.appendingPathComponent("\(expected).wsl")
        if FileManager.default.fileExists(atPath: dest.path), sha256(dest) == expected {
            return dest
        }
        out("Downloading: \(entry.FriendlyName)")
        guard let url = URL(string: dl.Url) else { fail("Invalid URL: \(dl.Url)", ErrorCode.invalidArgument) }
        let progress = Progress(tty: isatty(2) != 0)
        let delegate = DownloadDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        session.downloadTask(with: url).resume()
        delegate.done.wait()
        progress.finish()
        switch delegate.result {
        case .success(let tmp)?:
            guard sha256(tmp) == expected else {
                try? FileManager.default.removeItem(at: tmp)
                fail("The downloaded file's SHA-256 does not match the distribution list.", ErrorCode.importFailed)
            }
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.moveItem(at: tmp, to: dest) } catch { fail("\(error)", ErrorCode.service) }
            return dest
        case .failure(let e)?:
            fail("Download failed: \(e.localizedDescription)", ErrorCode.service)
        case nil:
            fail("Download failed.", ErrorCode.service)
        }
    }

    /// Microsoft's distro list may prefix SHA-256 values with `0x`.
    /// Normalize that notation before comparing it with CryptoKit's hex digest.
    static func manifestSHA256(_ value: String) -> String? {
        let digest = value.lowercased()
        let hex = digest.hasPrefix("0x") ? String(digest.dropFirst(2)) : digest
        guard hex.utf8.count == 64,
              hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return hex
    }

    /// Download a URL (file:// too) to a temp file, verifying its SHA-256.
    static func downloadVerified(_ url: URL, sha256 want: String, label: String) -> URL {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("msl-dl-\(UUID().uuidString)")
        if url.isFileURL {
            do { try FileManager.default.copyItem(at: url, to: dest) } catch { fail("Download failed: \(error.localizedDescription)", ErrorCode.service) }
        } else {
            out("Downloading: \(label)")
            let progress = Progress(tty: isatty(2) != 0)
            let delegate = DownloadDelegate(progress: progress)
            URLSession(configuration: .default, delegate: delegate, delegateQueue: nil).downloadTask(with: url).resume()
            delegate.done.wait()
            progress.finish()
            guard case .success(let tmp)? = delegate.result else { fail("Download failed.", ErrorCode.service) }
            try? FileManager.default.moveItem(at: tmp, to: dest)
        }
        guard sha256(dest) == want.lowercased() else {
            try? FileManager.default.removeItem(at: dest)
            fail("The downloaded file's SHA-256 does not match the release manifest.", ErrorCode.importFailed)
        }
        return dest
    }

    static func sha256(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

final class Box<T>: @unchecked Sendable { var value: T? }

final class Progress: @unchecked Sendable {
    let tty: Bool
    private var last = -1
    init(tty: Bool) { self.tty = tty }
    func update(_ done: Int64, _ total: Int64) {
        guard tty, total > 0 else { return }
        let pct = Int(Double(done) / Double(total) * 1000)
        guard pct != last else { return }
        last = pct
        let width = 40, filled = width * pct / 1000
        let bar = String(repeating: "=", count: filled) + String(repeating: " ", count: width - filled)
        write(2, String(format: "\r[%@] %5.1f%%", bar, Double(pct) / 10))
    }
    func finish() { if tty && last >= 0 { write(2, "\n") } }
}

final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: Progress
    let done = DispatchSemaphore(value: 0)
    var result: Result<URL, Error>?
    init(progress: Progress) { self.progress = progress }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite t: Int64) {
        progress.update(w, t)
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this returns: move it somewhere we own.
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wsl")
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            }
            try FileManager.default.moveItem(at: location, to: keep)
            result = .success(keep)
        } catch { result = .failure(error) }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { result = .failure(error) }
        done.signal()
    }
}
