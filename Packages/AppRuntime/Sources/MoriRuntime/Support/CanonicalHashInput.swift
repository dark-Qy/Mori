import Foundation

/// Encodes arbitrary string components without delimiter ambiguity.
///
/// Every UTF-8 payload is preceded by its byte count, so values that contain
/// separators cannot be confused with adjacent fields.
enum CanonicalHashInput {
  static func data(_ components: [String]) -> Data {
    Data(
      components
        .map { component in
          "\(component.utf8.count):\(component)"
        }
        .joined()
        .utf8
    )
  }
}
