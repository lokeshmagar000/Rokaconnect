import SwiftUI
import AppKit
import CoreLocation
import IOBluetooth

/// The "hello" card that drops out of the notch on first launch.
struct WelcomeCard: View {
    let notch: CGFloat
    @State private var drawn: CGFloat = 0
    var body: some View {
        VStack(spacing: 6) {
            Color.clear.frame(height: notch - 4)
            Text("hello")
                .font(.custom("SnellRoundhand-Black", size: 46))
                .foregroundStyle(LinearGradient(colors: [Color(red: 0.35, green: 0.62, blue: 1), Color(red: 0.62, green: 0.45, blue: 1), Color(red: 1, green: 0.45, blue: 0.7)],
                                                startPoint: .leading, endPoint: .trailing))
                .mask(Rectangle().scaleEffect(x: drawn, anchor: .leading))      // writes itself in, left to right
                .frame(height: 44)
            Text("Welcome to Rokaconnect").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75))
            Button { (NSApp.delegate as? AppDelegate)?.startSetup() } label: {
                Text("Get Started").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .glass(Capsule(), tint: .white.opacity(0.1))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .onAppear { withAnimation(.easeInOut(duration: 1.6).delay(0.35)) { drawn = 1 } }
    }
}

/// One-minute setup: asks for each permission in turn, then gets out of the way.
final class SetupModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var step = 0
    private let lm = CLLocationManager()

    struct Step { let icon: String; let title: String; let detail: String; let action: String }
    let steps: [Step] = [
        Step(icon: "music.note", title: "Music", detail: "Let Rokaconnect see what's playing in Music and Spotify. macOS asks once per app, the first time it's playing.", action: "Continue"),
        Step(icon: "cloud.sun.fill", title: "Weather", detail: "Your approximate location shows the weather in the island and on the lock screen.", action: "Allow Location"),
        Step(icon: "earbuds", title: "Headphones", detail: "Bluetooth access shows AirPods and Galaxy Buds battery, and lets you change Buds noise control.", action: "Allow Bluetooth"),
        Step(icon: "checkmark.circle.fill", title: "You're all set", detail: "Move your pointer to the notch any time. Everything else lives in Settings, in the menu bar.", action: "Done"),
    ]

    func next(close: () -> Void) {
        switch step {
        case 1: lm.delegate = self; lm.requestWhenInUseAuthorization()
        case 2: _ = IOBluetoothDevice.pairedDevices()          // triggers the Bluetooth prompt
        case 3: UserDefaults.standard.set(true, forKey: "onboarded"); close(); return
        default: break
        }
        step += 1
    }
}

struct SetupView: View {
    @StateObject var model = SetupModel()
    var close: () -> Void
    var body: some View {
        let s = model.steps[model.step]
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(0..<model.steps.count, id: \.self) { i in
                    Capsule().fill(Color.white.opacity(i <= model.step ? 0.9 : 0.2)).frame(width: i == model.step ? 18 : 6, height: 6)
                }
            }
            .animation(.spring, value: model.step)
            Image(systemName: s.icon).font(.system(size: 34)).frame(height: 44).id(s.icon).transition(.scale.combined(with: .opacity))
            Text(s.title).font(.system(size: 18, weight: .bold))
            Text(s.detail).font(.system(size: 12)).opacity(0.65).multilineTextAlignment(.center).frame(width: 280).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { withAnimation(.spring) { model.next(close: close) } } label: {
                Text(s.action).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 200).padding(.vertical, 8).glass(Capsule(), tint: .white.opacity(0.1))
            }
            .buttonStyle(.plain)
            if model.step > 0 && model.step < 3 {
                Button("Not now") { withAnimation(.spring) { model.step += 1 } }.buttonStyle(.plain).font(.system(size: 11)).opacity(0.5)
            }
        }
        .padding(28)
        .frame(width: 360, height: 330)
        .legacyWindowGlass()
        .foregroundStyle(.white)
    }
}
