import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var wsManager = WebSocketManager.shared
    @State private var showToast = false
    @State private var toastMessage = ""
    @AppStorage("connectionConfig") private var storedConfigData: Data = Data() // 引入 AppStorage
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Connection")) {
                    HStack {
                        Text("Server")
                        Spacer()
                        Text(wsManager.serverName)
                            .foregroundColor(.gray)
                    }
                    Button("Disconnect") {
                        wsManager.disconnect()
                        // 清除配置，触发 App 返回扫描页
                        storedConfigData = Data()
                    }
                    .foregroundColor(.red)
                }
                
                Section(header: Text("Command Center")) {
                    CommandButton(title: "Reboot Service", command: "reboot", color: .orange)
                    CommandButton(title: "Screenshot", command: "screenshot", color: .blue)
                    CommandButton(title: "Clear Logs", command: "clear_logs", color: .gray)
                }
            }
            .navigationTitle("Settings")
        }
        .overlay(
            ToastView(message: toastMessage, isShowing: $showToast)
        )
        .onReceive(wsManager.toastSubject) { msg in
            self.toastMessage = msg
            self.showToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.showToast = false
            }
        }
    }
}

struct CommandButton: View {
    let title: String
    let command: String
    let color: Color
    
    var body: some View {
        Button(action: {
            // Haptic Feedback
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            
            // Send Command
            WebSocketManager.shared.send(json: ["action": "system_command", "cmd": command])
        }) {
            Text(title)
                .foregroundColor(color)
        }
    }
}

struct ToastView: View {
    let message: String
    @Binding var isShowing: Bool
    
    var body: some View {
        if isShowing {
            VStack {
                Spacer()
                Text(message)
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.black.opacity(0.8))
                    .cornerRadius(20)
                    .padding(.bottom, 50)
            }
            .transition(.opacity)
            .animation(.easeInOut, value: isShowing)
        }
    }
}