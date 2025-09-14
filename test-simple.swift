#!/usr/bin/env swift

import Foundation

// Simple synchronous test using URLSession with completion handler
let testData = """
  {
    "timestamp": "2025-09-14T15:21:00Z",
    "taskCount": 2,
    "tasks": [
      {
        "id": "test-1",
        "title": "Test Task 1",
        "notes": "This is a test task",
        "dueDate": "2025-09-14T15:21:00Z",
        "calendar": "Test Calendar"
      },
      {
        "id": "test-2",
        "title": "Test Task 2",
        "notes": null,
        "dueDate": null,
        "calendar": "Test Calendar"
      }
    ]
  }
  """

guard let url = URL(string: "http://localhost:3000/") else {
  print("❌ Failed to create URL")
  exit(1)
}

guard let jsonData = testData.data(using: .utf8) else {
  print("❌ Failed to create JSON data")
  exit(1)
}

var request = URLRequest(url: url)
request.httpMethod = "POST"
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
request.setValue("CalendarSync/1.0", forHTTPHeaderField: "User-Agent")
request.httpBody = jsonData
request.timeoutInterval = 10.0

print("Sending test request to \(url.absoluteString)")
print("Payload size: \(jsonData.count) bytes")

let semaphore = DispatchSemaphore(value: 0)
var success = false

URLSession.shared.dataTask(with: request) { data, response, error in
  if let error = error {
    print("❌ Error: \(error.localizedDescription)")
    if let urlError = error as? URLError {
      print("URL Error code: \(urlError.code.rawValue)")
    }
  } else if let httpResponse = response as? HTTPURLResponse {
    print("Response code: \(httpResponse.statusCode)")
    if httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 {
      print("✅ Success!")
      success = true
    } else {
      let responseBody = String(data: data ?? Data(), encoding: .utf8) ?? "No response body"
      print("❌ Failed: \(responseBody)")
    }
  } else {
    print("❌ Invalid response type")
  }
  semaphore.signal()
}.resume()

let result = semaphore.wait(timeout: .now() + 15)
if result == .timedOut {
  print("❌ Request timed out")
} else if success {
  print("✅ Test completed successfully!")
} else {
  print("❌ Test failed")
}
