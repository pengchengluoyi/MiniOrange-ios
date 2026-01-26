import SwiftUI
@preconcurrency import AVFoundation

// 🔥 新的二维码数据模型
struct ProvisioningQRData: Codable {
    let v: Int?       // version
    let type: String? // "provisioning"
    let n: String?    // Hostname
    let u: [String]   // URLs list
}

struct ConnectionView: View {
    @ObservedObject var wsManager = WebSocketManager.shared
    @State private var isScanning = false
    @State private var isProcessing = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var showSuccessAlert = false // 新增成功提示
    
    // 如果已经连接了 Server，我们就不跳转，而是弹窗提示"添加节点成功"
    @Environment(\.dismiss) var dismiss
    
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
            
            Text("Scan the QR code on your PC to bind it.")
                .multilineTextAlignment(.center)
                .foregroundColor(.gray)
                .padding(.horizontal)
            
            Button(action: {
                isScanning = true
                isProcessing = false
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
            
            if !ServerManager.shared.savedServers.isEmpty {
                Button("Use Saved Servers") {
                   onConnect() // 如果有缓存，允许跳过扫码直接进入
                }
                .padding(.top)
            }
        }
        .sheet(isPresented: $isScanning) {
            QRScannerView { code in
                isScanning = false
                handleScan(code)
            }
        }
        .overlay {
            if isProcessing {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                        Text("Configuring Device...")
                            .font(.headline)
                            .foregroundColor(.white)
                    }
                    .padding(30)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(16)
                }
            }
        }
        .alert("Configuration Failed", isPresented: $showErrorAlert) {
            Button("OK") { isProcessing = false }
        } message: {
            Text(errorMessage)
        }
    }
    
    private func handleScan(_ code: String) {
        guard !isProcessing else { return }
        isProcessing = true
        
        print("📸 [Scan] Code: \(code)")
        
        // 1. 第一步：先尝试解析 JSON
        // data(using:) 和 decode(...) 都会返回 Optional，所以这里用 guard let
        guard let data = code.data(using: .utf8),
              let qrData = try? JSONDecoder().decode(ProvisioningQRData.self, from: data) else {
            // 如果解析失败
            errorMessage = "Invalid QR Code format."
            showErrorAlert = true
            isProcessing = false
            return
        }

        // 🔥 获取所有可能的地址 (服务端已经过滤了无效的，剩下的都是潜在可用的)
        let candidates = qrData.u
        guard !candidates.isEmpty else {
            // ... 错误处理 ...
            return
        }
        
        print("🚦 [Race] 准备开始，候选列表: \(candidates)")
        
        // 🚀 启动异步任务进行赛马
        Task {
            // 1. 找出最快的地址
            if let winnerUrl = await WebSocketManager.shared.raceToFindFastestHost(urls: candidates) {
                
                // 2. 找到赢家，开始正常流程
                await MainActor.run {
                    print("🔗 [Connection] 使用优选线路: \(winnerUrl)")
                    
                    // 决策：配置 Master 还是 Node (逻辑保持不变)
                    let currentServer = ServerManager.shared.currentServer
                    let isConfiguringNode = (wsManager.isConnected && currentServer != nil)
                    
                    var masterUrlForTarget = ""
                    if isConfiguringNode {
                         masterUrlForTarget = currentServer!.u
                    } else {
                         masterUrlForTarget = winnerUrl // 赢家即是 Master
                    }
                    
                    Task {
                        do {
                            // 3. 使用赢家地址进行配网
                            try await wsManager.provisionDevice(targetAddress: winnerUrl, masterUrl: masterUrlForTarget)
                            
                            // 4. 后续保存逻辑...
                            try await Task.sleep(nanoseconds: 2 * 1_000_000_000)
                            
                            if !isConfiguringNode {
                                let newName = qrData.n ?? "New Server"
                                // ✅ 关键：保存的是这个测试通过的 winnerUrl
                                let config = ServerConfig(u: winnerUrl, name: newName)
                                ServerManager.shared.addServer(config)
                                ServerManager.shared.switchTo(config)
                                onConnect()
                            } else {
                                isProcessing = false
                            }
                        } catch {
                            // ... 错误处理 ...
                            isProcessing = false
                        }
                    }
                }
            } else {
                // 3. 赛马全部失败 (所有地址都连不上)
                await MainActor.run {
                    errorMessage = "无法连接到服务器。\n已尝试所有地址均超时。\n请检查防火墙或网络设置。"
                    showErrorAlert = true
                    isProcessing = false
                }
            }
        }
    }
}
// QRScannerView 保持不变...

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
