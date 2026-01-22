import SwiftUI
import Combine

class DashboardViewModel: ObservableObject {
    @Published var workflows: [WorkflowItem] = []
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        WebSocketManager.shared.workflowSubject
            .receive(on: DispatchQueue.main)
            .assign(to: &$workflows)
    }
    
    func fetchWorkflows() {
        // 修正：服务端 wsmap 对应的是 app_graph/list
        WebSocketManager.shared.send(json: ["action": "app_graph/list"])
    }
    
    func execute(id: String) {
        // 修正：服务端 wsmap 对应的是 run_workflow
        // 注意：服务端还需要 "sn" 参数来指定运行设备，这里暂时只传 flow_id
        WebSocketManager.shared.send(json: ["action": "run_workflow", "flow_id": id])
    }
}

struct DashboardView: View {
    @StateObject var viewModel = DashboardViewModel()
    
    let columns = [
        GridItem(.flexible()),
        GridItem(.flexible())
    ]
    
    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(viewModel.workflows) { item in
                        WorkflowCardView(item: item) {
                            viewModel.execute(id: item.id)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Dashboard")
            .onAppear {
                if WebSocketManager.shared.isConnected {
                    viewModel.fetchWorkflows()
                }
            }
            // 新增：监听连接状态，一旦连接成功立即刷新数据
            .onReceive(WebSocketManager.shared.$isConnected) { connected in
                if connected {
                    viewModel.fetchWorkflows()
                }
            }
        }
    }
}

struct WorkflowCardView: View {
    let item: WorkflowItem
    let action: () -> Void
    @State private var isExecuting = false
    
    var body: some View {
        Button(action: {
            isExecuting = true
            action()
            // Simulate feedback delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isExecuting = false
            }
        }) {
            VStack(spacing: 15) {
                if isExecuting {
                    ProgressView()
                        .scaleEffect(1.5)
                } else {
                    // 服务端返回的是 Emoji，直接用 Text 显示；如果是 SF Symbol 则用 Image
                    // 这里简单处理：直接显示 Text，因为服务端数据是 Emoji
                    Text(item.icon)
                        .font(.system(size: 40))
                    // 如果需要支持颜色，可以使用默认颜色
                    // Image(systemName: item.icon)
                    //    .font(.system(size: 40))
                    //    .foregroundColor(Color(hex: item.color ?? "#007AFF"))
                }
                
                Text(item.name)
                    .font(.headline)
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 120)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(16)
        }
        .contextMenu {
            Button(action: {}) {
                Label("Add to Siri", systemImage: "mic")
            }
        }
    }
}

// Helper for Hex Color
extension Color {
    init(hex: String) {
        // Simplified placeholder. In real app, parse hex string to RGB
        self = .blue
    }
}