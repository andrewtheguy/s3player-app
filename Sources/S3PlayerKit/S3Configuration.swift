//
//  S3Configuration.swift
//  S3PlayerKit
//

import AWSSDKIdentity
import AWSS3
import Foundation

public struct S3Configuration: Sendable, Equatable {
    public let endpoint: String
    public let bucket: String
    public let region: String
    public let accessKeyID: String
    public let secretAccessKey: String
    public let forcePathStyle: Bool

    public init(
        endpoint: String,
        bucket: String,
        region: String,
        accessKeyID: String,
        secretAccessKey: String,
        forcePathStyle: Bool = true
    ) throws {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: trimmedEndpoint),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host != nil
        else {
            throw S3ConfigurationError.invalidEndpoint
        }

        self.endpoint = trimmedEndpoint
        self.bucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        self.region = region.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accessKeyID = accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secretAccessKey = secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.forcePathStyle = forcePathStyle

        guard !self.bucket.isEmpty else { throw S3ConfigurationError.missingValue("S3_BUCKET") }
        guard !self.region.isEmpty else { throw S3ConfigurationError.missingValue("S3_REGION") }
        guard !self.accessKeyID.isEmpty else { throw S3ConfigurationError.missingValue("S3_ACCESS_KEY_ID") }
        guard !self.secretAccessKey.isEmpty else { throw S3ConfigurationError.missingValue("S3_SECRET_ACCESS_KEY") }
    }

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> S3Configuration {
        try S3Configuration(
            endpoint: try value(for: "S3_ENDPOINT", in: environment),
            bucket: try value(for: "S3_BUCKET", in: environment),
            region: try value(for: "S3_REGION", in: environment),
            accessKeyID: try value(for: "S3_ACCESS_KEY_ID", in: environment),
            secretAccessKey: try value(for: "S3_SECRET_ACCESS_KEY", in: environment),
            forcePathStyle: boolValue(for: "S3_FORCE_PATH_STYLE", in: environment) ?? true
        )
    }

    public func makeClientConfig() async throws -> S3Client.S3ClientConfig {
        let credentials = AWSCredentialIdentity(
            accessKey: accessKeyID,
            secret: secretAccessKey
        )

        return try await S3Client.S3ClientConfig(
            awsCredentialIdentityResolver: StaticAWSCredentialIdentityResolver(credentials),
            region: region,
            signingRegion: region,
            forcePathStyle: forcePathStyle,
            endpoint: endpoint
        )
    }

    private static func value(for key: String, in environment: [String: String]) throws -> String {
        guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw S3ConfigurationError.missingValue(key)
        }

        return value
    }

    private static func boolValue(for key: String, in environment: [String: String]) -> Bool? {
        guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }

        switch value {
        case "1", "true", "yes", "y":
            return true
        case "0", "false", "no", "n":
            return false
        default:
            return nil
        }
    }
}

public enum S3ConfigurationError: LocalizedError, Equatable {
    case invalidEndpoint
    case missingValue(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "S3_ENDPOINT must be a valid HTTP or HTTPS URL."
        case .missingValue(let key):
            return "Missing required environment variable: \(key)."
        }
    }
}
