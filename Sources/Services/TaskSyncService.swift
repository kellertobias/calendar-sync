import Foundation
import OSLog

/// Service for sending task data to external systems via HTTP POST requests.
/// Handles the integration with external task management systems.
@MainActor
final class TaskSyncService {
  /// Logger for task sync operations
  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "CalendarSync",
    category: "TaskSync"
  )

  /// Sends task data to the specified URL via POST request.
  /// - Parameters:
  ///   - tasks: Array of tasks to send
  ///   - url: Target URL to send the POST request to
  /// - Returns: True if the request was successful, false otherwise
  func sendTasks(_ tasks: [TaskData], to url: String) async -> Bool {
    print("TaskSyncService.sendTasks called with URL: '\(url)'")

    // Validate URL format and protocol
    guard isValidURL(url) else {
      print("Invalid URL format or unsupported protocol: \(url)")
      return false
    }

    guard let url = URL(string: url) else {
      print("Failed to create URL from string: \(url)")
      return false
    }

    guard !tasks.isEmpty else {
      print("No tasks to send")
      return true
    }

    print("About to send \(tasks.count) tasks: \(tasks.map { $0.title })")

    do {
      // Create the request payload
      let payload = TaskSyncPayload(
        timestamp: Date(),
        taskCount: tasks.count,
        tasks: tasks
      )

      // Encode the payload as JSON
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = .prettyPrinted
      let jsonData = try encoder.encode(payload)

      // Create the HTTP request
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("CalendarSync/1.0", forHTTPHeaderField: "User-Agent")
      request.httpBody = jsonData
      request.timeoutInterval = 30.0  // 30 second timeout

      print(
        "Sending \(tasks.count) tasks to \(url.absoluteString) (scheme: \(url.scheme ?? "unknown"))"
      )

      // Send the request
      let (data, response) = try await URLSession.shared.data(for: request)

      if let httpResponse = response as? HTTPURLResponse {
        if httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 {
          print("Successfully sent tasks. Response code: \(httpResponse.statusCode)")
          return true
        } else {
          let responseBody = String(data: data, encoding: .utf8) ?? "No response body"
          print(
            "Failed to send tasks. Response code: \(httpResponse.statusCode), Response: \(responseBody)"
          )
          return false
        }
      } else {
        print("Invalid response type: \(type(of: response))")
        return false
      }
    } catch {
      // Provide more detailed error information
      if let urlError = error as? URLError {
        switch urlError.code {
        case .cannotConnectToHost:
          print("Cannot connect to host: \(urlError.localizedDescription)")
        case .networkConnectionLost:
          print("Network connection lost: \(urlError.localizedDescription)")
        case .notConnectedToInternet:
          print("Not connected to internet: \(urlError.localizedDescription)")
        case .timedOut:
          print("Request timed out: \(urlError.localizedDescription)")
        case .cannotFindHost:
          print("Cannot find host: \(urlError.localizedDescription)")
        default:
          print("URL Error (\(urlError.code.rawValue)): \(urlError.localizedDescription)")
        }
      } else {
        print("Failed to send tasks: \(error.localizedDescription)")
      }
      return false
    }
  }

  /// Validates if a URL string is valid and supports HTTP/HTTPS protocols.
  /// - Parameter urlString: The URL string to validate
  /// - Returns: True if the URL is valid and uses HTTP or HTTPS, false otherwise
  func isValidURL(_ urlString: String) -> Bool {
    guard let url = URL(string: urlString) else {
      logger.debug("URL parsing failed for: \(urlString)")
      return false
    }

    // Check if the scheme is HTTP or HTTPS
    guard let scheme = url.scheme?.lowercased() else {
      logger.debug("No scheme found in URL: \(urlString)")
      return false
    }

    let isValidScheme = scheme == "http" || scheme == "https"
    if !isValidScheme {
      logger.debug(
        "Unsupported scheme '\(scheme)' in URL: \(urlString). Only HTTP and HTTPS are supported.")
    }

    // Check if host is present
    guard url.host != nil else {
      logger.debug("No host found in URL: \(urlString)")
      return false
    }

    return isValidScheme
  }
}

/// Payload structure for sending tasks to external systems.
struct TaskSyncPayload: Codable {
  /// Timestamp when the sync was performed
  let timestamp: Date
  /// Number of tasks in this payload
  let taskCount: Int
  /// Array of task data
  let tasks: [TaskData]
}
