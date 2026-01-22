import SwiftUI

struct DeviceDetailView: View {
    let device: Device
    @State private var password = ""
    @State private var navigateToRemote = false
    @Environment(\.presentationMode) var presentationMode
    
    var isOnline: Bool {
        return device.status == "online"
    }
    
    var body: some View {
        Form {
            Section(header: Text("设备代码")) {
                HStack {
                    Text(device.sn)
                        .font(.system(.title2, design: .monospaced))
                        .fontWeight(.bold)
                    Spacer()
                    Button(action: { UIPasteboard.general.string = device.sn }) {
                        Image(systemName: "doc.on.doc").foregroundColor(.blue)
                    }
                }
            }
            
            Section(header: Text("屏幕解锁密码"), footer: Text("设置设备锁屏密码，远程控制时可用于解锁")) {
                HStack {
                    SecureField("输入解锁密码", text: $password)
                        .onSubmit { WebSocketManager.shared.setDevicePassword(sn: device.sn, password: password) }
                    
                    if !password.isEmpty {
                        Button("保存") { WebSocketManager.shared.setDevicePassword(sn: device.sn, password: password) }
                            .font(.caption).buttonStyle(.bordered)
                    }
                }
            }
            
            Section(header: Text("设备信息")) {
                HStack { Text("名称"); Spacer(); Text(device.model).foregroundColor(.gray) }
                HStack {
                    Text("状态")
                    Spacer()
                    Text(device.status)
                        .foregroundColor(isOnline ? .green : .gray)
                        .fontWeight(isOnline ? .bold : .regular)
                }
            }
            
            Section {
                Button(role: .destructive, action: {}) {
                    Text("删除设备").frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("设备详情")
        // ✅ 核心逻辑：这里强制隐藏。
        // 因为父页面的 visible 现在没有锁死整个导航栈，所以这里的 hidden 优先级生效。
        .toolbar(.hidden, for: .tabBar)
        
        .safeAreaInset(edge: .bottom) {
            VStack {
                if isOnline {
                    Button(action: { navigateToRemote = true }) {
                        Text("远程控制")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .cornerRadius(12)
                    }
                } else {
                    Text("设备已离线，无法投屏")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(12)
                }
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .background(
            NavigationLink(destination: RemoteControlView(device: device), isActive: $navigateToRemote) { EmptyView() }
        )
        .onAppear {
            if isOnline {
                WebSocketManager.shared.getDevicePassword(sn: device.sn)
            }
        }
        .onReceive(WebSocketManager.shared.passwordSubject) { pwd in
            self.password = pwd
        }
    }
}
