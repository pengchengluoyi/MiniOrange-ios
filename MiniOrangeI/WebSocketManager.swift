import Foundation
import Combine
import UIKit

// MARK: - 必须添加 URLSessionWebSocketDelegate 协议
@MainActor
class WebSocketManager: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    static let shared = WebSocketManager()
    
    // 🔥 [新增] 移动端生成的唯一身份 Token (User Token)
    let userToken: String
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var lastURL: URL?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var serverName: String = "Unknown"
    @Published var serverIP: String = "Unknown" // ✅ 修复 SettingsView 报错的关键
    @Published var isDeviceOfflineFromCluster = false // ✅ 恢复：设备下线状态
    
    // MARK: - Subjects (恢复所有数据流)
    let workflowSubject = PassthroughSubject<[WorkflowItem], Never>()
    let toastSubject = PassthroughSubject<String, Never>()
    let deviceListSubject = CurrentValueSubject<[Device], Never>([])
    let videoFrameSubject = PassthroughSubject<Data, Never>()
    let passwordSubject = PassthroughSubject<String, Never>() // ✅ 新增：密码回调
    
    // 恢复 ScreenRecorder 需要的属性
    var currentViewerSN: String?
    let clientSN: String
    
    // 恢复分辨率配置
    var remoteWidth: Double { 1080.0 }
    var remoteHeight: Double { 2400.0 }
    
    override init() {
        self.clientSN = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        
        // 2. 🔥 初始化 User Token (如果本地没有，就生成一个并持久化)
        if let storedToken = UserDefaults.standard.string(forKey: "miniorange_user_token") {
            self.userToken = storedToken
        } else {
            let newToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            UserDefaults.standard.set(newToken, forKey: "miniorange_user_token")
            self.userToken = newToken
        }
        
        super.init()
        let config = URLSessionConfiguration.default
        // self 现在遵循协议了，不会报错
        session = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue())
    }
    
    /// 并发检测一组 URL，返回最快连通的那一个
    func raceToFindFastestHost(urls: [String]) async -> String? {
        // 如果只有一个，直接返回，不用赛了
        if urls.count == 1 { return urls.first }
        
        print("🏎️ [Race] 开始赛马，参赛选手: \(urls)")
        
        return await withTaskGroup(of: String?.self) { group in
            for urlStr in urls {
                group.addTask {
                    return await self.checkConnectivity(urlStr: urlStr)
                }
            }
            
            // 等待第一个非空结果
            for await result in group {
                if let winner = result {
                    print("🏆 [Race] 胜出者: \(winner)")
                    group.cancelAll() // 既然有一个赢了，其他的就不用跑了
                    return winner
                }
            }
            
            print("☠️ [Race] 全军覆没，没有一个能连上")
            return nil
        }
    }
    
    /// 单个连接检测 (使用 HTTP HEAD 或 简单的 GET)
    private func checkConnectivity(urlStr: String) async -> String? {
        // 将 ws:// 转为 http:// 仅用于检测连通性 (开销更小)
        let httpStr = urlStr
            .replacingOccurrences(of: "ws://", with: "http://")
            .replacingOccurrences(of: "wss://", with: "https://")
        
        // 简单处理：去掉 /ws 后缀，改为 / (或者保留 /ws 也可以，只要端口通就行)
        // 这里为了稳妥，我们请求根路径或者不做改动，只要 TCP 握手成功即可
        guard let url = URL(string: httpStr) else { return nil }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET" // 或者 HEAD
        request.timeoutInterval = 2.0 // 🔥 关键：只给 2 秒超时，连不上的赶紧滚
        
        do {
            // 只要服务器有响应 (哪怕是 404/403)，说明网络层是通的！
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResp = response as? HTTPURLResponse {
                // print("✅ [Probe] \(urlStr) -> \(httpResp.statusCode)")
                return urlStr // 返回原始 ws 地址
            }
        } catch {
            // print("❌ [Probe] \(urlStr) -> 超时/失败")
        }
        return nil
    }
    
    // MARK: - 1. 恢复 setup 方法 (解决 MiniOrangeApp 报错)
    func setup(url: String) {
        clearState()
        // 自动处理 url，确保 ws:// 前缀
        var validUrlStr = url
        if !url.hasPrefix("ws://") && !url.hasPrefix("wss://") {
            validUrlStr = "ws://\(url)"
        }
        guard let baseURL = URL(string: url) else { return }
        self.serverName = baseURL.host ?? "Unknown"
        self.serverIP = baseURL.host ?? "Unknown" // ✅ 赋值
        
        
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        if components?.queryItems == nil { components?.queryItems = [] }
        // 移除旧 token (如果有)，添加 User Token
        components?.queryItems?.removeAll(where: { $0.name == "token" })
        components?.queryItems?.append(URLQueryItem(name: "token", value: self.userToken))
        if let fullURL = components?.url {
            connect(url: fullURL)
        }
    }
    
    /// 🔥 [新增] 配网逻辑：连接未配置的设备，发送配置指令
    /// - Parameters:
    ///   - targetAddress: 目标设备的 ws 地址 (从二维码获取)
    ///   - masterUrl: 主控端地址 (如果是配置 Master，则传 targetAddress 本身；如果是配置 Node，则传当前 Master 的地址)
    func provisionDevice(targetAddress: String, masterUrl: String) async throws {
        print("🔧 [Provision] 开始配网 -> \(targetAddress)")
        
        // 1. 建立临时连接 (不带 Token，或者带 Token 都可以，反正 Server 端此时是开放的或验证 Token)
        // 注意：这里我们使用一次性 HTTP 请求或者短连接 WS 都可以。
        // 由于后端已经改为纯 WS 架构，我们需要建立 WS 连接 -> 发送 join_cluster -> 断开
        
        guard let url = URL(string: targetAddress) else { throw URLError(.badURL) }
        let tempSession = URLSession(configuration: .default)
        let tempTask = tempSession.webSocketTask(with: url)
        tempTask.resume()
        
        // 等待连接建立 (简单延时，生产环境可用 Promise/Future)
        try await Task.sleep(nanoseconds: 500 * 1_000_000) // 0.5s
        
        // 2. 构造 join_cluster 指令
        // 注意：target_urls 是给 PC 端用的，告诉它去连谁。
        // 如果我们正在配置 Master，target_urls 就是它自己 (或者为空列表，视后端逻辑而定)。
        // 如果我们正在配置 Node，target_urls 是当前已连接的 Master 地址。
        let payload: [String: Any] = [
            "action": "join_cluster",
            "req": UUID().uuidString,
            "data": [
                "token": self.userToken,
                "target_urls": [masterUrl]
            ]
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }
        
        let message = URLSessionWebSocketTask.Message.string(jsonStr)
        
        return try await withCheckedThrowingContinuation { continuation in
            tempTask.send(message) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    print("✅ [Provision] 指令发送成功")
                    // 发送成功后，稍微等待一下再断开，确保 Server 收到
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        tempTask.cancel(with: .normalClosure, reason: nil)
                    }
                    continuation.resume(returning: ())
                }
            }
        }
    }
    
    // ✅ 新增：清理状态，防止不同 Server 数据混淆
    func clearState() {
        self.deviceListSubject.send([]) // 清空设备列表
        self.workflowSubject.send([])   // 清空 Dashboard
        self.isConnected = false
        self.isDeviceOfflineFromCluster = false // 断开连接时重置状态
    }
    
    func connect(url: URL) {
        reconnectTask?.cancel()
        self.isConnecting = true
        
        lastURL = url
        isConnecting = true
        webSocketTask = session?.webSocketTask(with: url)
        webSocketTask?.resume()
        
        receiveMessage()
        startHeartbeat()
    }
    
    func disconnect() {
        lastURL = nil
        reconnectTask?.cancel()
        internalDisconnect()
        clearState()
    }
    
    private func internalDisconnect() {
        isConnecting = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        pingTask?.cancel()
        self.isConnected = false
    }
    
    private func scheduleReconnect() {
        guard let url = lastURL, reconnectTask == nil else { return }
        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
            if !Task.isCancelled {
                self.reconnectTask = nil
                self.connect(url: url)
            }
        }
    }
    // MARK: - 🔥 核心修复：增强型心跳保活
    private func startHeartbeat() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                guard let self = self, self.isConnected else { return }
                
                self.webSocketTask?.sendPing { error in
                    if let error = error {
                        print("❌ Ping failed: \(error)")
                        Task { @MainActor in self.internalDisconnect(); self.scheduleReconnect() }
                    }
                }
                
                // 发送业务心跳
                let heartbeatData: [String: Any] = [
                    "action": "heartbeat",
                    "data": [
                        "sn": self.clientSN
                    ]
                ]
                self.send(json: heartbeatData)
            }
        }
    }
    
    // MARK: - 后台保活逻辑
    @objc private func handleAppBackground() {
        // 申请后台任务，保持 Socket 连接一段时间
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "WebSocketKeepAlive") {
            UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
            self.backgroundTaskID = .invalid
        }
    }
    
    @objc private func handleAppForeground() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
        // 回到前台如果断开了，立即重连
        if !isConnected && lastURL != nil {
            connect(url: lastURL!)
        }
    }
    
    // MARK: - 2. 恢复 send(data:) (解决 ScreenRecorder 报错)
    func send(data: Data) {
        let message = URLSessionWebSocketTask.Message.data(data)
        webSocketTask?.send(message) { error in
            if let error = error { print("❌ Send Binary Error: \(error)") }
        }
    }
    
    // JSON 发送
    func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: []),
              let string = String(data: data, encoding: .utf8) else { return }
        print("⬆️ [WebSocket] Sending: \(string)")
        let message = URLSessionWebSocketTask.Message.string(string)
        webSocketTask?.send(message) { error in
            if let error = error { print("❌ Send JSON Error: \(error)") }
        }
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                switch result {
                case .failure(let error):
                    print("❌ [WebSocket] Receive Error: \(error)")
                    self.internalDisconnect()
                    self.scheduleReconnect()
                case .success(let message):
                    switch message {
                    case .string(let text):
                        print("⬇️ [WebSocket] Received: \(text)")
                        self.handleMessage(text)
                    case .data(let data):
                        self.videoFrameSubject.send(data)
                    @unknown default: break
                    }
                    self.receiveMessage()
                }
            }
        }
    }
    
    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        
        // 🔥 状态码检查：处理下线与自动恢复
        if let code = json["code"] as? Int {
            if code == 503 {
                // 服务端明确告知已下线
                self.isDeviceOfflineFromCluster = true
                return
            } else if code == 200 {
                // ✅ 关键修复：如果注册成功，说明我们在线，强制清除下线标记
                // 这能解决 "先收到 503 后收到 200" 导致的假死问题
                if let action = json["action"] as? String, action == "register" {
                    self.isDeviceOfflineFromCluster = false
                }
            }
        }
        
        guard let action = json["action"] as? String else { return }
        
        print("✅ [WebSocket] Handling Action: \(action)")
        
        if action == "app_graph/list" {
            // Dashboard 逻辑保留
            if let data = json["data"] as? [[String: Any]] {
                let items = data.compactMap { dict -> WorkflowItem? in
                    guard let id = dict["id"] as? String, let name = dict["name"] as? String, let icon = dict["icon"] as? String else { return nil }
                    return WorkflowItem(id: id, name: name, icon: icon, color: dict["color"] as? String)
                }
                workflowSubject.send(items)
            }
        } else if action == "device_list" || action == "get_device_list" {
            if let data = json["data"] as? [[String: Any]] {
                let devices = data.compactMap { dict -> Device? in
                    guard let sn = dict["sn"] as? String, let model = dict["model"] as? String else { return nil }
                    return Device(sn: sn, model: model, status: dict["status"] as? String ?? "offline")
                }
                deviceListSubject.send(devices)
            }
        } else if action == "get_device_password" {
            if let data = json["data"] as? [String: Any], let pwd = data["password"] as? String {
                passwordSubject.send(pwd)
            }
        } else if action == "start_stream" {
            if let dataDict = json["data"] as? [String: Any],
               let viewerSN = dataDict["viewer_sn"] as? String {
                self.currentViewerSN = viewerSN
                NotificationCenter.default.post(name: .startStream, object: nil)
            }
        } else if action == "stop_stream" {
            NotificationCenter.default.post(name: .stopStream, object: nil)
        }
    }
    
    // MARK: - Delegate 方法
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("✅ WebSocket Connected")
        Task { @MainActor in
            WebSocketManager.shared.isConnected = true
            WebSocketManager.shared.isConnecting = false
            // 自动注册
            let regData: [String: Any] = [
                "action": "register",
                "req_id": UUID().uuidString,
                "data": [
                    "sn": WebSocketManager.shared.clientSN,
                    "type": "ios",
                    "role": "client",
                    "model": UIDevice.current.name,
                    "token": WebSocketManager.shared.userToken // 🔥
                ]
            ]
            WebSocketManager.shared.send(json: regData)
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor in
            WebSocketManager.shared.internalDisconnect()
            WebSocketManager.shared.scheduleReconnect()
        }
    }
}

// MARK: - 3. 远程控制扩展 (严格 Int 坐标)
extension WebSocketManager {
    // 密码管理
    func getDevicePassword(sn: String) {
        send(json: ["action": "get_device_password", "data": ["sn": sn]])
    }
    
    func setDevicePassword(sn: String, password: String) {
        send(json: ["action": "set_device_password", "data": ["sn": sn, "password": password]])
    }

    func sendTap(x: Double, y: Double, deviceSN: String) {
        // 强制转为 Int，匹配服务端需求
        let absX = Int(x * remoteWidth)
        let absY = Int(y * remoteHeight)
        
        let payload: [String: Any] = [
            "action": "device/control",
            "device_sn": deviceSN,
            "data": [
                "target_sn": deviceSN,
                "data": [
                    "target_sn": deviceSN,
                    "action": "click",
                    "x": absX, // Int
                    "y": absY  // Int
                ]
            ]
        ]
        send(json: payload)
    }
    
    func sendSwipe(start: CGPoint, end: CGPoint, deviceSN: String) {
        let x1 = Int(start.x * remoteWidth)
        let y1 = Int(start.y * remoteHeight)
        let x2 = Int(end.x * remoteWidth)
        let y2 = Int(end.y * remoteHeight)
        
        let payload: [String: Any] = [
            "action": "device/control",
            "device_sn": deviceSN,
            "data": [
                "target_sn": deviceSN,
                "data": [
                    "target_sn": deviceSN,
                    "action": "swipe",
                    "x1": x1, "y1": y1,
                    "x2": x2, "y2": y2,
                    "duration": 300
                ]
            ]
        ]
        send(json: payload)
    }
    
    // 输入文字
    func sendInputText(_ text: String, deviceSN: String) {
        let payload: [String: Any] = [
            "action": "device/control",
            "device_sn": deviceSN,
            "data": [
                "target_sn": deviceSN,
                "data": [
                    "target_sn": deviceSN,
                    "action": "text",
                    "text": text
                ]
            ]
        ]
        send(json: payload)
    }
    
    // Home / Back
    func sendAction(_ actionType: String, deviceSN: String) {
        let payload: [String: Any] = [
            "action": "device/control",
            "device_sn": deviceSN,
            "data": [
                "target_sn": deviceSN,
                "data": [
                    "target_sn": deviceSN,
                    "action": "keyevent",
                    "keyevent": actionType,
                ]
            ]
        ]
        send(json: payload)
    }
}

extension Notification.Name {
    static let startStream = Notification.Name("startStream")
    static let stopStream = Notification.Name("stopStream")
}
