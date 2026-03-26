import Foundation

extension String {
    /// Localized string lookup: "key".localized
    var localized: String {
        NSLocalizedString(self, comment: "")
    }

    /// Localized string with format arguments: "key".localized(arg1, arg2)
    func localized(_ args: CVarArg...) -> String {
        String(format: NSLocalizedString(self, comment: ""), arguments: args)
    }
}
