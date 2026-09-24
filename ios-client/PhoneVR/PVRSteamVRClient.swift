import Foundation
import Network
import CoreMotion
import CoreImage
import CoreGraphics

/// Drives the full PhoneVR/SteamVR handshake (see PVRProtocol.swift) so this
/// app can act as the "HMD" side of the open-source PhoneVR OpenVR driver:
///
///  1. Send a UDP PAIR_HMD announce to the PC's pairing port (33333).
///  2. Accept the PC's incoming TCP connection on that same port (the PC
///     driver connects OUT to the phone here - we must be listening).
///  3. Receive PAIR_ACCEPT, reply with ADDITIONAL_DATA (render size, FOV, IPD).
///  4. Receive HEADER_NALS (SPS/PPS) and feed them to the H.264 decoder.
///  5. Open a TCP connection out to the PC's video port (15243) and decode
///     the per-frame stream (64-byte header + Annex-B NAL payload).
///  6. Continuously stream head orientation over UDP to the pose port (51423).
final class PVRSteamVRClient: ObservableObject {
    @Published var statusText = "Idle"
    @Published var frame: CGImage?
    @Published var framesDecoded = 0
    @Published var lastDecodeError: String?

    private let decoder = H264Decoder()
    private let ciContext = CIContext()
    private let motionManager = CMMotionManager()

    private var pcHost = ""
    private var pairingListener: NWListener?
    private var controlConnection: NWConnection?
    private var videoConnection: NWConnection?
    private var poseConnection: NWConnection?
    private let frameParser = PVRFrameParser()
    private var announceTimer: Timer?
    private var paired = false

    private let queue = DispatchQueue(label: "phonevr.pvr")

    // Render target size reported to the PC. Any 2:1-per-eye size works;
    // the PC driver just uses it to size its render texture.
    private let renderWidth: UInt16 = 1920
    private let renderHeight: UInt16 = 1080

    func start(pcHost: String) {
        stop()   // tear down any listener/connections left over from a previous attempt first -
                 // otherwise NWListener silently fails to rebind port 33333 (already in use)
        self.pcHost = pcHost
        paired = false
        framesDecoded = 0
        lastDecodeError = nil
        statusText = "Announcing to \(pcHost)..."

        decoder.onFrame = { [weak self] pixelBuffer in
            // The PC captures the SteamVR compositor's Direct3D texture
            // (top-left origin, row 0 = top) and feeds it to x264 as raw
            // frames; CoreImage's CVPixelBuffer coordinate space is
            // bottom-left origin. That mismatch alone shows up as a 180°
            // rotation ("mirrored and upside down" looks the same as a
            // rotation to an untrained eye). Correct for it here since we
            // can't easily patch/recompile the closed legacy PC driver.
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(.down)
            guard let cg = self?.ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
            DispatchQueue.main.async {
                self?.frame = cg
                self?.framesDecoded += 1
            }
        }
        decoder.onDecodeError = { [weak self] status in
            DispatchQueue.main.async { self?.lastDecodeError = "VTDecompressionSessionDecodeFrame failed: \(status)" }
        }

        frameParser.onFrame = { [weak self] msg, payload in
            self?.handleControlFrame(msg, payload)
        }

        startPairingListener()
        startMotion()

        // The PC driver's pairing listener only exists once SteamVR has
        // loaded it, which may well be after you've pressed Connect here
        // (README even recommends opening this app first). A one-shot UDP
        // announce would just vanish into that gap, so keep resending until
        // the control channel actually comes up - the Android client does
        // this every 10ms when given an explicit IP (PVRSockets.cpp
        // PVRAnnounceToAllInterfaces); we use 300ms, aggressive enough to
        // reliably land inside the driver's ~5s pairing window without
        // spamming the network.
        sendPairingAnnounce()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self = self, !self.paired else { return }
            self.sendPairingAnnounce()
        }
        RunLoop.main.add(timer, forMode: .common)
        announceTimer = timer
    }

    func stop() {
        announceTimer?.invalidate()
        announceTimer = nil
        pairingListener?.cancel()
        pairingListener = nil
        controlConnection?.cancel()
        controlConnection = nil
        videoConnection?.cancel()
        videoConnection = nil
        poseConnection?.cancel()
        poseConnection = nil
        motionManager.stopDeviceMotionUpdates()
        statusText = "Idle"
    }

    // MARK: - Step 1+2: announce, then accept the PC's control connection

    private func startPairingListener() {
        let params = NWParameters.tcp
        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: PVRPort.pairing)!) else {
            statusText = "Failed to listen on pairing port"
            return
        }
        pairingListener = listener
        listener.newConnectionHandler = { [weak self] conn in
            self?.acceptControlConnection(conn)
        }
        listener.start(queue: queue)
    }

    private func acceptControlConnection(_ conn: NWConnection) {
        controlConnection = conn
        conn.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                DispatchQueue.main.async { self?.statusText = "Control channel connected" }
            }
        }
        conn.start(queue: queue)
        receiveControlLoop()
    }

    private func receiveControlLoop() {
        controlConnection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.frameParser.push(data)
            }
            if error == nil && !isComplete {
                self.receiveControlLoop()
            }
        }
    }

    private func sendPairingAnnounce() {
        let params = NWParameters.udp
        let conn = NWConnection(host: NWEndpoint.Host(pcHost), port: NWEndpoint.Port(rawValue: PVRPort.pairing)!, using: params)
        conn.start(queue: queue)
        conn.send(content: PVRWire.pairingPacket(msg: .pairHMD), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    // MARK: - Step 3+4: handshake payloads over the control channel

    private func handleControlFrame(_ msg: PVRMsg, _ payload: Data) {
        switch msg {
        case .pairAccept:
            paired = true
            announceTimer?.invalidate()
            announceTimer = nil
            DispatchQueue.main.async { self.statusText = "Paired - sending display config" }
            sendAdditionalData()
            connectVideo()
            connectPose()
        case .headerNALs:
            decoder.push(payload)   // contains SPS+PPS Annex-B NALs
            DispatchQueue.main.async { self.statusText = "Got SPS/PPS (\(payload.count) bytes), connecting video..." }
        case .disconnect:
            DispatchQueue.main.async { self.statusText = "PC disconnected" }
            stop()
        default:
            break
        }
    }

    private func sendAdditionalData() {
        // ~100 degree symmetric FOV as a safe Cardboard-style default;
        // tune per lens if you measure the actual phone-holder optics.
        let payload = PVRWire.additionalDataPayload(
            width: renderWidth, height: renderHeight,
            left: -1.19, bottom: -1.19, right: 1.19, top: 1.19,
            ipdMeters: 0.063)
        controlConnection?.send(content: PVRWire.frame(msg: .additionalData, payload: payload),
                                 completion: .contentProcessed { _ in })
    }

    // MARK: - Step 5: video stream (phone connects out to the PC)

    private func connectVideo() {
        let conn = NWConnection(host: NWEndpoint.Host(pcHost), port: NWEndpoint.Port(rawValue: PVRPort.video)!, using: .tcp)
        videoConnection = conn
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                DispatchQueue.main.async { self?.statusText = "Video connected, waiting for frames..." }
            case .failed(let error):
                DispatchQueue.main.async { self?.statusText = "Video connection failed: \(error)" }
            default: break
            }
        }
        conn.start(queue: queue)
        receiveVideoHeader(conn)
    }

    private static let frameHeaderSize = 8 + 16 + 4 + 20 + 8 + 8   // 64 bytes, see PVRSockets.cpp extraBuf

    private func receiveVideoHeader(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: Self.frameHeaderSize, maximumLength: Self.frameHeaderSize) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data, data.count == Self.frameHeaderSize else {
                if error == nil && !isComplete { self?.receiveVideoHeader(conn) }
                return
            }
            // nalSize is the int32 at byte offset 8+16=24 in extraBuf.
            let nalSize = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: Int32.self) }
            self.receiveVideoPayload(conn, remaining: Int(nalSize))
        }
    }

    private func receiveVideoPayload(_ conn: NWConnection, remaining: Int, accumulated: Data = Data()) {
        guard remaining > 0 else {
            decoder.push(accumulated)
            receiveVideoHeader(conn)
            return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var acc = accumulated
            if let data = data { acc.append(data) }
            let left = remaining - (data?.count ?? 0)
            if left > 0 && error == nil && !isComplete {
                self.receiveVideoPayload(conn, remaining: left, accumulated: acc)
            } else {
                self.decoder.push(acc)
                self.receiveVideoHeader(conn)
            }
        }
    }

    // MARK: - Step 6: continuous pose stream

    private func connectPose() {
        let conn = NWConnection(host: NWEndpoint.Host(pcHost), port: NWEndpoint.Port(rawValue: PVRPort.pose)!, using: .udp)
        poseConnection = conn
        conn.start(queue: queue)
    }

    private func startMotion() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 72.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            guard let self = self, let q = motion?.attitude.quaternion else { return }
            let packet = PVRWire.posePacket(qw: Float(q.w), qx: Float(q.x), qy: Float(q.y), qz: Float(q.z))
            self.poseConnection?.send(content: packet, completion: .contentProcessed { _ in })
        }
    }
}
