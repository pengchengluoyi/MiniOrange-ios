import SwiftUI

struct SettingsView: View {
    @StateObject var wsManager = WebSocketManager.shared
    @StateObject var serverManager = ServerManager.shared
    @State private var showScanner = false
    
    // 重命名相关
    @State private var serverToRename: ServerConfig?
    @State private var newServerName: String = ""
    @State private var showRenameAlert = false
    
    // ✅ 需求修改 3: Toast 弹窗状态
    @State private var toastMessage: String?
    
    var body: some View {
        NavigationView {
            ZStack {
                List {
                    // 1. 当前连接 (移除 Disconnect 按钮)
                    Section(header: Text("Current Connection")) {
                        if let current = serverManager.currentServer {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(wsManager.isConnected ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
                                        .frame(width: 40, height: 40)
                                    Image(systemName: wsManager.isConnected ? "wifi" : "wifi.slash")
                                        .foregroundColor(wsManager.isConnected ? .green : .orange)
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(current.name ?? "Server")
                                            .font(.headline)
                                        if wsManager.isConnected {
                                            Text("Online").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Color.green.opacity(0.2)).foregroundColor(.green).cornerRadius(4)
                                        } else {
                                            Text("Offline").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Color.gray.opacity(0.2)).foregroundColor(.gray).cornerRadius(4)
                                        }
                                    }
                                    Text(wsManager.serverIP)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        } else {
                            Text("No Server Connected").foregroundColor(.secondary)
                        }
                    }
                    
                    // 2. 服务器列表
                    Section(header: Text("Saved Servers"), footer: Text("Tap to switch. Swipe left to delete.")) {
                        ForEach(serverManager.savedServers) { server in
                            Button(action: {
                                if server.id != serverManager.currentServer?.id {
                                    serverManager.switchTo(server)
                                }
                            }) {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(server.name ?? "Server").font(.body).foregroundColor(.primary)
                                        Text(server.u).font(.caption).foregroundColor(.gray)
                                    }
                                    Spacer()
                                    if server.id == serverManager.currentServer?.id {
                                        Image(systemName: "checkmark.circle.fill").foregroundColor(.blue)
                                    }
                                }
                            }
                            .foregroundColor(.primary)
                            .swipeActions(edge: .leading) {
                                Button("Rename") {
                                    serverToRename = server
                                    newServerName = server.name ?? ""
                                    showRenameAlert = true
                                }
                                .tint(.blue)
                            }
                            .contextMenu {
                                Button {
                                    serverToRename = server
                                    newServerName = server.name ?? ""
                                    showRenameAlert = true
                                } label: { Label("Rename", systemImage: "pencil") }
                                Button(role: .destructive) {
                                    if let idx = serverManager.savedServers.firstIndex(of: server) {
                                        serverManager.removeServer(at: IndexSet(integer: idx))
                                    }
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                        .onDelete(perform: serverManager.removeServer)
                        
                        Button(action: { showScanner = true }) {
                            Label("Add New Server", systemImage: "plus.circle")
                        }
                    }
                    
                    // 3. 关于
                    Section(header: Text("About")) {
                        HStack { Text("Version"); Spacer(); Text("1.0.3").foregroundColor(.gray) }
                        HStack {
                            Text("Client SN")
                            Spacer()
                            Text(String(wsManager.clientSN.prefix(8)))
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.gray)
                        }
                    }
                }
                
                // ✅ Toast 弹窗层
                if let message = toastMessage {
                    VStack {
                        Spacer()
                        Text(message)
                            .font(.footnote)
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.black.opacity(0.8))
                            .cornerRadius(12)
                            .padding(.bottom, 50) // 底部留白
                            .shadow(radius: 10)
                    }
                    .transition(.opacity)
                    .zIndex(100)
                }
            }
            .navigationTitle("Settings")
            .alert("Rename Server", isPresented: $showRenameAlert) {
                TextField("Name", text: $newServerName)
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    if let s = serverToRename {
                        serverManager.updateServerName(server: s, newName: newServerName)
                    }
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerView { code in
                    showScanner = false
                    handleScan(code)
                }
            }
        }
    }
    
    private func handleScan(_ code: String) {
        guard let data = code.data(using: .utf8),
              let config = try? JSONDecoder().decode(ConnectionConfig.self, from: data) else { return }
        
        let newName = "Server \(serverManager.savedServers.count + 1)"
        let newServerConfig = ServerConfig(u: config.u, name: newName)
        
        // 调用 ServerManager 检查是否重复
        let result = serverManager.addServer(newServerConfig)
        
        if !result.isNew {
            // ✅ 显示 Toast
            withAnimation {
                toastMessage = "之前已经添加过当前服务端了，为您跳转到当前服务端"
            }
            // 3秒后隐藏
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation { toastMessage = nil }
            }
        }
        
        // 自动切换
        serverManager.switchTo(result.server)
    }
}
