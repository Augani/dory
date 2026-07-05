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

/// Streaming LZFSE codec over Apple's Compression framework, which ships in every macOS. The engine
/// uses it to compress its kernel/initfs at build time and decompress them at first launch, so there
/// is no external `zstd` binary or dylib to bundle, link, or go missing.
public enum LZFSE {
    private static let chunk = 1 << 20

    public static func compress(source: String, destination: String) throws {
        try transform(source: source, destination: destination, operation: COMPRESSION_STREAM_ENCODE)
    }

    public static func decompress(source: String, destination: String) throws {
        try transform(source: source, destination: destination, operation: COMPRESSION_STREAM_DECODE)
    }

    private static func transform(source: String, destination: String, operation: compression_stream_operation) throws {
        guard let input = InputStream(fileAtPath: source) else { throw LZFSEError.openInput(source) }
        guard let output = OutputStream(toFileAtPath: destination, append: false) else { throw LZFSEError.openOutput(destination) }
        input.open()
        output.open()
        defer { input.close(); output.close() }

        let source = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        let sink = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { source.deallocate(); sink.deallocate() }

        var stream = compression_stream(dst_ptr: sink, dst_size: chunk, src_ptr: UnsafePointer(source), src_size: 0, state: nil)
        guard compression_stream_init(&stream, operation, COMPRESSION_LZFSE) == COMPRESSION_STATUS_OK else {
            throw LZFSEError.streamInit
        }
        defer { compression_stream_destroy(&stream) }

        stream.src_size = 0
        stream.dst_ptr = sink
        stream.dst_size = chunk
        var inputExhausted = false

        while true {
            if stream.src_size == 0, !inputExhausted {
                let read = input.read(source, maxLength: chunk)
                if read < 0 { throw LZFSEError.read }
                if read == 0 { inputExhausted = true }
                stream.src_ptr = UnsafePointer(source)
                stream.src_size = read
            }

            let flags = inputExhausted ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(&stream, flags)
            guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                throw LZFSEError.process
            }

            let produced = chunk - stream.dst_size
            if produced > 0 {
                var offset = 0
                while offset < produced {
                    let written = output.write(sink + offset, maxLength: produced - offset)
                    if written <= 0 { throw LZFSEError.write }
                    offset += written
                }
                stream.dst_ptr = sink
                stream.dst_size = chunk
            }

            if status == COMPRESSION_STATUS_END { return }
        }
    }
}
