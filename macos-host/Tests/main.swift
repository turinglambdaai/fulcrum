import Foundation

// Fast macOS-only policy regression tests; no live GitHub or private keys.
// Production's update controller invokes this policy only after RivetUpdate
// authenticates the Ed25519 signed wrapper over the same payload bytes.
let json = """
{
  "application_id":"site.jrtx.fulcrum",
  "version":"0.14.0",
  "channel":"stable",
  "minimum_version":"0.12.0",
  "rollout":50,
  "artifacts":[
    {"platform":"macos","architecture":"arm64","installer":"zip",
     "url":"https://github.com/turinglambdaai/fulcrum/releases/download/v0.14.0/mac.zip",
     "size":20000000}
  ]
}
"""
let decoder = JSONDecoder()
decoder.keyDecodingStrategy = .convertFromSnakeCase
let good = try decoder.decode(NativeUpdatePolicy.Payload.self,
                              from: Data(json.utf8))

func expect(_ value: Bool, _ label: String) {
    guard value else { fatalError("native updater policy regression: " + label) }
    print("PASS: " + label)
}

func variant(_ replace: String, with substitution: String) throws
    -> NativeUpdatePolicy.Payload {
    let value = json.replacingOccurrences(of: replace, with: substitution)
    return try decoder.decode(NativeUpdatePolicy.Payload.self, from: Data(value.utf8))
}

func eligible(_ value: NativeUpdatePolicy.Payload,
              version: String = "0.13.2",
              arch: String = "arm64",
              bucket: Int = 49) -> Bool {
    NativeUpdatePolicy.eligible(value,
                                installedVersion: version,
                                arch: arch,
                                rolloutBucket: bucket)
}

expect(eligible(good), "signed eligible stable manifest")
expect(!eligible(good, bucket: 50), "staged rollout excludes boundary bucket")
expect(!eligible(good, bucket: -1), "reject invalid rollout bucket")
expect(!eligible(good, bucket: 100), "reject out of range rollout bucket")
expect(!eligible(good, version: "0.14.0"), "do not offer installed release")
expect(!eligible(good, version: "0.11.0"), "minimum version is enforced")
expect(!eligible(good, version: "0.13.2-rc.1"), "stable version syntax fails closed")
expect(!eligible(good, arch: "x64"), "no wrong architecture fallback")
expect(!eligible(try variant("site.jrtx.fulcrum", with: "example.unsafe")),
       "wrong application identity rejected")
expect(!eligible(try variant("stable", with: "beta")),
       "wrong release channel rejected")
expect(!eligible(try variant("\"rollout\":50", with: "\"rollout\":0")),
       "zero rollout never offered")
expect(!eligible(try variant("\"installer\":\"zip\"", with: "\"installer\":\"dmg\"")),
       "human DMG never selected as in-app artifact")
expect(!eligible(try variant("\"size\":20000000", with: "\"size\":900000000")),
       "oversized artifact rejected")
expect(!eligible(try variant("\"minimum_version\":\"0.12.0\"",
                             with: "\"minimum_version\":\"0.14.0\"")),
       "malformed minimum release policy rejected")
print("NativeUpdatePolicy tests complete.")
