import SwiftUI
import AVFoundation
import Combine

struct RemoteControlView: View {
    let device: Device
    @Environment(\.presentationMode) var presentationMode
    
    // UI状态
    @State private var isMenuExpanded = false
    @State private var isVideoReady = false
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                
                H264StreamingView(isVideoReady: $isVideoReady)
                    .edgesIgnoringSafeArea(.all)
                    .opacity(isVideoReady ? 1 : 0)
                
                if !isVideoReady {
                    ConnectingView().transition(.opacity)
                }
                
                if isVideoReady {
                    TouchControlLayer(geometry: geometry, deviceSN: device.sn) {
                        withAnimation { isMenuExpanded.toggle() }
                    }
                }
                
                // 隐形输入框
                TextField("", text: $inputText)
                    .focused($isInputFocused)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .onChange(of: inputText) { newValue in
                        if !newValue.isEmpty {
                            WebSocketManager.shared.sendInputText(newValue, deviceSN: device.sn)
                            inputText = ""
                        }
                    }
                
                if isVideoReady {
                    SideControlMenu(
                        isExpanded: $isMenuExpanded,
                        deviceSN: device.sn,
                        onDisconnect: { disconnect() },
                        onToggleKeyboard: { isInputFocused.toggle() }
                    )
                }
            }
        }
        .navigationBarHidden(true)
        // ✅ 需求1: 隐藏 TabBar
        .toolbar(.hidden, for: .tabBar)
        // ✅ 需求2: 菜单收起时，自动收起键盘
        .onChange(of: isMenuExpanded) { expanded in
            if !expanded {
                isInputFocused = false
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            WebSocketManager.shared.send(json: ["action": "start_stream", "data": ["device_sn": device.sn, "viewer_sn": WebSocketManager.shared.clientSN]])
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            WebSocketManager.shared.send(json: ["action": "stop_stream"])
        }
    }
    
    func disconnect() {
        WebSocketManager.shared.send(json: ["action": "stop_stream"])
        presentationMode.wrappedValue.dismiss()
    }
}

// MARK: - 子组件

struct SideControlMenu: View {
    @Binding var isExpanded: Bool
    let deviceSN: String
    let onDisconnect: () -> Void
    let onToggleKeyboard: () -> Void
    
    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: 15) {
                if isExpanded {
                    Group {
                        MenuButton(icon: "xmark.circle.fill", color: .red, label: "断开", action: onDisconnect)
                        MenuButton(icon: "keyboard", label: "键盘", action: onToggleKeyboard)
                        MenuButton(icon: "square.stack.3d.up", label: "后台") {
                            WebSocketManager.shared.sendAction("app_switch", deviceSN: deviceSN)
                        }
                        MenuButton(icon: "house.fill", label: "桌面") {
                            WebSocketManager.shared.sendAction("home", deviceSN: deviceSN)
                        }
                        MenuButton(icon: "arrow.uturn.backward", label: "返回") {
                            WebSocketManager.shared.sendAction("back", deviceSN: deviceSN)
                        }
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                Button(action: { withAnimation(.spring()) { isExpanded.toggle() } }) {
                    Image(systemName: isExpanded ? "chevron.right" : "chevron.left")
                        .font(.title2).foregroundColor(.white).frame(width: 44, height: 44)
                        .background(Color.blue.opacity(0.8)).clipShape(Circle()).shadow(radius: 4)
                }
            }
            .padding(.trailing, 16)
        }
    }
}

struct MenuButton: View {
    let icon: String
    var color: Color = .white
    var label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.title2).frame(width: 44, height: 44).background(.ultraThinMaterial).clipShape(Circle())
                Text(label).font(.system(size: 10)).foregroundColor(.white).shadow(radius: 1)
            }
        }.foregroundColor(color)
    }
}

struct ConnectingView: View {
    @State private var progress = 0.0
    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    var body: some View {
        ZStack {
            Color(UIColor.systemBackground).ignoresSafeArea()
            VStack(spacing: 30) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 60)).foregroundColor(.blue).symbolEffect(.bounce, options: .repeating)
                Text("正在建立安全连接...").font(.headline).foregroundColor(.secondary)
                VStack(spacing: 8) {
                    ProgressView(value: progress, total: 100).tint(.blue).frame(width: 200)
                    Text("\(Int(progress))%").font(.caption).foregroundColor(.gray)
                }
            }
        }.onReceive(timer) { _ in if progress < 95 { progress += Double.random(in: 2...5) } }
    }
}

struct TouchControlLayer: View {
    let geometry: GeometryProxy
    let deviceSN: String
    let onToggleMenu: () -> Void
    var body: some View {
        Color.white.opacity(0.001)
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                let w = geometry.size.width
                let h = geometry.size.height
                let dist = hypot(value.translation.width, value.translation.height)
                if dist < 10 {
                    WebSocketManager.shared.sendTap(x: value.startLocation.x / w, y: value.startLocation.y / h, deviceSN: deviceSN)
                } else {
                    let start = CGPoint(x: value.startLocation.x / w, y: value.startLocation.y / h)
                    let end = CGPoint(x: value.location.x / w, y: value.location.y / h)
                    WebSocketManager.shared.sendSwipe(start: start, end: end, deviceSN: deviceSN)
                }
            })
            .onTapGesture(count: 2) { onToggleMenu() }
    }
}

struct H264StreamingView: UIViewRepresentable {
    @Binding var isVideoReady: Bool
    func makeUIView(context: Context) -> H264PlayerUIView {
        let view = H264PlayerUIView()
        view.onFirstFrameReceived = { DispatchQueue.main.async { self.isVideoReady = true } }
        return view
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
    private let decoder = H264Decoder()
    private var cancellable: Any?
    var onFirstFrameReceived: (() -> Void)?
    private var hasReceivedFirstFrame = false
    
    override init(frame: CGRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }
    
    private func setup() {
        layer.addSublayer(displayLayer)
        var controlTimebase: CMTimebase?
        CMTimebaseCreateWithMasterClock(allocator: kCFAllocatorDefault, masterClock: CMClockGetHostTimeClock(), timebaseOut: &controlTimebase)
        if let tb = controlTimebase {
            displayLayer.controlTimebase = tb
            CMTimebaseSetTime(tb, time: CMTime.zero)
            CMTimebaseSetRate(tb, rate: 1.0)
        }
        decoder.onNewSampleBuffer = { [weak self] sb in DispatchQueue.main.async { self?.enqueue(sb.sampleBuffer) } }
        cancellable = WebSocketManager.shared.videoFrameSubject.sink { [weak decoder] data in decoder?.handleData(data) }
    }
    
    override func layoutSubviews() { super.layoutSubviews(); displayLayer.frame = bounds }
    
    private func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if displayLayer.status == .failed { displayLayer.flush() }
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
            if !hasReceivedFirstFrame { hasReceivedFirstFrame = true; onFirstFrameReceived?() }
        }
    }
}
