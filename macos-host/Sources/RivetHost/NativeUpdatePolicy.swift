import Foundation

/// Policy parity with rivet/distribution/updater.rkt's select-update.
/// The caller MUST first authenticate the exact signed manifest wrapper
/// with RivetUpdateService.verifyManifest before decoding this payload.
/// These fields affect eligibility; an Ed25519 signature alone only proves
/// who published the data, not that the installed app should consume it.
enum NativeUpdatePolicy {
    struct Payload: Decodable {
        struct Artifact: Decodable {
            let platform: String
            let architecture: String
            let installer: String
            let component: String?
            let url: URL
            let size: Int
        }
        let applicationId: String
        let version: String
        let channel: String
        let minimumVersion: String
        let rollout: Int
        let artifacts: [Artifact]
    }

    struct SignedWrapper: Decodable {
        let payload: String
    }

    static func decodeAuthenticatedPayload(from verifiedWrapper: Data) throws -> Payload {
        // Only call after RivetUpdateService.verifyManifest() has verified the
        // Ed25519 signature over this exact wrapper's payload bytes.
        let wrapper = try JSONDecoder().decode(SignedWrapper.self, from: verifiedWrapper)
        guard let bytes = Data(base64Encoded: wrapper.payload) else {
            throw RivetUpdateError.signatureInvalid
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Payload.self, from: bytes)
    }

    /// Stable channel policy deliberately rejects prereleases and malformed
    /// version strings instead of treating a parse failure as version 0.
    static func components(_ version: String) -> [Int]? {
        let pieces = version.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return nil }
        let nums = pieces.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part) else { return nil }
            return number
        }
        return nums.count == 3 ? nums : nil
    }

    static func eligible(_ payload: Payload,
                         installedVersion: String,
                         arch: String,
                         rolloutBucket: Int) -> Bool {
        guard payload.applicationId == "site.jrtx.fulcrum",
              payload.channel == "stable",
              let installed = components(installedVersion),
              let newer = components(payload.version),
              let minimum = components(payload.minimumVersion),
              minimum.lexicographicallyPrecedes(newer),
              installed.lexicographicallyPrecedes(newer),
              !installed.lexicographicallyPrecedes(minimum),
              (0...100).contains(payload.rollout),
              (0..<100).contains(rolloutBucket),
              rolloutBucket < payload.rollout else {
            return false
        }
        // select-update's component-less macOS zip rule, plus the bounded
        // native downloader's preflight. Our release manifest carries one
        // macOS artifact per architecture.
        return payload.artifacts.contains { artifact in
            artifact.platform == "macos" &&
                artifact.architecture == arch &&
                artifact.installer == "zip" &&
                artifact.component == nil &&
                artifact.url.scheme?.lowercased() == "https" &&
                artifact.size > 0 &&
                artifact.size <= 512 * 1024 * 1024
        }
    }
}
