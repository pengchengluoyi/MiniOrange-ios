import Foundation
import Combine
import UIKit

@MainActor
class WebSocketManager: NSObject, ObservableObject {
    static let shared = WebSocketManager()
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var lastURL: URL?
    
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var serverName: String = "Unknown"
    
    let workflowSubject = PassthroughSubject<[WorkflowItem], Never>()
    let toastSubject = PassthroughSubject<String, Never>()
    let deviceListSubject = PassthroughSubject<[Device], Never>()
    let videoFrameSubject = PassthroughSubject<Data, Never>()
    
    // Stores the Viewer SN received from 'start_stream' command
    var currentViewerSN: String?
    
    let clientSN: String
    
    override init() {
        self.clientSN = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        super.init()
        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue())
    }
    
    func setup(url: String, token: String) {
        print("🔧 [WebSocketManager] Setup called with URL: \(url)")
        guard let baseURL = URL(string: url) else { return }
        self.serverName = baseURL.host ?? "Unknown"
        
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        if components?.queryItems == nil {
            components?.queryItems = []
        }
        components?.queryItems?.append(URLQueryItem(name: "token", value: token))
        
        if let fullURL = components?.url {
            connect(url: fullURL)
        }
    }
    
    func connect(url: URL) {
        // Cancel any pending reconnect task since we are connecting now
        reconnectTask?.cancel()
        reconnectTask = nil
        
        // Perform internal cleanup but don't clear lastURL (unless we want to overwrite it, which we do below)
        internalDisconnect()
        
        lastURL = url
        
        isConnecting = true
        print("🚀 [WebSocketManager] Connecting to \(url)")
        webSocketTask = session?.webSocketTask(with: url)
        webSocketTask?.resume()
        
        receiveMessage()
        startHeartbeat()
    }
    
    func disconnect() {
        // User initiated disconnect - stop auto-reconnect
        lastURL = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        internalDisconnect()
    }
    
    private func internalDisconnect() {
        isConnecting = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        pingTask?.cancel()
        pingTask = nil
        self.isConnected = false
    }
    
    private func scheduleReconnect() {
        guard let url = lastURL else { return }
        guard reconnectTask == nil else { return } // Already scheduled
        
        print("⚠️ [WebSocketManager] Connection lost. Reconnecting in 3s...")
        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
            if !Task.isCancelled {
                self.reconnectTask = nil
                self.connect(url: url)
            }
        }
    }
    
    func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: []),
              let string = String(data: data, encoding: .utf8) else { return }
        print("⬆️ [WebSocketManager] Sending JSON: \(string)")
        
        let message = URLSessionWebSocketTask.Message.string(string)
        webSocketTask?.send(message) { error in
            if let error = error {
                print("❌ [WebSocketManager] Send JSON error: \(error)")
            }
        }
    }
    
    func send(data: Data) {
        let message = URLSessionWebSocketTask.Message.data(data)
        webSocketTask?.send(message) { error in
            if let error = error {
                print("❌ [WebSocketManager] Send Binary error: \(error)")
            }
        }
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                switch result {
                case .failure(let error):
                    print("❌ [WebSocketManager] Receive error: \(error)")
                    self.internalDisconnect()
                    self.scheduleReconnect()
                    
                case .success(let message):
                    switch message {
                    case .string(let text):
                        print("⬇️ [WebSocketManager] Received text: \(text)")
                        self.handleMessage(text)
                    case .data(let data):
                        // 🔥 必须处理 .data 类型，并分发给 videoFrameSubject
                        print("⬇️ [WebSocketManager] Received binary data: \(data.count) bytes")
                        self.videoFrameSubject.send(data)
                    @unknown default:
                        break
                    }
                    self.receiveMessage()
                }
            }
        }
    }
    
    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            print("❌ [WebSocketManager] Failed to parse message: \(text)")
            return
        }
        
        print("✅ [WebSocketManager] Handling action: \(action)")
        
        if action == "start_stream" {
            if let dataDict = json["data"] as? [String: Any],
               let viewerSN = dataDict["viewer_sn"] as? String {
                self.currentViewerSN = viewerSN
                NotificationCenter.default.post(name: .startStream, object: nil)
            }
        } else if action == "stop_stream" {
            NotificationCenter.default.post(name: .stopStream, object: nil)
        } else if action == "app_graph/list" {
            if let data = json["data"] as? [[String: Any]] {
                let items = data.compactMap { dict -> WorkflowItem? in
                    guard let id = dict["id"] as? String,
                          let name = dict["name"] as? String,
                          let icon = dict["icon"] as? String else { return nil }
                    return WorkflowItem(id: id, name: name, icon: icon, color: dict["color"] as? String)
                }
                workflowSubject.send(items)
            }
        } else if action == "device_list" || action == "get_device_list" {
            if let data = json["data"] as? [[String: Any]] {
                let devices = data.compactMap { dict -> Device? in
                    guard let sn = dict["sn"] as? String,
                          let model = dict["model"] as? String,
                          let status = dict["status"] as? String else { return nil }
                    return Device(sn: sn, model: model, status: status)
                }
                deviceListSubject.send(devices)
            }
        }
    }
    
    private func startHeartbeat() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                if Task.isCancelled { return }
                
                self.webSocketTask?.sendPing { [weak self] error in
                    if let error = error {
                        print("❌ [WebSocketManager] Ping failed: \(error)")
                        Task { @MainActor in
                            self?.internalDisconnect()
                            self?.scheduleReconnect()
                        }
                    }
                }
            }
        }
    }
    
    private func sendRegistration() {
        let device = UIDevice.current
        let sn = clientSN
        
        let regData: [String: Any] = [
            "action": "register",
            "req_id": UUID().uuidString,
            "data": [
                "sn": sn,
                "type": "ios",
                "role": "client",
                "model": device.name,
                "name": device.name,
                "ip": "192.168.1.100", // Simplified for demo; use getifaddrs for real IP
                "os_version": device.systemVersion
            ]
        ]
        send(json: regData)
    }
}

extension WebSocketManager: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("✅ [WebSocketManager] Connected")
        Task { @MainActor in
            WebSocketManager.shared.isConnected = true
            WebSocketManager.shared.isConnecting = false
            WebSocketManager.shared.sendRegistration()
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        print("🔌 [WebSocketManager] Disconnected: \(closeCode)")
        Task { @MainActor in
            WebSocketManager.shared.internalDisconnect()
            WebSocketManager.shared.scheduleReconnect()
        }
    }
}

extension Notification.Name {
    static let startStream = Notification.Name("startStream")
    static let stopStream = Notification.Name("stopStream")
}

// MARK: - Remote Control Commands
extension WebSocketManager {
    /// 发送点击事件
    /// - Parameters:
    ///   - x: 归一化 X 坐标 (0.0 - 1.0)
    ///   - y: 归一化 Y 坐标 (0.0 - 1.0)
    func sendClick(x: Double, y: Double) {
        let payload: [String: Any] = [
            "action": "input",
            "type": "touch", // 或者 "click"
            "data": [
                "event": "tap",
                "x": x,
                "y": y
            ]
        ]
        send(json: payload)
    }

    /// 发送滚动/滑动事件
    /// - Parameters:
    ///   - dx: X轴偏移量
    ///   - dy: Y轴偏移量
    func sendScroll(dx: Double, dy: Double) {
        let payload: [String: Any] = [
            "action": "input",
            "type": "scroll",
            "data": [
                "dx": dx,
                "dy": dy
            ]
        ]
        send(json: payload)
    }

    /// 发送按键事件 (Home, Back 等)
    func sendKey(_ key: String) {
        let payload: [String: Any] = [
            "action": "input",
            "type": "key",
            "data": [
                "key": key
            ]
        ]
        send(json: payload)
    }
}

// MARK: - 远程控制协议 (适配 Python ADB)
extension WebSocketManager {
    
    // 假设被控端分辨率 (建议后期让服务器在 get_device_list 里返回真实宽和高)
    // 这里暂时按主流 Android 分辨率设置，否则坐标会点歪
    var remoteWidth: Double { 1080.0 }
    var remoteHeight: Double { 2400.0 }
    
    /// 发送点击 (对应 Python: action == "click")
    /// - Parameters:
    ///   - x: 归一化坐标 (0.0 - 1.0)
    ///   - y: 归一化坐标 (0.0 - 1.0)
    func sendTap(x: Double, y: Double, deviceSN: String) {
        // 1. 转换为目标设备分辨率的绝对坐标 (Int)
        let absX = Int(x * remoteWidth)
        let absY = Int(y * remoteHeight)
        
        let payload: [String: Any] = [
            "action": "device/control",
            "sn": deviceSN,
            "req_id": UUID().uuidString,
            "data": [
                "target_sn": deviceSN,
                "data": [
                    "action": "click",
                    "target_sn": deviceSN,
                    "x": absX,     // 🔥 发送 Int
                    "y": absY
                ]
            ]
                
        ]
        send(json: payload)
    }
    
    /// 发送滑动 (对应 Python: action == "swipe")
    /// - Parameters:
    ///   - startPoint: 起始点 (归一化)
    ///   - endPoint: 结束点 (归一化)
    func sendSwipe(start: CGPoint, end: CGPoint, deviceSN: String) {
        let x1 = Int(start.x * remoteWidth)
        let y1 = Int(start.y * remoteHeight)
        let x2 = Int(end.x * remoteWidth)
        let y2 = Int(end.y * remoteHeight)
        
        let payload: [String: Any] = [
            "action": "device/control",
            "sn": deviceSN,
            "req_id": UUID().uuidString,
            "data": [
                "target_sn": deviceSN,
                "data": [
                    "action": "swipe",
                    "target_sn": deviceSN,
                    "x1": x1,
                    "y1": y1,
                    "x2": x2,
                    "y2": y2,
                    "duration": 300 // 默认 300ms
                ]
            ]
                
        ]
        send(json: payload)
    }
    
    /// 发送按键 (对应 Python: action == "home" / "back")
    func sendKey(action: String, deviceSN: String, data: [String: Any]) {
        let payload: [String: Any] = [
            "action": action, // 🔥 直接传 "home" 或 "back"
            "device_sn": deviceSN,
            "req_id": UUID().uuidString,
            "data": data // 空数据防止解析报错
        ]
        send(json: payload)
    }
}
