// SPDX-License-Identifier: MIT

import Foundation

public enum NTFSError: Error, Equatable, CustomStringConvertible {
    case invalidDeviceGeometry(String)
    case outOfBounds(offset: UInt64, length: Int)
    case invalidBootSector(String)
    case invalidFileRecord(String)
    case invalidAttribute(String)
    case invalidRunlist(String)
    case readOnly(String)
    case shortRead(expected: Int, actual: Int)
    case shortWrite(expected: Int, actual: Int)
    case writeVerificationFailed(offset: UInt64, length: Int)

    public var description: String {
        switch self {
        case let .invalidDeviceGeometry(message): return "Invalid block device geometry: \(message)"
        case let .outOfBounds(offset, length): return "I/O outside device at \(offset), length \(length)"
        case let .invalidBootSector(message): return "Invalid NTFS boot sector: \(message)"
        case let .invalidFileRecord(message): return "Invalid NTFS file record: \(message)"
        case let .invalidAttribute(message): return "Invalid NTFS attribute: \(message)"
        case let .invalidRunlist(message): return "Invalid NTFS runlist: \(message)"
        case let .readOnly(message): return "NTFS write refused: \(message)"
        case let .shortRead(expected, actual): return "Short read: expected \(expected), got \(actual)"
        case let .shortWrite(expected, actual): return "Short write: expected \(expected), got \(actual)"
        case let .writeVerificationFailed(offset, length):
            return "Write verification failed at \(offset), length \(length)"
        }
    }
}
