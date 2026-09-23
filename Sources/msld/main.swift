import Foundation
// msld: the MSL service (wslservice.exe equivalent). Started on demand by msl.
import MSLService

do {
    try Service().serve()
} catch {
    FileHandle.standardError.write("msld: \(error)\n".data(using: .utf8)!)
    exit(1)
}
