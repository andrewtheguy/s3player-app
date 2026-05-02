import Foundation

func errorMessage(_ error: Error) -> String {
    if let apiError = error as? APIError {
        return apiError.errorDescription ?? "Request failed."
    }
    return error.localizedDescription
}