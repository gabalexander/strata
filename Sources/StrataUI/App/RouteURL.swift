import Foundation

extension Route {
    public init?(strataURL string: String) {
        guard let url = URLComponents(string: string), url.scheme?.lowercased() == "strata",
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        let target = String(url.path.dropFirst())
        switch url.host?.lowercased() {
        case "sim" where !target.isEmpty && !target.contains("/"):
            let path = url.queryItems?.first { $0.name == "path" }?.value ?? ""
            self = .sim(target, path: path.split(separator: "/").map(String.init))
        case "note" where !target.isEmpty:
            let parts = target.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !target.contains("\0") else { return nil }
            self = .note(target)
        case "search" where target.isEmpty:
            self = .search(url.queryItems?.first { $0.name == "q" }?.value ?? "")
        default: return nil
        }
    }
}
