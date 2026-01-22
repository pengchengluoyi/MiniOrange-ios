import Foundation

struct WorkflowItem: Identifiable, Codable {
    let id: String
    let name: String
    let icon: String
    let color: String?
}

struct ConnectionConfig: Codable {
    let u: String
    let t: String
}

struct Device: Identifiable, Codable {
    let sn: String
    let model: String
    let status: String
    
    var id: String { sn }
}