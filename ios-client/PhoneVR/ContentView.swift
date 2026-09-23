import SwiftUI
import CoreImage

final class StreamViewModel: ObservableObject {
    @Published var frame: CGImage?
    @Published var connected = false

    private let videoClient = TCPClient()
    private let controlClient = TCPClient()
    private let decoder = H264Decoder()
    private var motionSender: MotionSender?
    private let ciContext = CIContext()

    /// host: PC's LAN IP for Wi-Fi, or "127.0.0.1" if tunneled over USB via
    /// iproxy (see docs/usb-tunnel.md). videoPort/controlPort must match
    /// server.py's VIDEO_PORT / CONTROL_PORT (or the local ports iproxy forwards to).
    func connect(host: String, videoPort: UInt16 = 9001, controlPort: UInt16 = 9002) {
        decoder.onFrame = { [weak self] pixelBuffer in
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = self?.ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
            DispatchQueue.main.async { self?.frame = cgImage }
        }

        videoClient.onData = { [weak self] data in self?.decoder.push(data) }
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
        motionSender?.stop()
        videoClient.disconnect()
        controlClient.disconnect()
        connected = false
    }
}

struct ContentView: View {
    @StateObject private var vm = StreamViewModel()
    @State private var host = "192.168.1.100"
    @State private var showSettings = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = vm.frame {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        eyeView(image: image, width: geo.size.width / 2, height: geo.size.height)
                        eyeView(image: image, width: geo.size.width / 2, height: geo.size.height)
                    }
                }
                .ignoresSafeArea()
                .onTapGesture(count: 2) { showSettings.toggle() }
            }

            if showSettings {
                VStack(spacing: 16) {
                    Text("PhoneVR").font(.title).foregroundColor(.white)
                    TextField("PC IP address (or 127.0.0.1 for USB)", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 40)
                        .keyboardType(.numbersAndPunctuation)
                    Button(vm.connected ? "Connected" : "Connect") {
                        vm.connect(host: host)
                        showSettings = false
                    }
                    .buttonStyle(.borderedProminent)
                    Text("Tip: for USB, run iproxy on the PC and use 127.0.0.1 here.")
                        .font(.footnote).foregroundColor(.gray)
                        .padding(.horizontal, 40)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(16)
            }
        }
        .statusBar(hidden: true)
        .persistentSystemOverlays(.hidden)
    }

    private func eyeView(image: CGImage, width: CGFloat, height: CGFloat) -> some View {
        Image(decorative: image, scale: 1.0)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: width, height: height)
            .clipped()
    }
}
