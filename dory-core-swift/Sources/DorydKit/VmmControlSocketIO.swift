import Darwin
import Foundation

/// EOF-delimited control frames with one monotonic deadline per transfer. A peer that keeps
/// supplying partial data cannot extend the request deadline by resetting a socket timeout.
public enum VmmControlSocketIO {
    public static let maximumMessageBytes = 1_048_576

    public static func readRequestData(
        from fd: Int32, timeoutMilliseconds: UInt32 = 5_000
    ) throws -> Data {
        try makeNonblocking(fd)
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else {
            throw VmmControlError.syscall("getpeereid", errno)
        }
        guard uid == geteuid() else {
            throw VmmControlError.rejected("control peer must have the helper's user identity")
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMilliseconds) * 1_000_000
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            try wait(fd, events: Int16(POLLIN), deadline: deadline)
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw VmmControlError.syscall("recv", errno)
            }
            if count == 0 { break }
            guard result.count + count <= maximumMessageBytes else {
                throw VmmControlError.rejected("control request exceeded 1 MiB")
            }
            result.append(buffer, count: count)
        }
        guard !result.isEmpty else { throw VmmControlError.rejected("empty control request") }
        return result
    }

    public static func writeResponseData(
        _ data: Data, to fd: Int32, timeoutMilliseconds: UInt32 = 5_000
    ) throws {
        try makeNonblocking(fd)
        guard data.count <= maximumMessageBytes else {
            throw VmmControlError.rejected("control response exceeded 1 MiB")
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMilliseconds) * 1_000_000
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(fd, events: Int16(POLLOUT), deadline: deadline)
                let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset,
                    MSG_NOSIGNAL)
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    throw VmmControlError.syscall("send", errno)
                }
                guard count > 0 else { throw VmmControlError.syscall("send", EPIPE) }
                offset += count
            }
        }
    }

    // These connected descriptors are owned by the control worker. Set O_NONBLOCK on the
    // descriptor: a per-call flag alone does not reliably bound Darwin Unix-stream sends.
    private static func makeNonblocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { throw VmmControlError.syscall("fcntl(F_GETFL)", errno) }
        guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw VmmControlError.syscall("fcntl(F_SETFL)", errno)
        }
    }

    private static func wait(_ fd: Int32, events: Int16, deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw VmmControlError.syscall("control deadline", ETIMEDOUT) }
            let milliseconds = min(UInt64(Int32.max), (deadline - now + 999_999) / 1_000_000)
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(milliseconds))
            if result < 0 {
                if errno == EINTR { continue }
                throw VmmControlError.syscall("poll", errno)
            }
            if result == 0 { continue }
            if descriptor.revents & Int16(POLLNVAL) != 0 {
                throw VmmControlError.syscall("poll", EBADF)
            }
            if descriptor.revents & Int16(POLLERR) != 0 {
                throw VmmControlError.syscall("poll", ECONNRESET)
            }
            // HUP can accompany unread request bytes. recv must drain them before seeing EOF.
            if descriptor.revents & (events | Int16(POLLHUP)) != 0 { return }
        }
    }
}
