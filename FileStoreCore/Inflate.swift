import Foundation
import zlib

/// Inflating untrusted data into a buffer of the size it declares, never more (zlib from the SDK).
enum Inflate {
    /// `input` inflated into exactly `expectedSize` bytes, or nil when it is not a whole, valid
    /// stream of exactly that size with nothing after it. `raw` is a zip entry's bare deflate data;
    /// otherwise zlib's header and Adler-32 check are expected, as a xar archive stores them.
    static func inflate(_ input: [UInt8], expectedSize: Int, raw: Bool) -> [UInt8]? {
        guard expectedSize >= 0, let size = UInt32(exactly: expectedSize + 1), let inputSize = UInt32(exactly: input.count) else {
            return nil
        }
        var stream = z_stream()
        guard inflateInit2_(&stream, raw ? -MAX_WBITS : MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return nil
        }
        defer { inflateEnd(&stream) }
        // One byte more than declared, so a stream that would write more is caught.
        var output = [UInt8](repeating: 0, count: expectedSize + 1)
        var input = input
        let status = input.withUnsafeMutableBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                stream.next_in = source.baseAddress
                stream.avail_in = inputSize
                stream.next_out = destination.baseAddress
                stream.avail_out = size
                return zlib.inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.total_out == UInt(expectedSize), stream.avail_in == 0 else {
            return nil
        }
        output.removeLast()
        return output
    }

    /// The CRC-32 of `bytes`, as zip records it.
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBufferPointer { buffer in
            UInt32(zlib.crc32(0, buffer.baseAddress, UInt32(buffer.count)))
        }
    }
}

/// Parses XML from an installer, which may be hostile, with `XMLParser`: only UTF-8, no NUL, and no
/// document type or entity declaration, so no entity can expand and nothing outside is fetched.
enum UntrustedXML {
    static func parse(_ bytes: [UInt8], with delegate: any XMLParserDelegate) -> Bool {
        let utf16BigEndian: [UInt8] = [0xFE, 0xFF]
        let utf16LittleEndian: [UInt8] = [0xFF, 0xFE]
        guard !bytes.contains(0),
              !bytes.starts(with: utf16BigEndian), !bytes.starts(with: utf16LittleEndian),
              let text = String(validating: bytes, as: UTF8.self),
              !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else {
            return false
        }
        let parser = XMLParser(data: Data(bytes))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        return parser.parse()
    }
}
