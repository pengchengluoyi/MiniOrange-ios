import Foundation
import Combine
import UIKit

// MARK: - 必须添加 URLSessionWebSocketDelegate 协议
@MainActor
class WebSocketManager: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    static let shared = WebSocketManager()
    
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
        super.init()
        let config = URLSessionConfiguration.default
        // self 现在遵循协议了，不会报错
        session = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue())
    }
    
    // MARK: - 1. 恢复 setup 方法 (解决 MiniOrangeApp 报错)
    func setup(url: String, token: String) {
        clearState()
        guard let baseURL = URL(string: url) else { return }
        self.serverName = baseURL.host ?? "Unknown"
        self.serverIP = baseURL.host ?? "Unknown" // ✅ 赋值
        
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        if components?.queryItems == nil { components?.queryItems = [] }
        components?.queryItems?.append(URLQueryItem(name: "token", value: token))
        
        if let fullURL = components?.url {
            connect(url: fullURL)
        }
    }
    // ✅ 新增：清理状态，防止不同 Server 数据混淆
    func clearState() {
        self.deviceListSubject.send([]) // 清空设备列表
        self.workflowSubject.send([])   // 清空 Dashboard
        self.isConnected = false
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
                // 1. 缩短间隔到 3秒 (防止网络抖动导致的超时)
                try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                
                guard let self = self, self.isConnected else { return }
                
                // 2. 发送协议层 Ping (底层保活)
                self.webSocketTask?.sendPing { error in
                    if let error = error {
                        print("❌ Ping failed: \(error)")
                        Task { @MainActor in self.internalDisconnect(); self.scheduleReconnect() }
                    }
                }
                
                // 3. 🔥 发送业务层心跳 (强制刷新服务端状态)
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
                case .failure:
                    self.internalDisconnect()
                    self.scheduleReconnect()
                case .success(let message):
                    switch message {
                    case .string(let text): self.handleMessage(text)
                    case .data(let data): self.videoFrameSubject.send(data)
                    @unknown default: break
                    }
                    self.receiveMessage()
                }
            }
        }
    }
    
    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else { return }
        
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
                    "model": UIDevice.current.name
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
                    "action": actionType
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
