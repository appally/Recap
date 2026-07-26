import Foundation

/// 工具注册表：稳定顺序、重名去重、按名过滤。
public struct AgentToolRegistry: Sendable {
    private let tools: [any AgentTool]
    private let byName: [String: any AgentTool]

    public init(tools: [any AgentTool]) {
        var ordered: [any AgentTool] = []
        var map: [String: any AgentTool] = [:]
        for tool in tools {
            let name = tool.spec.name
            if map[name] != nil {
                // 后者忽略；Debug 打日志，不 trap（避免单测/生产被 assertionFailure 打死）。
                #if DEBUG
                print("AgentToolRegistry: duplicate tool name \(name), ignoring latter")
                #endif
                continue
            }
            map[name] = tool
            ordered.append(tool)
        }
        self.tools = ordered
        self.byName = map
    }

    public var specs: [AgentToolSpec] {
        tools.map(\.spec)
    }

    public func tool(named name: String) -> (any AgentTool)? {
        byName[name]
    }

    /// `nil` → 全集；空集 → 空注册表。
    public func filtered(allowing names: Set<String>?) -> AgentToolRegistry {
        guard let names else { return self }
        let kept = tools.filter { names.contains($0.spec.name) }
        return AgentToolRegistry(tools: kept)
    }
}
