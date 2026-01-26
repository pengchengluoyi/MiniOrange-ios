import SwiftUI
import Combine

class DeviceListViewModel: ObservableObject {
    @Published var devices: [Device] = []
    private var timerCancellable: AnyCancellable?
    
    init() {
        WebSocketManager.shared.deviceListSubject
            .receive(on: DispatchQueue.main)
            .assign(to: &$devices)
        
        timerCancellable = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshIfConnected() }
    }
    
    func refreshIfConnected() {
        // ✅ 恢复：如果已下线，停止轮询，避免刷屏报错
        if WebSocketManager.shared.isConnected && !WebSocketManager.shared.isDeviceOfflineFromCluster {
            fetchDevices()
        }
    }
    
    func fetchDevices() {
        WebSocketManager.shared.send(json: ["action": "get_device_list"])
    }
}

struct DeviceListView: View {
    @StateObject var viewModel = DeviceListViewModel()
    @State private var showMyDeviceSettings = false
    
    var myDevice: Device? {
        viewModel.devices.first { $0.sn == WebSocketManager.shared.clientSN }
    }
    
    var remoteDevices: [Device] {
        viewModel.devices
            .filter { $0.sn != WebSocketManager.shared.clientSN }
            .sorted { d1, d2 in
                if d1.status == "online" && d2.status != "online" { return true }
                if d1.status != "online" && d2.status == "online" { return false }
                return d1.model < d2.model
            }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(UIColor.systemGroupedBackground).ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        if let myDevice = myDevice {
                            MyDeviceCard(device: myDevice) { showMyDeviceSettings = true }
                                .padding(.horizontal)
                        }
                        
                        if !remoteDevices.isEmpty {
                            VStack(alignment: .leading) {
                                Text("在线设备").font(.caption).foregroundColor(.secondary).padding(.leading)
                                LazyVStack(spacing: 12) {
                                    ForEach(remoteDevices) { device in
                                        NavigationLink(destination: DeviceDetailView(device: device)) {
                                            RemoteDeviceRow(device: device)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                    }
                                }
                            }
                            .padding(.horizontal)
                        } else {
                            EmptyStateView()
                        }
                    }
                    .padding(.top)
                }
            }
            .navigationTitle("设备列表")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { viewModel.fetchDevices() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showMyDeviceSettings) {
                if let device = myDevice {
                    MyDeviceSettingsView(device: device)
                }
            }
        }
        .showOfflineBanner() // ✅ 恢复 Banner
        .onAppear {
            // 强制刷新一次
            if WebSocketManager.shared.isConnected { viewModel.fetchDevices() }
        }
        .onReceive(WebSocketManager.shared.$isConnected) { if $0 { viewModel.fetchDevices() } }
    }
}

// 辅助视图
struct RemoteDeviceRow: View {
    let device: Device
    
    var iconName: String {
        let m = device.model.lowercased()
        if m.contains("win") || m.contains("pc") || m.contains("desktop") { return "desktopcomputer" }
        if m.contains("mac") || m.contains("book") { return "laptopcomputer" }
        if m.contains("ipad") || m.contains("tablet") { return "ipad" }
        if m.contains("android") || m.contains("pixel") || m.contains("galaxy") { return "phone.connection" }
        return "iphone"
    }
    
    var body: some View {
        HStack {
            Image(systemName: iconName)
                .foregroundColor(.blue)
                .font(.title2)
                .frame(width: 30)
            
            VStack(alignment: .leading) {
                Text(device.model).font(.headline)
                Text(device.sn).font(.caption).foregroundColor(.gray)
            }
            Spacer()
            Circle().fill(device.status == "online" ? Color.green : Color.gray).frame(width: 8, height: 8)
        }
        .padding()
        .background(Color.white)
        .cornerRadius(10)
    }
}

struct EmptyStateView: View {
    var body: some View { Text("暂无设备").foregroundColor(.gray).padding(.top, 50) }
}

struct MyDeviceCard: View {
    let device: Device
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("本机设备").font(.headline).foregroundColor(.white)
                        Text("在线").font(.caption2).padding(4).background(Color.green).foregroundColor(.white).cornerRadius(4)
                    }
                    Text("SN: \(device.sn)").font(.caption).foregroundColor(.white.opacity(0.8))
                }
                Spacer()
                Image(systemName: "iphone").font(.largeTitle).foregroundColor(.white)
            }
            .padding()
            .background(LinearGradient(gradient: Gradient(colors: [.blue, .purple]), startPoint: .leading, endPoint: .trailing))
            .cornerRadius(16)
        }
    }
}

struct MyDeviceSettingsView: View {
    let device: Device
    @Environment(\.presentationMode) var mode
    var body: some View {
        NavigationView {
            List { HStack { Text("SN"); Spacer(); Text(device.sn) } }
            .navigationTitle("本机设置")
            .navigationBarItems(trailing: Button("关闭") { mode.wrappedValue.dismiss() })
        }
    }
}
