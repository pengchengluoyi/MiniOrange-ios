import SwiftUI
import ReplayKit

struct ContentView: View {
    @StateObject var wsManager = WebSocketManager.shared
    @State private var serverURLString = "ws://192.168.1.100:8000/ws?token=123"
    @State private var isStreaming = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 25) {
                // Header
                VStack(spacing: 5) {
                    Text("MiniOrange Agent")
                        .font(.title)
                        .bold()
                    Text("iOS Client")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                
                // Connection Status
                HStack {
                    Circle()
                        .fill(wsManager.isConnected ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                    Text(wsManager.isConnected ? "Connected" : "Disconnected")
                        .font(.headline)
                }
                .padding(.top)
                
                // Server Input / Scan
                VStack(alignment: .leading) {
                    Text("Server Address")
                        .font(.caption)
                        .foregroundColor(.gray)
                    HStack {
                        TextField("ws://...", text: $serverURLString)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                        
                        Button(action: {
                            // Simulate QR Scan
                            print("Scanning QR Code...")
                        }) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.title2)
                        }
                    }
                }
                .padding(.horizontal)
                
                // Connect Button
                Button(action: {
                    if wsManager.isConnected {
                        wsManager.disconnect()
                    } else {
                        if let url = URL(string: serverURLString) {
                            wsManager.connect(url: url)
                        }
                    }
                }) {
                    Text(wsManager.isConnected ? "Disconnect" : "Connect")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(wsManager.isConnected ? Color.red.opacity(0.8) : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .padding(.horizontal)
                
                Divider()
                
                // Streaming Status
                if isStreaming {
                    Text("Streaming to: \(wsManager.currentViewerSN ?? "Unknown")")
                        .font(.caption)
                        .padding(5)
                        .background(Color.green.opacity(0.2))
                        .cornerRadius(5)
                }
                
                // System Broadcast Picker (Required for System-wide recording)
                VStack {
                    Text("System Broadcast")
                        .font(.caption)
                    BroadcastPickerView()
                        .frame(width: 60, height: 60)
                }
                
                Spacer()
            }
            .padding()
            .onReceive(NotificationCenter.default.publisher(for: .startStream)) { _ in
                ScreenRecorder.shared.startRecording()
                isStreaming = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .stopStream)) { _ in
                ScreenRecorder.shared.stopRecording()
                isStreaming = false
            }
        }
    }
}

struct BroadcastPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: .zero)
        // Note: Replace with your actual Broadcast Upload Extension Bundle ID
        picker.preferredExtension = "com.miniorange.broadcast.extension"
        picker.showsMicrophoneButton = false
        return picker
    }
    
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}