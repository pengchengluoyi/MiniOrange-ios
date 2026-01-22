import SwiftUI
@preconcurrency import AVFoundation

struct ConnectionView: View {
    // 监听 WebSocketManager 状态，以便在连接成功/失败时做出反应
    @ObservedObject var wsManager = WebSocketManager.shared
    @State private var isScanning = false
    @State private var isProcessing = false // 新增：防止重复处理
    @State private var showErrorAlert = false // 控制错误弹窗
    @State private var errorMessage = ""
    @State private var tempConfig: ConnectionConfig? // 临时存储配置，连接成功后再保存
    @AppStorage("connectionConfig") private var storedConfigData: Data = Data()
    
    var onConnect: () -> Void
    
    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "server.rack")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .foregroundColor(.orange)
            
            Text("MiniOrange Client")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Scan the QR code on your PC server to connect.")
                .multilineTextAlignment(.center)
                .foregroundColor(.gray)
                .padding(.horizontal)
            
            Button(action: {
                isScanning = true
                isProcessing = false // 重置状态
            }) {
                HStack {
                    Image(systemName: "qrcode.viewfinder")
                    Text("Scan QR Code")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.blue)
                .cornerRadius(12)
            }
            .padding(.horizontal, 40)
        }
        .sheet(isPresented: $isScanning) {
            QRScannerView { code in
                isScanning = false
                handleScan(code)
            }
        }
        // Loading 遮罩：当正在连接时显示
        .overlay {
            if wsManager.isConnecting {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                        Text("Connecting to Server...")
                            .font(.headline)
                            .foregroundColor(.white)
                    }
                    .padding(30)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(16)
                }
            }
        }
        // 错误弹窗
        .alert("Connection Failed", isPresented: $showErrorAlert) {
            Button("OK") {
                isProcessing = false // 重置处理状态，允许再次扫码
            }
        } message: {
            Text(errorMessage)
        }
        // 监听连接状态变化
        .onChange(of: wsManager.isConnected, initial: false) { _, connected in
            if connected, let config = tempConfig {
                print("✅ 连接成功，保存配置并进入主界面")
                // 只有连接成功才保存配置
                if let encoded = try? JSONEncoder().encode(config) {
                    storedConfigData = encoded
                    // 触发 App 入口切换视图
                }
            }
        }
        // 监听连接过程结束（用于捕获失败）
        .onChange(of: wsManager.isConnecting, initial: false) { _, connecting in
            // 如果连接过程结束，但未连接成功，且我们有待处理的配置，说明连接失败
            if !connecting && !wsManager.isConnected && tempConfig != nil {
                print("❌ 连接尝试失败")
                errorMessage = "Unable to connect to server.\nPlease check your network, URL, or server status."
                showErrorAlert = true
                tempConfig = nil // 清除临时配置
            }
        }
    }
    
    private func handleScan(_ code: String) {
        guard !isProcessing else { return } // 如果正在处理，直接忽略后续扫描
        isProcessing = true
        
        print("📸 [ConnectionView] 扫描到的原始数据: \(code)")
        
        guard let data = code.data(using: .utf8),
              let config = try? JSONDecoder().decode(ConnectionConfig.self, from: data) else {
            print("❌ [ConnectionView] 二维码格式错误，无法解析 JSON")
            return
        }
        
        print("✅ [ConnectionView] 解析成功! Token: \(config.t)")
        print("🔗 [ConnectionView] 目标服务器: \(config.u)")
        
        // 优化：不立即保存配置，而是先尝试连接
        self.tempConfig = config
        // 调用 setup 会触发 connect()，并更新 isConnecting 状态
        WebSocketManager.shared.setup(url: config.u, token: config.t)
    }
}

// MARK: - QR Scanner Helper
struct QRScannerView: UIViewControllerRepresentable {
    var didFindCode: (String) -> Void
    
    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }
    
    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(didFindCode: didFindCode)
    }
    
    class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var didFindCode: (String) -> Void
        var hasFound = false // 新增：Coordinator 级别的防抖
        
        init(didFindCode: @escaping (String) -> Void) {
            self.didFindCode = didFindCode
        }
        
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !hasFound else { return } // 忽略后续帧
            
            if let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
               let stringValue = metadataObject.stringValue {
                hasFound = true
                // 震动反馈，提示用户已扫码
                AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
                didFindCode(stringValue)
            }
        }
    }
}

class ScannerViewController: UIViewController {
    var captureSession: AVCaptureSession!
    var previewLayer: AVCaptureVideoPreviewLayer!
    weak var delegate: AVCaptureMetadataOutputObjectsDelegate?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        checkPermissionsAndSetup()
    }
    
    private func checkPermissionsAndSetup() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async { self?.setupCamera() }
                }
            }
        case .denied, .restricted:
            print("❌ 摄像头权限被拒绝")
        @unknown default:
            break
        }
    }
    
    private func setupCamera() {
        captureSession = AVCaptureSession()
        
        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video),
              let videoInput = try? AVCaptureDeviceInput(device: videoCaptureDevice) else {
            print("❌ 无法初始化摄像头 (可能是模拟器或硬件问题)")
            return
        }
        
        if captureSession.canAddInput(videoInput) { captureSession.addInput(videoInput) }
        
        let metadataOutput = AVCaptureMetadataOutput()
        if captureSession.canAddOutput(metadataOutput) {
            captureSession.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(delegate, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
        }
        
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.frame = view.layer.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        
        guard let session = self.captureSession else { return }
        DispatchQueue.global(qos: .background).async {
            session.startRunning()
        }    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if previewLayer != nil { previewLayer.frame = view.layer.bounds }
    }
}
