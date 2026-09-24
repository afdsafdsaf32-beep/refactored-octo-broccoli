import Foundation

/// finnvoor/Transcoding's VideoDecoderAnnexBAdaptor splits incoming Annex-B
/// data on a fixed 4-byte start code (00 00 00 01) only. x264 (which the PC
/// driver uses, with b_annexb=1) commonly only emits a 4-byte start code
/// before the first NAL unit in an access unit and 3-byte start codes
/// (00 00 01) between the rest - a very ordinary Annex-B encoder behavior,
/// but one that leaves multiple NALs (e.g. SPS+PPS+IDR) glued together as
/// far as a 4-byte-only splitter is concerned, so it never recognizes the
/// slice NAL as its own unit and no frame ever decodes.
///
/// Re-frame the stream so every NAL gets its own clean 4-byte start code
/// before handing it to the adaptor.
enum AnnexBNormalizer {
    static func normalize(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var starts: [(offset: Int, prefixLen: Int)] = []
        // Scanning for the 3-byte pattern [0,0,1] alone is enough to find
        // both kinds of marker: for a real 4-byte marker (00 00 00 01) the
        // pattern is simply found one byte later than its start, and
        // offset+3 still lands exactly one past the full marker either way.
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                starts.append((i, 3))
                i += 3
            } else {
                i += 1
            }
        }
        guard !starts.isEmpty else { return data }

        var out = Data()
        let fourByteStart = Data([0, 0, 0, 1])
        for (idx, start) in starts.enumerated() {
            let nalBegin = start.offset + start.prefixLen
            let nalEnd = idx + 1 < starts.count ? starts[idx + 1].offset : bytes.count
            guard nalBegin < nalEnd else { continue }
            out.append(fourByteStart)
            out.append(contentsOf: bytes[nalBegin..<nalEnd])
        }
        return out
    }
}
