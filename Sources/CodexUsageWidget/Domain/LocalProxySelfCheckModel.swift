import Foundation

struct LocalProxySelfCheckModel {
    struct Step: Identifiable {
        let id: String
        let title: String
        var passed: Bool? = nil
        var detail = "等待检查"
    }
    var isRunning = false
    var observedAt: Date?
    var steps: [Step] = []
    mutating func begin() {
        isRunning = true
        observedAt = Date()
        steps = [Step(id: "system", title: "系统代理"), Step(id: "egress", title: "出口节点"), Step(id: "official", title: "官方后端"), Step(id: "endpoint", title: "反代端点"), Step(id: "pool", title: "账号池")]
    }
    mutating func update(_ id: String, passed: Bool, detail: String) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[index].passed = passed
        steps[index].detail = detail
    }
}
