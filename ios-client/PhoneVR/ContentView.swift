import SwiftUI
import CoreImage
import Transcoding

final class StreamViewModel: ObservableObject {
    @Published var frame: CGImage?
    @Published var connected = false

    private let videoClient = TCPClient()
    private let controlClient = TCPClient()
    private let videoDecoder = VideoDecoder(config: .init(realTime: true))
    private lazy var annexBAdaptor = VideoDecoderAnnexBAdaptor(videoDecoder: videoDecoder, codec: .h264)
    private var decodeTask: Task<Void, Never>?
    private var motionSender: MotionSender?
    private let ciContext = CIContext()

    /// host: the PC's IP, either on the Wi-Fi LAN or on the USB Ethernet
    /// link (see docs/usb-connection.md) - same code path either way.
    /// videoPort/controlPort must match server.py's VIDEO_PORT / CONTROL_PORT.
    func connect(host: String, videoPort: UInt16 = 9001, controlPort: UInt16 = 9002) {
        decodeTask?.cancel()
        decodeTask = Task { [weak self] in
            guard let self = self else { return }
            for await sampleBuffer in self.videoDecoder.decodedSampleBuffers {
                guard let pixelBuffer = sampleBuffer.imageBuffer else { continue }
                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                guard let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) else { continue }
                await MainActor.run { self.frame = cgImage }
            }
        }

        videoClient.onData = { [weak self] data in self?.annexBAdaptor.decode(data) }
        videoClient.onStateChange = { [weak self] state in
            if case .ready = state { DispatchQueue.main.async { self?.connected = true } }
        }
        videoClient.connect(host: host, port: videoPort)

        controlClient.connect(host: host, port: controlPort)
        let sender = MotionSender(client: controlClient)
        sender.start()
        motionSender = sender
    }

    func disconnect() {
        decodeTask?.cancel()
        videoDecoder.invalidate()
        motionSender?.stop()
        videoClient.disconnect()
        controlClient.disconnect()
        connected = false
    }
}

enum ConnectionMode: String, CaseIterable, Identifiable {
    case mouseLook = "Mouse-look (any game)"
    case steamVR = "SteamVR (PhoneVR driver)"
    var id: String { rawValue }
}

/// Both transports use the exact same TCP/UDP code below - "USB" only
/// changes which IP you type in, since the phone dials out to the PC in
/// every mode. Wi-Fi: the PC's normal LAN IP. USB: enable Internet Sharing
/// (Windows: "Internet Connection Sharing" onto the "Apple Mobile Device
/// Ethernet" adapter that appears when the iPhone is plugged in) so the
/// phone gets a real IP over the cable and can reach the PC directly - see
/// docs/usb-connection.md. (A raw usbmuxd/iproxy tunnel does NOT work here:
/// it only forwards PC-initiated connections, and this app always dials out.)
enum Transport: String, CaseIterable, Identifiable {
    case wifi = "Wi-Fi"
    case usb = "USB"
    var id: String { rawValue }

    var hint: String {
        switch self {
        case .wifi: return "Enter the PC's normal LAN IP (same Wi-Fi network)."
        case .usb: return "Enable Internet Sharing to the \"Apple Mobile Device Ethernet\" adapter on the PC, then enter the PC's IP on that adapter (see docs/usb-connection.md)."
        }
    }
}

struct ContentView: View {
    @StateObject private var vm = StreamViewModel()
    @StateObject private var pvr = PVRSteamVRClient()
    @State private var host = "192.168.1.100"
    @State private var showSettings = true
    @State private var mode: ConnectionMode = .mouseLook
    @State private var transport: Transport = .wifi

    private var activeImage: CGImage? {
        mode == .steamVR ? pvr.frame : vm.frame
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = activeImage {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        eyeView(image: image, width: geo.size.width / 2, height: geo.size.height)
                        eyeView(image: image, width: geo.size.width / 2, height: geo.size.height)
                    }
                }
                .ignoresSafeArea()
                .onTapGesture(count: 2) { showSettings.toggle() }
            }

            // Always-visible debug strip for the SteamVR path - there's no
            // Xcode console attached to a sideloaded CI build, so this is
            // the only way to see what stage things are stuck at.
            if mode == .steamVR && !showSettings {
                VStack {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(pvr.log.enumerated()), id: \.offset) { _, line in
                            Text(line)
                        }
                        Text("frames decoded: \(pvr.framesDecoded)").bold()
                        if let err = pvr.lastDecodeError {
                            Text(err).foregroundColor(.red)
                        }
                    }
                    .font(.caption2).foregroundColor(.white)
                    .padding(6)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(6)
                    .padding(.top, 8)
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                }
            }

            if showSettings {
                VStack(spacing: 16) {
                    Text("PhoneVR").font(.title).foregroundColor(.white)

                    Picker("Mode", selection: $mode) {
                        ForEach(ConnectionMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 24)

                    Picker("Transport", selection: $transport) {
                        ForEach(Transport.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 24)

                    TextField("PC IP address", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 40)
                        .keyboardType(.numbersAndPunctuation)

                    Text(transport.hint)
                        .font(.caption2).foregroundColor(.gray)
                        .padding(.horizontal, 40)
                        .multilineTextAlignment(.center)

                    Button(statusLabel) {
                        switch mode {
                        case .mouseLook: vm.connect(host: host)
                        case .steamVR: pvr.start(pcHost: host)
                        }
                        showSettings = false
                    }
                    .buttonStyle(.borderedProminent)

                    if mode == .steamVR {
                        Text(pvr.statusText)
                            .font(.footnote).foregroundColor(.gray)
                            .padding(.horizontal, 40)
                            .multilineTextAlignment(.center)
                        Text("Requires the PhoneVR OpenVR driver installed and SteamVR running on the PC.")
                            .font(.caption2).foregroundColor(.gray)
                            .padding(.horizontal, 40)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(16)
            }
        }
        .statusBar(hidden: true)
        .persistentSystemOverlays(.hidden)
    }

    private var statusLabel: String {
        mode == .steamVR ? (pvr.frame == nil ? "Connect" : "Connected") : (vm.connected ? "Connected" : "Connect")
    }

    private func eyeView(image: CGImage, width: CGFloat, height: CGFloat) -> some View {
        Image(decorative: image, scale: 1.0)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: width, height: height)
            .clipped()
    }
}
