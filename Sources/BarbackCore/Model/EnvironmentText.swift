import Foundation

/// The text editor keeps its own draft; parsing must never rewrite an unfinished line.
public enum EnvironmentText {
    public struct Result: Equatable, Sendable {
        public let variables: [String: EnvVar]
        public let errors: [String]
    }

    public static func parse(_ text: String) -> Result {
        var variables: [String: EnvVar] = [:]
        var errors: [String] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (offset, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let prefix = "第 \(offset + 1) 行："
            guard let separator = line.firstIndex(of: "=") else {
                errors.append(prefix + "请使用 KEY=VALUE 格式")
                continue
            }
            var key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let sensitive = key.hasPrefix("*")
            if sensitive { key.removeFirst() }
            guard !key.isEmpty, !key.contains("\0"), !key.contains(where: { $0.isWhitespace }) else {
                errors.append(prefix + "变量名不能为空或包含空白字符")
                continue
            }
            let value = String(line[line.index(after: separator)...])
            guard !value.contains("\0") else {
                errors.append(prefix + "变量值不能包含空字符")
                continue
            }
            guard variables[key] == nil else {
                errors.append(prefix + "变量名重复，请合并为一行")
                continue
            }
            variables[key] = EnvVar(value: value, sensitive: sensitive)
        }
        return Result(variables: variables, errors: errors)
    }

    public static func format(_ variables: [String: EnvVar]) -> String {
        variables.keys.sorted().map { key in
            guard let variable = variables[key] else { return "" }
            return (variable.sensitive ? "*" : "") + key + "=" + variable.value
        }.joined(separator: "\n")
    }
}
