import SwiftUI

struct DashboardView: View {
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    
                    // 头部欢迎卡片
                    VStack(alignment: .leading, spacing: 12) {
                        Text("欢迎使用 MiniOrange")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("这就通过本应用，您可以轻松管理设备、进行远程投屏和控制。以下是快速上手指南。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineSpacing(4)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(16)
                    
                    // 指南部分
                    VStack(spacing: 20) {
                        GuideRow(
                            icon: "wifi",
                            color: .blue,
                            title: "1. 确保网络通畅",
                            content: "请确保您的 iOS 设备与目标设备（电脑/手机）已连接到服务器，且状态显示为“在线”。"
                        )
                        
                        GuideRow(
                            icon: "rectangle.inset.filled.and.person.filled",
                            color: .orange,
                            title: "2. 开始投屏",
                            content: "在“设备列表”页，点击在线的设备进入详情页。若设备支持，底部会显示“远程控制”按钮，点击即可查看实时画面。"
                        )
                        
                        GuideRow(
                            icon: "hand.tap.fill",
                            color: .green,
                            title: "3. 远程控制手势",
                            content: "• 点击屏幕：触发点击\n• 双指滑动：触发滚动\n• 长按：触发右键或长按菜单"
                        )
                        
                        GuideRow(
                            icon: "lock.shield.fill",
                            color: .purple,
                            title: "4. 安全设置",
                            content: "为了安全起见，建议在设备详情页设置“屏幕解锁密码”，以防止未授权的远程访问。"
                        )
                    }
                    .padding(.horizontal)
                    
                    // 底部版本信息
                    VStack(spacing: 8) {
                        Text("当前版本: v1.0.0")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Made with SwiftUI")
                            .font(.caption2)
                            .foregroundColor(Color(UIColor.tertiaryLabel))
                    }
                    .padding(.top, 40)
                }
                .padding(.vertical)
            }
            .navigationTitle("使用指南")
            .background(Color(.systemGroupedBackground))
        }
    }
}

// 辅助视图：单行指南组件
struct GuideRow: View {
    let icon: String
    let color: Color
    let title: String
    let content: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // 图标
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(color)
            }
            
            // 文字内容
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Text(content)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true) // 确保文字换行
            }
            Spacer()
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.03), radius: 5, x: 0, y: 2)
    }
}

// 预览
#Preview {
    DashboardView()
}
