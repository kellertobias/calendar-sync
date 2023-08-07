import Foundation

func makePOSTRequest(urlString: String, data: Any, completion: @escaping (Error?) -> Void) {
    // Convert the dictionary to JSON data
    guard let jsonData = try? JSONSerialization.data(withJSONObject: data) else {
        print("Error converting JSON data")
        completion(NSError(domain: "JSONConversionError", code: 0, userInfo: nil))
        return
    }

    // Create a URLRequest with the URL
    guard let url = URL(string: urlString) else {
        print("Invalid URL")
        completion(NSError(domain: "InvalidURLError", code: 0, userInfo: nil))
        return
    }

    var request = URLRequest(url: url)

    // Set the request method to POST
    request.httpMethod = "POST"

    // Set the content type header to indicate JSON data in the body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    // Set the request body with the JSON data
    request.httpBody = jsonData

    // Create a URLSession
    let session = URLSession.shared

    // Create a data task with the request
    let task = session.dataTask(with: request) { data, response, error in
        // Check for errors
        if let error = error {
            completion(error)
            return
        }

        // Check if there's a response
        guard let response = response as? HTTPURLResponse else {
            completion(NSError(domain: "NoResponseError", code: 0, userInfo: nil))
            return
        }

        // Check the status code of the response
        if response.statusCode == 200 {
            print("POST request successful")
            // You can process the response data here if needed
            completion(nil)
        } else {
            print("Server returned status code: \(response.statusCode)")
            completion(NSError(domain: "ServerResponseError", code: response.statusCode, userInfo: nil))
        }
    }

    // Start the data task
    task.resume()
}
