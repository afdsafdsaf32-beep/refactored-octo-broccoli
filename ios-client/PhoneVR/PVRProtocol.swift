import Foundation

/// Wire protocol reverse-engineered from the open-source PhoneVR OpenVR
/// driver (github.com/PhoneVR-Developers/PhoneVR, code/common/src/PVRSocketUtils.*
/// and code/windows/PhoneVR/PhoneVR/{driver,PVRSockets}.cpp). Implementing this
/// lets our iOS app pair directly with their existing free/open-source SteamVR
/// driver, instead of writing a driver from scratch.
///
/// Default ports (from PVRFileManager.h):
///   - 33333 pairing (UDP, phone -> PC) then control channel (TCP, PC -> phone)
///   - 15243 video   (TCP, phone connects out to PC)
///   - 51423 pose    (UDP, phone -> PC, continuous)
enum PVRPort {
    static let pairing: UInt16 = 33333
    static let video: UInt16 = 15243
    static let pose: UInt16 = 51423
}

/// PVR_MSG enum, PVRSocketUtils.h. Raw byte value is sent on the wire.
enum PVRMsg: UInt8 {
    case pairHMD = 0
    case pairPhoneCtrl = 1
    case pairHmdCtrls = 2
    case pairAccept = 3
    case additionalData = 4
    case headerNALs = 5
    case disconnect = 6
}

enum PVRWire {
    /// UDP discovery packet the phone sends to the PC's pairing port to
    /// announce itself: "pvr" + msgType(1) + version(4, native/little-endian
    /// uint32 = rel<<24 | sub<<16 | patch). The server only checks
    /// `clientVersion >= serverVersion`, so 0xFFFFFFFF always satisfies it
    /// regardless of the exact PVR_BINVERSION the PC driver was built with.
    static func pairingPacket(msg: PVRMsg) -> Data {
        var data = Data([0x70, 0x76, 0x72, msg.rawValue])   // "pvr" + type
        var version: UInt32 = 0xFFFF_FFFF
        withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
        return data
    }

    /// TCP control-channel framing (PVRSocketUtils.cpp TCPTalker::send):
    /// "pvr" + msgType(1) + payloadLength(2, little-endian) + payload.
    static func frame(msg: PVRMsg, payload: Data = Data()) -> Data {
        var data = Data([0x70, 0x76, 0x72, msg.rawValue])
        var len = UInt16(payload.count).littleEndian
        withUnsafeBytes(of: &len) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    /// ADDITIONAL_DATA payload the phone reports back after PAIR_ACCEPT:
    /// uint16 width, uint16 height (render target size, both eyes),
    /// float[4] raw projection (left, bottom, right, top - tangent of the
    /// half-angles, see driver.cpp GetProjectionRaw), float ipd (meters).
    static func additionalDataPayload(width: UInt16, height: UInt16,
                                       left: Float, bottom: Float, right: Float, top: Float,
                                       ipdMeters: Float) -> Data {
        var data = Data()
        var w = width.littleEndian, h = height.littleEndian
        withUnsafeBytes(of: &w) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &h) { data.append(contentsOf: $0) }
        for var f in [left, bottom, right, top] {
            withUnsafeBytes(of: &f) { data.append(contentsOf: $0) }
        }
        var ipd = ipdMeters
        withUnsafeBytes(of: &ipd) { data.append(contentsOf: $0) }
        return data
    }

    /// POSE_PORT UDP packet (PVRSockets.cpp PVRStartReceiveData): float
    /// quat[4] w,x,y,z (16 bytes) + float acc[3] (12 bytes, unused by the
    /// driver but must be present to make pktSz > 24) + int64 timestamp in
    /// nanoseconds (matched against the PC's own steady clock to compute a
    /// pose time offset - exact cross-device sync isn't critical, it only
    /// nudges reprojection timing).
    static func posePacket(qw: Float, qx: Float, qy: Float, qz: Float) -> Data {
        var data = Data()
        for var f in [qw, qx, qy, qz, Float(0), Float(0), Float(0)] {
            withUnsafeBytes(of: &f) { data.append(contentsOf: $0) }
        }
        var ns = Int64(DispatchTime.now().uptimeNanoseconds)
        withUnsafeBytes(of: &ns) { data.append(contentsOf: $0) }
        return data
    }
}

/// Incrementally parses "pvr"-prefixed frames out of a TCP byte stream,
/// mirroring TCPTalker's resynchronizing parser: it scans for the next "pvr"
/// marker rather than assuming perfect alignment, so a partial read never
/// desyncs the stream permanently.
final class PVRFrameParser {
    private var buffer = Data()
    var onFrame: ((PVRMsg, Data) -> Void)?

    func push(_ data: Data) {
        buffer.append(data)
        while true {
            guard let markerRange = buffer.range(of: Data([0x70, 0x76, 0x72])) else { return }
            let headerEnd = markerRange.lowerBound + 6   // "pvr" + type + len(2)
            guard buffer.count >= headerEnd else { return }
            let typeByte = buffer[markerRange.lowerBound + 3]
            let lenLo = UInt16(buffer[markerRange.lowerBound + 4])
            let lenHi = UInt16(buffer[markerRange.lowerBound + 5])
            let payloadLen = Int(lenLo | (lenHi << 8))
            let payloadEnd = headerEnd + payloadLen
            guard buffer.count >= payloadEnd else { return }

            if let msg = PVRMsg(rawValue: typeByte) {
                onFrame?(msg, buffer.subdata(in: headerEnd..<payloadEnd))
            }
            buffer.removeSubrange(buffer.startIndex..<payloadEnd)
        }
    }
}
