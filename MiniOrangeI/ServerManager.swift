import SwiftUI
import Combine

struct ServerConfig: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    let u: String // URL
    var name: String? // 别名
    
    static func == (lhs: ServerConfig, rhs: ServerConfig) -> Bool {
        return lhs.u == rhs.u
    }
}

class ServerManager: ObservableObject {
    static let shared = ServerManager()
    
    @Published var savedServers: [ServerConfig] = []
    @Published var currentServer: ServerConfig?
    
    private let storageKey = "saved_servers"
    private let currentKey = "current_server_id"
    
    init() {
        loadServers()
    }
    
    private func loadServers() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let servers = try? JSONDecoder().decode([ServerConfig].self, from: data) {
            self.savedServers = servers
        }
        
        if let lastId = UserDefaults.standard.string(forKey: currentKey),
           let server = savedServers.first(where: { $0.id == lastId }) {
            self.currentServer = server
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                WebSocketManager.shared.setup(url: server.u)
            }
        }
    }
    
    // ✅ 修改返回值：(最终的Server配置, 是否是新添加的)
    func addServer(_ config: ServerConfig) -> (server: ServerConfig, isNew: Bool) {
        if let existing = savedServers.first(where: { $0 == config }) {
            return (existing, false) // 返回旧的，标记为不是新的
        }
        
        objectWillChange.send()
        savedServers.append(config)
        save()
        return (config, true) // 返回新的，标记为是新的
    }
    
    func updateServerName(server: ServerConfig, newName: String) {
        if let index = savedServers.firstIndex(where: { $0.id == server.id }) {
            savedServers[index].name = newName
            if currentServer?.id == server.id {
                currentServer?.name = newName
            }
            save()
        }
    }
    
    func removeServer(at offsets: IndexSet) {
        offsets.forEach { index in
            let server = savedServers[index]
            if server.id == currentServer?.id {
                internalDisconnectOnly()
            }
        }
        savedServers.remove(atOffsets: offsets)
        save()
    }
    
    func switchTo(_ server: ServerConfig) {
        WebSocketManager.shared.clearState()
        self.currentServer = server
        UserDefaults.standard.set(server.id, forKey: currentKey)
        DispatchQueue.main.async {
            WebSocketManager.shared.setup(url: server.u)
        }
    }
    
    func disconnectCurrent() {
        guard let current = currentServer else { return }
        savedServers.removeAll { $0.id == current.id }
        internalDisconnectOnly()
        save()
    }
    
    private func internalDisconnectOnly() {
        DispatchQueue.main.async {
            self.currentServer = nil
            UserDefaults.standard.removeObject(forKey: self.currentKey)
            WebSocketManager.shared.disconnect()
            WebSocketManager.shared.clearState()
        }
    }
    
    private func save() {
        if let data = try? JSONEncoder().encode(savedServers) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
