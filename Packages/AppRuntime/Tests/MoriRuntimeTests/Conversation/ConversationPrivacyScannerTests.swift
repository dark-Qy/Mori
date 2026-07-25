import MoriRuntime
import Testing

@Suite("Conversation privacy scanner")
struct ConversationPrivacyScannerTests {
  private let scanner = ConversationPrivacyScanner()

  @Test("Recognized credential formats block sending")
  func recognizedCredentialsBlock() {
    let openAIKey = "sk-" + "proj-" + String(repeating: "a", count: 32)
    let awsKey = "AKIA" + String(repeating: "A", count: 16)
    let bearer =
      "Authorization: " + "Bearer "
      + String(repeating: "b", count: 32)
    let cases: [(String, ConversationCredentialKind)] = [
      (openAIKey, .openAIAPIKey),
      (awsKey, .awsAccessKeyID),
      ("-----BEGIN PRIVATE KEY-----", .pemPrivateKey),
      (bearer, .bearerToken),
    ]

    for (content, kind) in cases {
      let result = scanner.scan(content)

      #expect(result.blocked)
      #expect(result.issues.contains(.recognizedCredential(kind)))
      #expect(result.warnings.isEmpty)
    }
  }

  @Test("Short examples and ordinary Unicode conversation do not block")
  func shortExamplesRemainAllowed() {
    let content =
      "我们只是讨论 sk-proj、Bearer token、nonbearer abcdefghijklmnopqrstuvwxyz 和"
      + " 2026-07-25，不是发送密钥。🗝️"
    let result = scanner.scan(content)

    #expect(!result.blocked)
    #expect(result.issues.isEmpty)
  }

  @Test("Email and Unicode phone candidates warn without blocking")
  func contactDetailsWarn() {
    let result = scanner.scan(
      "可以写信到 mori@example.com，或者拨打＋８６ １３８ ００１３ ８０００。"
    )

    #expect(!result.blocked)
    #expect(
      result.warnings == [
        .possibleContact(.email),
        .possibleContact(.phone),
      ]
    )
    #expect(result.issues == result.warnings)
  }

  @Test("Precise in-range decimal coordinates warn")
  func preciseCoordinatesWarn() {
    let result = scanner.scan("在 31.230416，121.473701 附近见。")

    #expect(!result.blocked)
    #expect(result.warnings == [.possiblePreciseLocation])
  }

  @Test("Out-of-range and low-precision coordinates remain allowed")
  func invalidOrBroadCoordinatesRemainAllowed() {
    #expect(scanner.scan("190.0000, 121.4737").issues.isEmpty)
    #expect(scanner.scan("31.23, 121.47").issues.isEmpty)
    #expect(scanner.scan("版本 1.234.567, 89.0123").issues.isEmpty)
  }

  @Test("Issues are deduplicated and returned in deterministic policy order")
  func issueOrderIsDeterministic() {
    let content = [
      "mori@example.com and another@example.com",
      "31.230416, 121.473701",
      "AKIA" + String(repeating: "A", count: 16),
      "sk-" + String(repeating: "c", count: 32),
      "+1 (415) 555-2671",
    ].joined(separator: "\n")

    let first = scanner.scan(content)
    let second = scanner.scan(content)

    #expect(first == second)
    #expect(
      first.issues == [
        .recognizedCredential(.openAIAPIKey),
        .recognizedCredential(.awsAccessKeyID),
        .possibleContact(.email),
        .possibleContact(.phone),
        .possiblePreciseLocation,
      ]
    )
    #expect(
      first.warnings == [
        .possibleContact(.email),
        .possibleContact(.phone),
        .possiblePreciseLocation,
      ]
    )
  }
}
