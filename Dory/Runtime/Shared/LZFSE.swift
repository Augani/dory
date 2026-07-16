import Compression
import Foundation

nonisolated enum LZFSEError: Error {
    case openInput
    case openOutput
    case streamInit
    case read
    case write
    case process
}

/// In-process LZFSE decompression over Apple's Compression framework (present in every macOS), so
/// the app extracts its bundled engine kernel/initfs at first launch with no external `zstd` binary
/// or dylib to bundle, link, or go missing.
nonisolated enum LZFSE {
    private static let chunk = 1 << 20

    static func decompress(source: String, destination: String) throws {
        guard let input = InputStream(fileAtPath: source) else { throw LZFSEError.openInput }
        guard let output = OutputStream(toFileAtPath: destination, append: false) else { throw LZFSEError.openOutput }
        input.open()
        output.open()
        defer { input.close(); output.close() }

        let src = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { src.deallocate(); dst.deallocate() }

        var stream = compression_stream(dst_ptr: dst, dst_size: chunk, src_ptr: UnsafePointer(src), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE) == COMPRESSION_STATUS_OK else {
            throw LZFSEError.streamInit
        }
        defer { compression_stream_destroy(&stream) }

        stream.src_size = 0
        stream.dst_ptr = dst
        stream.dst_size = chunk
        var exhausted = false

        while true {
            if stream.src_size == 0, !exhausted {
                let read = input.read(src, maxLength: chunk)
                if read < 0 { throw LZFSEError.read }
                if read == 0 { exhausted = true }
                stream.src_ptr = UnsafePointer(src)
                stream.src_size = read
            }

            let flags = exhausted ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(&stream, flags)
            guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                throw LZFSEError.process
            }

            let produced = chunk - stream.dst_size
            if produced > 0 {
                var offset = 0
                while offset < produced {
                    let written = output.write(dst + offset, maxLength: produced - offset)
                    if written <= 0 { throw LZFSEError.write }
                    offset += written
                }
                stream.dst_ptr = dst
                stream.dst_size = chunk
            }

            if status == COMPRESSION_STATUS_END { return }
        }
    }
}
