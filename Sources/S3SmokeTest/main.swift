import Foundation
import S3PlayerKit

@main
struct S3SmokeTest {
    static func main() async {
        do {
            let configuration = try S3Configuration.fromEnvironment()
            let service = try await S3ObjectService(configuration: configuration)
            let bucket = try await service.validateBucketAccess()

            let environment = ProcessInfo.processInfo.environment
            let prefix = environment["S3_PREFIX"]
            let maxKeys = Int(environment["S3_MAX_KEYS"] ?? "") ?? 10
            let objects = try await service.listObjects(prefix: prefix, maxKeys: maxKeys)

            print("Connected to bucket '\(bucket.name)' at \(configuration.endpoint).")
            if let region = bucket.region {
                print("Bucket region: \(region)")
            }
            print("Listed \(objects.count) object(s).")

            guard let firstObject = objects.first else {
                print("No objects found; bucket access test passed.")
                return
            }

            print("First object: \(firstObject.key)")
            if let size = firstObject.size {
                print("Size: \(size) bytes")
            }

            let url = try await service.presignedGetObjectURL(forKey: firstObject.key)
            let urlDescription = [url.host, url.path].compactMap(\.self).joined()
            print("Generated presigned playback URL for \(urlDescription).")
        } catch {
            fputs("S3 smoke test failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
