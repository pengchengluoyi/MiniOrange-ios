import SwiftUI
import AVFoundation
import Combine  // ✅ 必须引入 Combine，否则无法使用 AnyCancellable

// MARK: - ToDesk 风格全屏控制页
struct RemoteControlView: View {
    let device: Device
    @State private var isMenuVisible = true // 菜单显隐
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 1. 黑色背景
                Color.black.ignoresSafeArea()
                
                // 2. 视频流
                H264StreamingView()
                    .edgesIgnoringSafeArea(.all)
                
                // 3. 透明触控层 (捕获手势)
                TouchControlLayer(geometry: geometry, deviceSN: device.sn) {
                    // 点击空白处切换菜单显示
                    withAnimation { isMenuVisible.toggle() }
                }
                
                // 4. 悬浮菜单栏
                if isMenuVisible {
                    VStack {
                        // 顶部栏
                        HStack {
                            Text(device.model)
                                .foregroundColor(.white)
                                .font(.headline)
                                .padding(8)
                                .background(.thinMaterial)
                                .cornerRadius(8)
                            Spacer()
                        }
                        .padding(.top, 50)
                        .padding(.horizontal)
                        
                        Spacer()
                        
                        // 底部功能栏
                        HStack(spacing: 40) {
                            ControlButton(icon: "house.fill", label: "主页") {
                                WebSocketManager.shared.sendKey(action: "device/control", deviceSN: device.sn, data: ["target_sn": device.sn, "data": ["action": "home", "target_sn": device.sn]])
                            }
                            ControlButton(icon: "arrow.uturn.backward", label: "返回") {
                                WebSocketManager.shared.sendKey(action: "device/control", deviceSN: device.sn, data: ["target_sn": device.sn, "data": ["action": "back", "target_sn": device.sn] ])
                            }
                        }
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(20)
                        .padding(.bottom, 30)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .tabBar) // 隐藏底部 Tab 栏
        .onAppear {
            let payload: [String: Any] = [
                "action": "start_stream",
                "data": [
                    "device_sn": device.sn,
                    "viewer_sn": WebSocketManager.shared.clientSN
                ]
            ]
            WebSocketManager.shared.send(json: payload)
        }
        .onDisappear {
            WebSocketManager.shared.send(json: ["action": "stop_stream"])
        }
    }
}

// MARK: - 触控逻辑层
struct TouchControlLayer: View {
    let geometry: GeometryProxy
    let deviceSN: String
    let onToggleMenu: () -> Void
    
    var body: some View {
        Color.white.opacity(0.001) // 极低透明度以接收事件
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        let width = geometry.size.width
                        let height = geometry.size.height
                        let distance = hypot(value.translation.width, value.translation.height)
                        
                        if distance < 10 {
                            // 点击
                            let nx = value.startLocation.x / width
                            let ny = value.startLocation.y / height
                            print("👆 Tap: \(nx), \(ny)")
                            WebSocketManager.shared.sendTap(x: nx, y: ny, deviceSN: deviceSN)
                            onToggleMenu()
                        } else {
                            // 滑动
                            let startX = value.startLocation.x / width
                            let startY = value.startLocation.y / height
                            let endX = value.location.x / width
                            let endY = value.location.y / height
                            print("↔️ Swipe")
                            WebSocketManager.shared.sendSwipe(
                                start: CGPoint(x: startX, y: startY),
                                end: CGPoint(x: endX, y: endY),
                                deviceSN: deviceSN
                            )
                        }
                    }
            )
    }
}

// MARK: - 组件
struct ControlButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2)
                Text(label).font(.caption)
            }
            .foregroundColor(.white)
            .frame(width: 60)
        }
    }
}

// MARK: - H.264 播放器视图封装
struct H264StreamingView: UIViewRepresentable {
    func makeUIView(context: Context) -> H264PlayerUIView {
        return H264PlayerUIView()
    }
    func updateUIView(_ uiView: H264PlayerUIView, context: Context) {}
}

class H264PlayerUIView: UIView {
    private lazy var displayLayer: AVSampleBufferDisplayLayer = {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        return layer
    }()
    
    // 引用 H264Decoder.swift 中的类
    private let decoder = H264Decoder()
    // ✅ 修复：正确使用 AnyCancellable
    private var cancellables = Set<AnyCancellable>()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayer()
        setupSubscription()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
        setupSubscription()
    }
    
    private func setupLayer() {
        layer.addSublayer(displayLayer)
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
    }
    
    private func setupSubscription() {
        decoder.onNewSampleBuffer = { [weak self] safeBuffer in
            let sampleBuffer = safeBuffer.sampleBuffer
            DispatchQueue.main.async {
                self?.enqueue(sampleBuffer)
            }
        }
        
        let decoder = self.decoder
        WebSocketManager.shared.videoFrameSubject
            .sink { [weak decoder] data in
                decoder?.handleData(data)
            }
            .store(in: &cancellables)
    }
    
    private func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if #available(iOS 17.0, *) {
            if displayLayer.sampleBufferRenderer.status == .failed {
                displayLayer.sampleBufferRenderer.flush()
            }
            if displayLayer.sampleBufferRenderer.status != .failed {
                displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
            }
        } else {
            if displayLayer.status == .failed { displayLayer.flush() }
            if displayLayer.status != .failed { displayLayer.enqueue(sampleBuffer) }
        }
    }
}
