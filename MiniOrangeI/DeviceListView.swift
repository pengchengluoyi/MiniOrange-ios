import SwiftUI
import Combine
import AVFoundation

class DeviceListViewModel: ObservableObject {
    @Published var devices: [Device] = []
    
    init() {
        WebSocketManager.shared.deviceListSubject
            .receive(on: DispatchQueue.main)
            .assign(to: &$devices)
    }
    
    func fetchDevices() {
        WebSocketManager.shared.send(json: ["action": "get_device_list"])
    }
}

struct DeviceListView: View {
    @StateObject var viewModel = DeviceListViewModel()
    
    var body: some View {
        NavigationView {
            List(viewModel.devices) { device in
                // 这里引用的是另一个文件里的 RemoteControlView
                NavigationLink(destination: RemoteControlView(device: device)) {
                    HStack {
                        // 设备图标
                        Image(systemName: getDeviceIcon(type: device.model))
                            .font(.title2)
                            .foregroundColor(.blue)
                            .frame(width: 40)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(device.model).font(.headline)
                                
                                // 显示“本设备”字样
                                if device.sn == WebSocketManager.shared.clientSN {
                                    Text("本设备")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.1))
                                        .foregroundColor(.blue)
                                        .cornerRadius(4)
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.blue, lineWidth: 0.5))
                                }
                            }
                            Text("SN: \(device.sn)").font(.caption).foregroundColor(.gray)
                        }
                        Spacer()
                        Circle()
                            .fill(device.status == "online" ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("设备列表")
            .refreshable { viewModel.fetchDevices() }
        }
        .onAppear {
            if WebSocketManager.shared.isConnected { viewModel.fetchDevices() }
        }
        .onReceive(WebSocketManager.shared.$isConnected) { connected in
            if connected { viewModel.fetchDevices() }
        }
    }
    
    func getDeviceIcon(type: String) -> String {
        let t = type.lowercased()
        if t.contains("ios") || t.contains("iphone") { return "iphone" }
        if t.contains("android") { return "candybarphone" }
        return "desktopcomputer"
    }
}
