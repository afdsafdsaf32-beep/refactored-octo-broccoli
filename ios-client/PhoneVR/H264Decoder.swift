import Foundation
import VideoToolbox
import CoreMedia

/// Decodes an Annex-B H.264 byte stream (as produced by ffmpeg on the PC
/// side) frame by frame into CVPixelBuffers using hardware VideoToolbox
/// decoding, and hands them back on `onFrame`.
final class H264Decoder {
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var buffer = Data()

    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Fires on VTDecompressionSessionDecodeFrame failures (status, human name) - previously
    /// silently ignored, which made a broken decode path (see the use-after-free this replaced)
    /// indistinguishable from "no data arriving at all" without a debugger attached.
    var onDecodeError: ((OSStatus) -> Void)?
    /// Fires once the VTDecompressionSession is actually created from SPS/PPS - if this never
    /// fires, no amount of incoming video data will ever decode, which narrows down "0 frames
    /// decoded" to a parameter-set problem rather than a networking one.
    var onSessionReady: (() -> Void)?

    /// Feed raw bytes as they arrive from the socket; call repeatedly.
    func push(_ data: Data) {
        buffer.append(data)
        extractNALUnits()
    }

    private func extractNALUnits() {
        // Find start codes (00 00 00 01 or 00 00 01) and split into NAL units.
        var startIndices: [Int] = []
        let bytes = [UInt8](buffer)
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                startIndices.append(i)
                i += 3
            } else if i + 4 < bytes.count, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                startIndices.append(i)
                i += 4
            } else {
                i += 1
            }
        }
        guard startIndices.count > 1 else { return } // need at least one full NAL

        for idx in 0..<(startIndices.count - 1) {
            let start = startIndices[idx]
            let end = startIndices[idx + 1]
            let prefixLen = (bytes[start + 2] == 1) ? 3 : 4
            let nal = Array(bytes[(start + prefixLen)..<end])
            handleNAL(nal)
        }
        // keep the remainder (last, possibly incomplete, NAL) in the buffer
        buffer = Data(bytes[startIndices.last!...])
    }

    private func handleNAL(_ nal: [UInt8]) {
        guard !nal.isEmpty else { return }
        let type = nal[0] & 0x1F
        switch type {
        case 7: sps = nal; tryBuildFormatDescription()
        case 8: pps = nal; tryBuildFormatDescription()
        case 5, 1: decode(nal: nal)
        default: break
        }
    }

    private func tryBuildFormatDescription() {
        guard let sps = sps, let pps = pps else { return }
        let parameterSets: [[UInt8]] = [sps, pps]
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        for set in parameterSets {
            set.withUnsafeBufferPointer { buf in
                pointers.append(buf.baseAddress!)
                sizes.append(buf.count)
            }
        }
        var formatDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: 2,
            parameterSetPointers: &pointers,
            parameterSetSizes: &sizes,
            nalUnitHeaderLength: 4,
            formatDescriptionOut: &formatDesc)
        guard status == noErr, let fd = formatDesc else { return }
        formatDescription = fd
        createSession(with: fd)
    }

    private func createSession(with formatDescription: CMVideoFormatDescription) {
        if let s = session { VTDecompressionSessionInvalidate(s) }
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refCon, _, status, _, imageBuffer, _, _ in
                guard status == noErr, let imageBuffer = imageBuffer else { return }
                let decoder = Unmanaged<H264Decoder>.fromOpaque(refCon!).takeUnretainedValue()
                decoder.onFrame?(imageBuffer)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())

        var newSession: VTDecompressionSession?
        VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: &callback,
            decompressionSessionOut: &newSession)
        session = newSession
        if newSession != nil {
            onSessionReady?()
        }
    }

    private func decode(nal: [UInt8]) {
        guard let session = session, let formatDescription = formatDescription else { return }
        var nalWithLength = [UInt8]()
        var length = UInt32(nal.count).bigEndian
        withUnsafeBytes(of: &length) { nalWithLength.append(contentsOf: $0) }
        nalWithLength.append(contentsOf: nal)

        // Let CMBlockBuffer allocate and own its own copy of the bytes
        // (blockAllocator: kCFAllocatorDefault) rather than pointing at
        // nalWithLength's storage with kCFAllocatorNull - that local array
        // is deallocated as soon as this function returns, and decoding
        // happens asynchronously, so the decoder would read freed memory
        // and silently never produce a frame.
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: nalWithLength.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: nalWithLength.count, flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let bb = blockBuffer else { return }

        status = nalWithLength.withUnsafeBytes { rawBuf in
            CMBlockBufferReplaceDataBytes(with: rawBuf.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: rawBuf.count)
        }
        guard status == kCMBlockBufferNoErr else { return }

        var sampleBuffer: CMSampleBuffer?
        var sampleSizeArray = [nalWithLength.count]
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: bb,
            formatDescription: formatDescription, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSizeArray,
            sampleBufferOut: &sampleBuffer)
        guard let sb = sampleBuffer else { return }

        var flagOut = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb,
                                           flags: [._EnableAsynchronousDecompression],
                                           frameRefcon: nil, infoFlagsOut: &flagOut)
        if decodeStatus != noErr {
            onDecodeError?(decodeStatus)
        }
    }
}
