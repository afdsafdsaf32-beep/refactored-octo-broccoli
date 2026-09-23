import CoreMotion
import Foundation

/// Reads phone orientation and streams yaw/pitch to the PC as small
/// length-prefixed JSON packets over the control TCP connection.
final class MotionSender {
    private let motionManager = CMMotionManager()
    private let client: TCPClient

    init(client: TCPClient) {
        self.client = client
    }

    func start() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            guard let self = self, let motion = motion else { return }
            let yaw = motion.attitude.yaw * 180 / .pi
            let pitch = motion.attitude.pitch * 180 / .pi
            let roll = motion.attitude.roll * 180 / .pi
            self.send(yaw: yaw, pitch: pitch, roll: roll)
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }

    private func send(yaw: Double, pitch: Double, roll: Double) {
        let payload: [String: Double] = ["yaw": yaw, "pitch": pitch, "roll": roll]
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var length = UInt32(json.count).bigEndian
        var packet = Data()
        withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
        packet.append(json)
        client.send(packet)
    }
}
