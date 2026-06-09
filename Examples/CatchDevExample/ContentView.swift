import SwiftUI
import CatchDev

struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)

                Text("Shake the device to report feedback")
                    .font(.headline)
                Text("Simulator: Hardware → Shake Gesture (⌃⌘Z)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Or send feedback manually") {
                    CatchDev.presentReporter()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("CatchDev Example")
        }
    }
}

#Preview {
    ContentView()
}
