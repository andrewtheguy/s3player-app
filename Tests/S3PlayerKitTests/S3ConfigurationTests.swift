import XCTest
@testable import S3PlayerKit

final class S3ConfigurationTests: XCTestCase {
    func testLoadsConfigurationFromEnvironment() throws {
        let configuration = try S3Configuration.fromEnvironment([
            "S3_ENDPOINT": " https://example.com ",
            "S3_BUCKET": " radio-show ",
            "S3_REGION": " us-east-1 ",
            "S3_ACCESS_KEY_ID": " access-key ",
            "S3_SECRET_ACCESS_KEY": " secret-key ",
            "S3_FORCE_PATH_STYLE": "false"
        ])

        XCTAssertEqual(configuration.endpoint, "https://example.com")
        XCTAssertEqual(configuration.bucket, "radio-show")
        XCTAssertEqual(configuration.region, "us-east-1")
        XCTAssertEqual(configuration.accessKeyID, "access-key")
        XCTAssertEqual(configuration.secretAccessKey, "secret-key")
        XCTAssertFalse(configuration.forcePathStyle)
    }

    func testPathStyleDefaultsToTrue() throws {
        let configuration = try S3Configuration.fromEnvironment([
            "S3_ENDPOINT": "https://example.com",
            "S3_BUCKET": "radio-show",
            "S3_REGION": "us-east-1",
            "S3_ACCESS_KEY_ID": "access-key",
            "S3_SECRET_ACCESS_KEY": "secret-key"
        ])

        XCTAssertTrue(configuration.forcePathStyle)
    }

    func testRejectsInvalidEndpoint() {
        XCTAssertThrowsError(
            try S3Configuration(
                endpoint: "not a url",
                bucket: "radio-show",
                region: "us-east-1",
                accessKeyID: "access-key",
                secretAccessKey: "secret-key"
            )
        ) { error in
            XCTAssertEqual(error as? S3ConfigurationError, .invalidEndpoint)
        }
    }

    func testRequiresBucket() {
        XCTAssertThrowsError(
            try S3Configuration.fromEnvironment([
                "S3_ENDPOINT": "https://example.com",
                "S3_REGION": "us-east-1",
                "S3_ACCESS_KEY_ID": "access-key",
                "S3_SECRET_ACCESS_KEY": "secret-key"
            ])
        ) { error in
            XCTAssertEqual(error as? S3ConfigurationError, .missingValue("S3_BUCKET"))
        }
    }
}
