import Foundation

/// What the add-account sheet asks the engine to do.
struct AddAccountRequest: Sendable {
    var mode: AddAccountMode
    var name: String?
    var secret: String?
    var path: String
}

enum AddAccountEvent: Sendable {
    case line(String)
    case openURL(URL)
}
