import SwiftUI

struct GlobalOfflineModifier: ViewModifier {
    @ObservedObject var socket = WebSocketManager.shared
    
    func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            content
            
            // 状态 1: 正在连接中 (仿微信 "收取中..." 样式)
            if socket.isConnecting {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Connecting...")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .cornerRadius(20)
                .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
                .padding(.top, 50) // 避开刘海
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(1000)
            }
            // 状态 2: 完全断开连接 (红色警告)
            else if !socket.isConnected {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("与服务器断开连接")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    
                    Button("重试") {
                        if let config = ServerManager.shared.currentServer {
                            WebSocketManager.shared.setup(url: config.u, token: config.t)
                        }
                    }
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white)
                    .foregroundColor(.red)
                    .cornerRadius(8)
                }
                .foregroundColor(.white)
                .padding()
                .padding(.top, 40) // 避开刘海
                .background(Color.red)
                .transition(.move(edge: .top))
                .zIndex(999)
                .ignoresSafeArea()
            }
        }
        .animation(.easeInOut, value: socket.isConnected)
        .animation(.easeInOut, value: socket.isConnecting)
    }
}

extension View {
    func showOfflineBanner() -> some View {
        self.modifier(GlobalOfflineModifier())
    }
}
