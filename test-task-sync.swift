#!/usr/bin/env swift

import Foundation

// Simple test to verify TaskSyncService functionality
struct TaskData: Codable {
  let id: String
  let title: String
  let notes: String?
  let dueDate: Date?
  let calendar: String
}

struct TaskSyncPayload: Codable {
  let timestamp: Date
  let taskCount: Int
  let tasks: [TaskData]
}

func testTaskSync() async {
  let testTasks = [
    TaskData(
      id: "test-1",
      title: "Test Task 1",
      notes: "This is a test task",
      dueDate: Date(),
      calendar: "Test Calendar"
    ),
    TaskData(
      id: "test-2",
      title: "Test Task 2",
      notes: nil,
      dueDate: nil,
      calendar: "Test Calendar"
    ),
  ]

  let payload = TaskSyncPayload(
    timestamp: Date(),
    taskCount: testTasks.count,
    tasks: testTasks
  )

  do {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = .prettyPrinted
    let jsonData = try encoder.encode(payload)

    guard let url = URL(string: "http://localhost:3000/") else {
      print("Failed to create URL")
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("CalendarSync/1.0", forHTTPHeaderField: "User-Agent")
    request.httpBody = jsonData
    request.timeoutInterval = 30.0

    print("Sending test request to \(url.absoluteString)")
    print("Payload size: \(jsonData.count) bytes")

    print("Making request...")
    let (data, response) = try await URLSession.shared.data(for: request)
    print("Request completed")

    if let httpResponse = response as? HTTPURLResponse {
      print("Response code: \(httpResponse.statusCode)")
      if httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 {
        print("✅ Success!")
      } else {
        let responseBody = String(data: data, encoding: .utf8) ?? "No response body"
        print("❌ Failed: \(responseBody)")
      }
    } else {
      print("❌ Invalid response type")
    }

  } catch {
    print("❌ Error: \(error.localizedDescription)")
    if let urlError = error as? URLError {
      print("URL Error code: \(urlError.code.rawValue)")
    }
  }
}

Task {
  await testTaskSync()
}
