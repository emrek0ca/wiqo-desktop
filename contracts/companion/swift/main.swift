// Verifies RovaShared (the Mac companion's shared code) against contracts/companion/vectors.json.
// Built with swiftc together with RovaShared/*.swift by contracts/companion/check.sh, so the Xcode
// project needs no change.
import Foundation

/// Any JSON value, so the vectors run through the same RovaCanonicalJSON path real payloads use.
indirect enum JSONValue: Codable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

struct Vectors: Decodable {
    struct Canonical: Decodable { let input: String; let canonical: String }
    struct Grant: Decodable { let grantId: String; let rootDirectory: String; let mode: String; let expiresAt: Int; let token: String; let signature: String }
    struct Command: Decodable { let id: String; let type: String; let epochMs: Int64; let nonce: String; let payload: JSONValue; let token: String; let payloadCanonical: String; let signature: String }
    let canonicalJson: [Canonical]
    let terminalGrants: [Grant]
    let commandSignatures: [Command]
}

let arguments = Array(CommandLine.arguments.dropFirst())
let path = arguments.first ?? "contracts/companion/vectors.json"

// The operation catalogue (RovaShared/OperationManifest.swift) is the single source of which
// operation runs where; operations.json carries it to the Windows tests and the parity report.
if let operationsPath = arguments.dropFirst().first {
    let object = try JSONSerialization.jsonObject(with: RovaOperationManifest.encodedManifest())
    let text = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self) + "\n"
    let current = try? String(contentsOfFile: operationsPath, encoding: .utf8)
    if arguments.contains("--write") {
        try text.write(toFile: operationsPath, atomically: true, encoding: .utf8)
    } else if current != text {
        print("✖ operations.json RovaShared manifestosuyla aynı değil: contracts/companion/check.sh --write")
        exit(1)
    }
}

let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
var failures = 0
func expect(_ ok: Bool, _ label: String) {
    if !ok { failures += 1; print("✖ \(label)") }
}

for item in vectors.canonicalJson {
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(item.input.utf8))
    let actual = String(decoding: try RovaCanonicalJSON.data(value), as: UTF8.self)
    expect(actual == item.canonical, "kanonik JSON: \(item.input)\n  beklenen \(item.canonical)\n  gelen    \(actual)")
}

for grant in vectors.terminalGrants {
    let now = Date(timeIntervalSince1970: TimeInterval(grant.expiresAt - 60))
    expect(RovaTerminalPolicy.verifyGrant(grantId: grant.grantId, rootDirectory: grant.rootDirectory, mode: grant.mode, expiresAt: grant.expiresAt, signature: grant.signature, token: grant.token, now: now), "grant imzası: \(grant.rootDirectory)")
    expect(!RovaTerminalPolicy.verifyGrant(grantId: grant.grantId, rootDirectory: grant.rootDirectory + "x", mode: grant.mode, expiresAt: grant.expiresAt, signature: grant.signature, token: grant.token, now: now), "değiştirilmiş grant reddi: \(grant.rootDirectory)")
}

for command in vectors.commandSignatures {
    // The real CommandRequest decoder and signer, exactly as the Mac verifies a phone command.
    let createdAt = ISO8601DateFormatter.string(from: Date(timeIntervalSince1970: Double(command.epochMs) / 1_000), timeZone: TimeZone(identifier: "UTC")!, formatOptions: [.withInternetDateTime])
    let json: [String: Any] = [
        "id": command.id, "type": command.type, "createdAt": createdAt, "signatureVersion": 2,
        "createdAtEpochMs": command.epochMs, "nonce": command.nonce,
        "payload": try JSONSerialization.jsonObject(with: JSONEncoder().encode(command.payload))
    ]
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let request = try decoder.decode(CommandRequest.self, from: JSONSerialization.data(withJSONObject: json))
    let payload = String(decoding: try RovaCanonicalJSON.data(request.payload), as: UTF8.self)
    expect(payload == command.payloadCanonical, "komut payload kanonik: \(command.type)\n  beklenen \(command.payloadCanonical)\n  gelen    \(payload)")
    expect(RovaValidation.signRequest(request: request, token: command.token) == command.signature, "komut imzası v2: \(command.type)")
}

let total = vectors.canonicalJson.count + vectors.terminalGrants.count * 2 + vectors.commandSignatures.count * 2
print(failures == 0 ? "✔ Mac (Swift): \(total) sözleşme kontrolü geçti" : "✖ Mac (Swift): \(failures)/\(total) kontrol başarısız")
exit(failures == 0 ? 0 : 1)
