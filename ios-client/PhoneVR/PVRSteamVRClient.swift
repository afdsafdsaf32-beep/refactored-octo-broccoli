import Foundation
import Network
import CoreMotion
import CoreImage
import CoreGraphics
import CoreMedia
import Transcoding

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
    /// Rolling log of milestones, newest last - unlike statusText (which
    /// only ever shows the latest message) this lets you see the whole
    /// handshake sequence at once, so a step that happened-then-got-
    /// overwritten isn't invisible.
    @Published var log: [String] = []

    private func logEvent(_ message: String) {
        DispatchQueue.main.async {
            self.statusText = message
            self.log.append(message)
            if self.log.count > 8 { self.log.removeFirst(self.log.count - 8) }
        }
    }

    // Own hand-rolled H264Decoder was replaced with finnvoor/Transcoding:
    // it does the same Annex-B -> VideoToolbox decode but avoids two bugs
    // ours had - decodeFrame with _EnableAsynchronousDecompression pointing
    // a CMBlockBuffer at memory that got freed before decode actually ran,
    // and rebuilding the VTDecompressionSession on every repeated SPS/PPS
    // (x264 re-embeds them before every keyframe) instead of only when the
    // format description actually changes.
    private let videoDecoder = VideoDecoder(config: .init(realTime: true))
    private lazy var annexBAdaptor = VideoDecoderAnnexBAdaptor(videoDecoder: videoDecoder, codec: .h264)
    private var decodeTask: Task<Void, Never>?
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
    private var active = false
    private var videoConnected = false
    private var videoRetryCount = 0

    private let queue = DispatchQueue(label: "phonevr.pvr")

    // Render target size reported to the PC. Any 2:1-per-eye size works;
    // the PC driver just uses it to size its render texture.
    private let renderWidth: UInt16 = 1920
    private let renderHeight: UInt16 = 1080

    func start(pcHost: String) {
        stop()   // tear down any listener/connections left over from a previous attempt first -
                 // otherwise NWListener silently fails to rebind port 33333 (already in use)
        self.pcHost = pcHost
        active = true
        paired = false
        videoConnected = false
        videoRetryCount = 0
        framesDecoded = 0
        lastDecodeError = nil
        log = []
        logEvent("Announcing to \(pcHost)...")

        decodeTask?.cancel()
        decodeTask = Task { [weak self] in
            guard let self = self else { return }
            for await sampleBuffer in self.videoDecoder.decodedSampleBuffers {
                guard let pixelBuffer = sampleBuffer.imageBuffer else { continue }
                // The PC captures the SteamVR compositor's Direct3D texture
                // (top-left origin, row 0 = top) and feeds it to x264 as raw
                // frames; CoreImage's CVPixelBuffer coordinate space is
                // bottom-left origin. That mismatch alone shows up as a 180°
                // rotation ("mirrored and upside down" looks the same as a
                // rotation to an untrained eye). Correct for it here since we
                // can't easily patch/recompile the closed legacy PC driver.
                let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(.down)
                guard let cg = self.ciContext.createCGImage(ciImage, from: ciImage.extent) else { continue }
                await MainActor.run {
                    self.frame = cg
                    self.framesDecoded += 1
                }
            }
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
        active = false
        decodeTask?.cancel()
        decodeTask = nil
        videoDecoder.invalidate()
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
                self?.logEvent("Control channel connected")
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
            logEvent("Paired - sending display config")
            sendAdditionalData()
            connectVideo()
            connectPose()
        case .headerNALs:
            annexBAdaptor.decode(payload)   // contains SPS+PPS Annex-B NALs
            logEvent("Got SPS/PPS (\(payload.count) bytes)")
        case .disconnect:
            logEvent("PC disconnected")
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
        videoConnected = false
        videoRetryCount = 0
        attemptVideoConnect()
    }

    /// The PC driver needs a couple hundred ms after ADDITIONAL_DATA to
    /// actually call accept() on its video port (observed ~200ms in
    /// pvrlog.txt) - a connect attempt that lands before that sits retrying
    /// SYNs indefinitely without ever calling back .failed, so a single
    /// attempt with no timeout can hang forever. Give each attempt a short
    /// window, then cancel and start a fresh one.
    private func attemptVideoConnect() {
        guard active, !videoConnected else { return }
        let conn = NWConnection(host: NWEndpoint.Host(pcHost), port: NWEndpoint.Port(rawValue: PVRPort.video)!, using: .tcp)
        videoConnection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.videoConnected = true
                self.logEvent("Video connected, waiting for frames...")
            case .failed:
                self.retryVideoConnect()
            default: break
            }
        }
        conn.start(queue: queue)
        receiveVideoHeader(conn)

        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.retryVideoConnect()
        }
    }

    private func retryVideoConnect() {
        guard active, !videoConnected else { return }
        videoRetryCount += 1
        if videoRetryCount == 1 || videoRetryCount % 5 == 0 {
            logEvent("Retrying video connection (attempt \(videoRetryCount))...")
        }
        videoConnection?.cancel()
        attemptVideoConnect()
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
            annexBAdaptor.decode(accumulated)
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
                self.annexBAdaptor.decode(acc)
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
