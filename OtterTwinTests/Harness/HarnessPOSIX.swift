import Foundation
import Darwin

/// Error raised by the harness's own POSIX calls (never by the app under test).
struct HarnessError: Error, CustomStringConvertible {
    let description: String

    static func posix(_ call: String, _ path: String, _ code: Int32 = errno) -> HarnessError {
        HarnessError(description: "\(call)(\(path)) failed: \(String(cString: strerror(code))) (errno \(code))")
    }
}

/// Thin POSIX helpers used by `FixtureTree`, `TreeComparator` and `ScratchVolume`.
/// Paths are passed as Swift strings; Swift keeps their UTF-8 bytes exactly
/// (no Unicode normalization), so NFC and NFD names reach the file system as written.
enum HarnessPOSIX {
    static func makeDirectory(_ path: String, mode: mode_t = 0o755) throws {
        guard mkdir(path, mode) == 0 else { throw HarnessError.posix("mkdir", path) }
    }

    /// Creates a new file (fails if it exists) and writes `size` bytes produced by `fill`.
    static func writeFile(_ path: String, size: Int, mode: mode_t = 0o644, fill: (UnsafeMutableRawBufferPointer, Int) -> Void) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard fd >= 0 else { throw HarnessError.posix("open", path) }
        defer { close(fd) }
        let bufferSize = 1 << 20
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }
        var written = 0
        while written < size {
            let count = min(bufferSize, size - written)
            fill(buffer, count)
            try writeAll(fd, UnsafeRawBufferPointer(rebasing: buffer[0..<count]), path: path)
            written += count
        }
    }

    static func writeFile(_ path: String, data: Data, mode: mode_t = 0o644) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard fd >= 0 else { throw HarnessError.posix("open", path) }
        defer { close(fd) }
        try data.withUnsafeBytes { try writeAll(fd, $0, path: path) }
    }

    private static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer, path: String) throws {
        var offset = 0
        while offset < bytes.count {
            let n = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                throw HarnessError.posix("write", path)
            }
            offset += n
        }
    }

    static func symlink(_ target: String, at path: String) throws {
        guard Darwin.symlink(target, path) == 0 else { throw HarnessError.posix("symlink", path) }
    }

    static func chmod(_ path: String, _ mode: mode_t) throws {
        guard Darwin.chmod(path, mode) == 0 else { throw HarnessError.posix("chmod", path) }
    }

    static func setXattr(_ path: String, name: String, value: Data) throws {
        let result = value.withUnsafeBytes {
            setxattr(path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        guard result == 0 else { throw HarnessError.posix("setxattr", path) }
    }

    /// Sets access and modification time without following a final symlink.
    static func setMtime(_ path: String, _ time: timespec) throws {
        var times = [time, time]
        guard utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw HarnessError.posix("utimensat", path)
        }
    }

    static func lstat(_ path: String) throws -> stat {
        var st = stat()
        guard Darwin.lstat(path, &st) == 0 else { throw HarnessError.posix("lstat", path) }
        return st
    }

    /// Raw entry names of a directory (without `.` and `..`), exactly as stored.
    static func directoryEntries(_ path: String) throws -> [[UInt8]] {
        guard let dir = opendir(path) else { throw HarnessError.posix("opendir", path) }
        defer { closedir(dir) }
        var names: [[UInt8]] = []
        while true {
            errno = 0
            guard let entry = readdir(dir) else {
                if errno != 0 { throw HarnessError.posix("readdir", path) }
                break
            }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { Array($0.prefix(length)) }
            if name == [0x2E] || name == [0x2E, 0x2E] { continue }
            names.append(name)
        }
        return names
    }

    static func readLink(_ path: String) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = buffer.withUnsafeMutableBufferPointer {
            readlink(path, UnsafeMutableRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self), $0.count)
        }
        guard n >= 0 else { throw HarnessError.posix("readlink", path) }
        return Array(buffer.prefix(n))
    }

    /// Extended attributes of `path` (not following symlinks). File systems
    /// without xattr support report none.
    static func xattrs(_ path: String) throws -> [String: Data] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        if size < 0 {
            if errno == ENOTSUP || errno == EPERM { return [:] }
            throw HarnessError.posix("listxattr", path)
        }
        guard size > 0 else { return [:] }
        var nameBuffer = [CChar](repeating: 0, count: size)
        let listed = listxattr(path, &nameBuffer, size, XATTR_NOFOLLOW)
        guard listed >= 0 else { throw HarnessError.posix("listxattr", path) }
        var result: [String: Data] = [:]
        let names = nameBuffer.prefix(listed).split(separator: 0, omittingEmptySubsequences: true)
        for nameChars in names {
            let name = String(decoding: nameChars.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let valueSize = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard valueSize >= 0 else { throw HarnessError.posix("getxattr", path) }
            var value = Data(count: valueSize)
            if valueSize > 0 {
                let read = value.withUnsafeMutableBytes {
                    getxattr(path, name, $0.baseAddress, valueSize, 0, XATTR_NOFOLLOW)
                }
                guard read >= 0 else { throw HarnessError.posix("getxattr", path) }
                value = value.prefix(read)
            }
            result[name] = value
        }
        return result
    }

    /// Reads a regular file through its own descriptor (not following symlinks)
    /// and feeds every block to `consume`.
    static func readFile(_ path: String, consume: (UnsafeRawBufferPointer) -> Void) throws {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw HarnessError.posix("open", path) }
        defer { close(fd) }
        let bufferSize = 1 << 20
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }
        while true {
            let n = read(fd, buffer.baseAddress, bufferSize)
            if n < 0 {
                if errno == EINTR { continue }
                throw HarnessError.posix("read", path)
            }
            if n == 0 { break }
            consume(UnsafeRawBufferPointer(rebasing: buffer[0..<n]))
        }
    }
}
