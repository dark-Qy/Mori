import Foundation

public enum ConversationCredentialKind: String, Hashable, Sendable {
  case openAIAPIKey
  case awsAccessKeyID
  case pemPrivateKey
  case bearerToken
}

public enum ConversationContactKind: String, Hashable, Sendable {
  case email
  case phone
}

public enum ConversationPrivacyIssue: Hashable, Sendable {
  case recognizedCredential(ConversationCredentialKind)
  case possibleContact(ConversationContactKind)
  case possiblePreciseLocation

  public var isBlocking: Bool {
    if case .recognizedCredential = self {
      return true
    }
    return false
  }
}

public typealias ConversationScanIssue = ConversationPrivacyIssue

public struct ConversationPrivacyScanResult: Equatable, Sendable {
  public let blocked: Bool
  public let warnings: [ConversationPrivacyIssue]
  public let issues: [ConversationPrivacyIssue]

  fileprivate init(issues: [ConversationPrivacyIssue]) {
    self.issues = issues
    blocked = issues.contains(where: \.isBlocking)
    warnings = issues.filter { !$0.isBlocking }
  }
}

/// A deterministic, local preflight check for a small set of recognizable risks.
///
/// This scanner is intentionally conservative in what it blocks and is not a
/// claim of complete data-loss prevention. It never logs or retains the scanned
/// content.
public struct ConversationPrivacyScanner: Sendable {
  private static let phoneCandidateCharacters: Set<Character> = [
    "+", "(", ")", "-", " ", "\t",
  ]

  public init() {}

  public func scan(_ content: String) -> ConversationPrivacyScanResult {
    var issues: [ConversationPrivacyIssue] = []

    append(
      .recognizedCredential(.openAIAPIKey),
      when: content.firstMatch(
        of: #/\bsk-(?:proj-)?[A-Za-z0-9_-]{19,}[A-Za-z0-9]\b/#
      ) != nil,
      to: &issues
    )
    append(
      .recognizedCredential(.awsAccessKeyID),
      when: content.firstMatch(of: #/\bAKIA[0-9A-Z]{16}\b/#) != nil,
      to: &issues
    )
    append(
      .recognizedCredential(.pemPrivateKey),
      when: content.firstMatch(
        of: #/-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----/#
      ) != nil,
      to: &issues
    )
    append(
      .recognizedCredential(.bearerToken),
      when: content.firstMatch(
        of: #/\b(?i:bearer)\b[ \t]+[A-Za-z0-9._~+\/-]{19,}[A-Za-z0-9]/#
      ) != nil,
      to: &issues
    )
    append(
      .possibleContact(.email),
      when: content.firstMatch(
        of: #/(?i:\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b)/#
      ) != nil,
      to: &issues
    )
    append(
      .possibleContact(.phone),
      when: Self.containsPossiblePhone(in: content),
      to: &issues
    )
    append(
      .possiblePreciseLocation,
      when: Self.containsPossiblePreciseLocation(in: content),
      to: &issues
    )

    return ConversationPrivacyScanResult(issues: issues)
  }

  private func append(
    _ issue: ConversationPrivacyIssue,
    when condition: Bool,
    to issues: inout [ConversationPrivacyIssue]
  ) {
    guard condition, !issues.contains(issue) else { return }
    issues.append(issue)
  }

  private static func containsPossiblePhone(in content: String) -> Bool {
    var candidate = ""

    for character in content {
      if character.isNumber
        || isASCIILetter(character)
        || phoneCandidateCharacters.contains(character)
      {
        candidate.append(character)
      } else {
        if isPossiblePhone(candidate) {
          return true
        }
        candidate.removeAll(keepingCapacity: true)
      }
    }

    return isPossiblePhone(candidate)
  }

  private static func isPossiblePhone(_ candidate: String) -> Bool {
    if candidate.contains(where: isASCIILetter) {
      guard
        let suffix = candidate.split(whereSeparator: \.isWhitespace).last,
        suffix.contains(where: isASCIILetter) == false
      else {
        return false
      }
      return isPossiblePhone(String(suffix))
    }

    let digitCount = candidate.lazy.filter(\.isNumber).count
    guard (7...15).contains(digitCount) else { return false }

    let groups = Array(candidate).split(whereSeparator: { !$0.isNumber })
      .map { $0.count }
    let hasExplicitPhoneMarker =
      candidate.contains("+")
      || candidate.contains("(")
      || candidate.contains(")")
    let hasPlausibleLocalGrouping =
      groups.count == 2
      && (3...4).contains(groups[0])
      && groups[1] == 4

    return hasExplicitPhoneMarker
      || digitCount >= 10
      || hasPlausibleLocalGrouping
  }

  private static func isASCIILetter(_ character: Character) -> Bool {
    guard let value = character.asciiValue else { return false }
    return (65...90).contains(value) || (97...122).contains(value)
  }

  private static func containsPossiblePreciseLocation(in content: String) -> Bool {
    let coordinatePairPattern =
      #/-?[0-9]{1,3}\.[0-9]{3,}[ \t]*[,，][ \t]*-?[0-9]{1,3}\.[0-9]{3,}/#
    for match in content.matches(of: coordinatePairPattern) {
      let range = match.range
      if range.lowerBound != content.startIndex {
        let preceding = content[content.index(before: range.lowerBound)]
        if preceding.isNumber || preceding == "." {
          continue
        }
      }
      if range.upperBound != content.endIndex {
        let following = content[range.upperBound]
        if following.isNumber || following == "." {
          continue
        }
      }

      let value = String(match.output)
        .replacingOccurrences(of: "，", with: ",")
      let components = value.split(separator: ",", omittingEmptySubsequences: false)
      guard
        components.count == 2,
        let latitude = Double(
          components[0].trimmingCharacters(in: .whitespacesAndNewlines)
        ),
        let longitude = Double(
          components[1].trimmingCharacters(in: .whitespacesAndNewlines)
        ),
        (-90...90).contains(latitude),
        (-180...180).contains(longitude)
      else {
        continue
      }
      return true
    }

    return false
  }
}
