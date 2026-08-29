import Compression
import Foundation

public enum LZFSEError: Error, CustomStringConvertible {
    case openInput(String)
    case openOutput(String)
    case streamInit
    case read
    case write
    case process

    public var description: String {
        switch self {
        case .openInput(let path): "cannot open input \(path)"
        case .openOutput(let path): "cannot open output \(path)"
        case .streamInit: "compression_stream_init failed"
        case .read: "read failed"
        case .write: "write failed"
        case .process: "compression_stream_process failed"
        }
    }
}

/// Streaming LZFSE codec over Apple's Compression framework. Release assembly uses this exact
/// implementation to compress guest payloads, while the installed app uses the same format when it
/// expands those payloads on first launch. Keeping the codec in the signed runner avoids an ambient
/// Homebrew or system-tool dependency in the public release path.
public enum LZFSE {
    private static let chunk = 1 << 20

    public static func compress(source: String, destination: String) throws {
        try transform(source: source, destination: destination, operation: COMPRESSION_STREAM_ENCODE)
    }

    public static func decompress(source: String, destination: String) throws {
        try transform(source: source, destination: destination, operation: COMPRESSION_STREAM_DECODE)
    }

    private static func transform(
        source: String,
        destination: String,
        operation: compression_stream_operation
    ) throws {
        guard FileManager.default.isReadableFile(atPath: source),
              let input = InputStream(fileAtPath: source) else {
            throw LZFSEError.openInput(source)
        }
        guard let output = OutputStream(toFileAtPath: destination, append: false) else {
            throw LZFSEError.openOutput(destination)
        }
        input.open()
        output.open()
        defer {
            input.close()
            output.close()
        }

        let sourceBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer {
            sourceBuffer.deallocate()
            destinationBuffer.deallocate()
        }

        var stream = compression_stream(
            dst_ptr: destinationBuffer,
            dst_size: chunk,
            src_ptr: UnsafePointer(sourceBuffer),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, operation, COMPRESSION_LZFSE)
            == COMPRESSION_STATUS_OK else {
            throw LZFSEError.streamInit
        }
        defer { compression_stream_destroy(&stream) }

        // compression_stream_init resets the caller-owned source/destination fields.
        stream.src_ptr = UnsafePointer(sourceBuffer)
        stream.src_size = 0
        stream.dst_ptr = destinationBuffer
        stream.dst_size = chunk

        var inputExhausted = false
        while true {
            if stream.src_size == 0, !inputExhausted {
                let read = input.read(sourceBuffer, maxLength: chunk)
                if read < 0 { throw LZFSEError.read }
                if read == 0 { inputExhausted = true }
                stream.src_ptr = UnsafePointer(sourceBuffer)
                stream.src_size = read
            }

            let flags = inputExhausted ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(&stream, flags)
            guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                throw LZFSEError.process
            }

            // Compression.framework owns the partially filled destination buffer while it returns
            // OK. Publish and reset that buffer only once it is full, or publish the final partial
            // buffer when the stream ends. Resetting a partially filled buffer between OK calls
            // produces a malformed stream once a payload crosses the input chunk boundary.
            let produced: Int
            switch status {
            case COMPRESSION_STATUS_OK where stream.dst_size == 0:
                produced = chunk
            case COMPRESSION_STATUS_END:
                produced = chunk - stream.dst_size
            default:
                produced = 0
            }
            var offset = 0
            while offset < produced {
                let written = output.write(
                    destinationBuffer + offset,
                    maxLength: produced - offset
                )
                if written <= 0 { throw LZFSEError.write }
                offset += written
            }
            if status == COMPRESSION_STATUS_OK, stream.dst_size == 0 {
                stream.dst_ptr = destinationBuffer
                stream.dst_size = chunk
            }

            if status == COMPRESSION_STATUS_END { return }
        }
    }
}
