//
//  S3ObjectService.swift
//  S3PlayerKit
//

import AWSS3
import Foundation

public struct S3BucketInfo: Sendable, Equatable {
    public let name: String
    public let region: String?
}

public struct S3ObjectSummary: Sendable, Equatable {
    public let key: String
    public let size: Int?
    public let lastModified: Date?
    public let eTag: String?
}

public final class S3ObjectService {
    private let configuration: S3Configuration
    private let clientConfig: S3Client.S3ClientConfig
    private let client: S3Client

    public init(configuration: S3Configuration) async throws {
        let clientConfig = try await configuration.makeClientConfig()

        self.configuration = configuration
        self.clientConfig = clientConfig
        self.client = S3Client(config: clientConfig)
    }

    public func validateBucketAccess() async throws -> S3BucketInfo {
        let output = try await client.headBucket(
            input: HeadBucketInput(bucket: configuration.bucket)
        )

        return S3BucketInfo(
            name: configuration.bucket,
            region: output.bucketRegion
        )
    }

    public func listObjects(prefix: String? = nil, maxKeys: Int = 25) async throws -> [S3ObjectSummary] {
        let output = try await client.listObjectsV2(
            input: ListObjectsV2Input(
                bucket: configuration.bucket,
                maxKeys: maxKeys,
                prefix: prefix?.nilIfEmpty
            )
        )

        return output.contents?.compactMap { object in
            guard let key = object.key else { return nil }

            return S3ObjectSummary(
                key: key,
                size: object.size,
                lastModified: object.lastModified,
                eTag: object.eTag
            )
        } ?? []
    }

    public func presignedGetObjectURL(
        forKey key: String,
        expiresIn expiration: TimeInterval = 15 * 60
    ) async throws -> URL {
        let input = GetObjectInput(
            bucket: configuration.bucket,
            key: key
        )

        guard let url = try await input.presignURL(config: clientConfig, expiration: expiration) else {
            throw S3ObjectServiceError.presignFailed(key)
        }

        return url
    }
}

public enum S3ObjectServiceError: LocalizedError, Equatable {
    case presignFailed(String)

    public var errorDescription: String? {
        switch self {
        case .presignFailed(let key):
            return "Failed to generate a presigned URL for \(key)."
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
