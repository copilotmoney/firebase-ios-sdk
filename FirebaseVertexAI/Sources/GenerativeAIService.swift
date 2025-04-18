// Copyright 2023 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import FirebaseAppCheckInterop
import FirebaseAuthInterop
import FirebaseCore
import Foundation

@available(iOS 15.0, macOS 11.0, macCatalyst 15.0, tvOS 15.0, watchOS 8.0, *)
struct GenerativeAIService {
  /// The language of the SDK in the format `gl-<language>/<version>`.
  static let languageTag = "gl-swift/5"

  /// The Firebase SDK version in the format `fire/<version>`.
  static let firebaseVersionTag = "fire/\(FirebaseVersion())"

  private let projectID: String

  /// Gives permission to talk to the backend.
  private let apiKey: String

  private let appCheck: AppCheckInterop?

  private let auth: AuthInterop?

  private let urlSession: URLSession

  init(projectID: String, apiKey: String, appCheck: AppCheckInterop?, auth: AuthInterop?,
       urlSession: URLSession) {
    self.projectID = projectID
    self.apiKey = apiKey
    self.appCheck = appCheck
    self.auth = auth
    self.urlSession = urlSession
  }

  func loadRequest<T: GenerativeAIRequest>(request: T) async throws -> T.Response {
    let urlRequest = try await urlRequest(request: request)

    #if DEBUG
      printCURLCommand(from: urlRequest)
    #endif

    let data: Data
    let rawResponse: URLResponse
    (data, rawResponse) = try await urlSession.data(for: urlRequest)

    let response = try httpResponse(urlResponse: rawResponse)

    // Verify the status code is 200
    guard response.statusCode == 200 else {
      Logging.network.error("[FirebaseVertexAI] The server responded with an error: \(response)")
      if let responseString = String(data: data, encoding: .utf8) {
        Logging.default.error("[FirebaseVertexAI] Response payload: \(responseString)")
      }

      throw parseError(responseData: data)
    }

    return try parseResponse(T.Response.self, from: data)
  }

  @available(macOS 12.0, *)
  func loadRequestStream<T: GenerativeAIRequest>(request: T)
    -> AsyncThrowingStream<T.Response, Error> {
    return AsyncThrowingStream { continuation in
      Task {
        let urlRequest: URLRequest
        do {
          urlRequest = try await self.urlRequest(request: request)
        } catch {
          continuation.finish(throwing: error)
          return
        }

        #if DEBUG
          printCURLCommand(from: urlRequest)
        #endif

        let stream: URLSession.AsyncBytes
        let rawResponse: URLResponse
        do {
          (stream, rawResponse) = try await urlSession.bytes(for: urlRequest)
        } catch {
          continuation.finish(throwing: error)
          return
        }

        // Verify the status code is 200
        let response: HTTPURLResponse
        do {
          response = try httpResponse(urlResponse: rawResponse)
        } catch {
          continuation.finish(throwing: error)
          return
        }

        // Verify the status code is 200
        guard response.statusCode == 200 else {
          Logging.network
            .error("[FirebaseVertexAI] The server responded with an error: \(response)")
          var responseBody = ""
          for try await line in stream.lines {
            responseBody += line + "\n"
          }

          Logging.default.error("[FirebaseVertexAI] Response payload: \(responseBody)")
          continuation.finish(throwing: parseError(responseBody: responseBody))

          return
        }

        // Received lines that are not server-sent events (SSE); these are not prefixed with "data:"
        var extraLines: String = ""

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        for try await line in stream.lines {
          Logging.network.debug("[FirebaseVertexAI] Stream response: \(line)")

          if line.hasPrefix("data:") {
            // We can assume 5 characters since it's utf-8 encoded, removing `data:`.
            let jsonText = String(line.dropFirst(5))
            let data: Data
            do {
              data = try jsonData(jsonText: jsonText)
            } catch {
              continuation.finish(throwing: error)
              return
            }

            // Handle the content.
            do {
              let content = try parseResponse(T.Response.self, from: data)
              continuation.yield(content)
            } catch {
              continuation.finish(throwing: error)
              return
            }
          } else {
            extraLines += line
          }
        }

        if extraLines.count > 0 {
          continuation.finish(throwing: parseError(responseBody: extraLines))
          return
        }

        continuation.finish(throwing: nil)
      }
    }
  }

  // MARK: - Private Helpers

  private func urlRequest<T: GenerativeAIRequest>(request: T) async throws -> URLRequest {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
    urlRequest.setValue(
      "\(GenerativeAIService.languageTag) \(GenerativeAIService.firebaseVersionTag)",
      forHTTPHeaderField: "x-goog-api-client"
    )
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

    if let appCheck {
      let tokenResult = await appCheck.getToken(forcingRefresh: false)
      urlRequest.setValue(tokenResult.token, forHTTPHeaderField: "X-Firebase-AppCheck")
      if let error = tokenResult.error {
        Logging.default
          .debug("[FirebaseVertexAI] Failed to fetch AppCheck token. Error: \(error)")
      }
    }

    if let auth, let authToken = try await auth.getToken(forcingRefresh: false) {
      urlRequest.setValue("Firebase \(authToken)", forHTTPHeaderField: "Authorization")
    }

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    urlRequest.httpBody = try encoder.encode(request)

    if let timeoutInterval = request.options.timeout {
      urlRequest.timeoutInterval = timeoutInterval
    }

    return urlRequest
  }

  private func httpResponse(urlResponse: URLResponse) throws -> HTTPURLResponse {
    // Verify the status code is 200
    guard let response = urlResponse as? HTTPURLResponse else {
      Logging.default
        .error(
          "[FirebaseVertexAI] Response wasn't an HTTP response, internal error \(urlResponse)"
        )
      throw NSError(
        domain: "com.google.generative-ai",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Response was not an HTTP response."]
      )
    }

    return response
  }

  private func jsonData(jsonText: String) throws -> Data {
    guard let data = jsonText.data(using: .utf8) else {
      let error = NSError(
        domain: "com.google.generative-ai",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Could not parse response as UTF8."]
      )
      throw error
    }

    return data
  }

  private func parseError(responseBody: String) -> Error {
    do {
      let data = try jsonData(jsonText: responseBody)
      return parseError(responseData: data)
    } catch {
      return error
    }
  }

  private func parseError(responseData: Data) -> Error {
    do {
      let rpcError = try JSONDecoder().decode(RPCError.self, from: responseData)
      logRPCError(rpcError)
      return rpcError
    } catch {
      // TODO: Return an error about an unrecognized error payload with the response body
      return error
    }
  }

  // Log specific RPC errors that cannot be mitigated or handled by user code.
  // These errors do not produce specific GenerateContentError or CountTokensError cases.
  private func logRPCError(_ error: RPCError) {
    if error.isFirebaseMLServiceDisabledError() {
      Logging.default.error("""
      The Vertex AI for Firebase SDK requires the Firebase ML API `firebaseml.googleapis.com` to \
      be enabled for your project. Get started in the Firebase Console \
      (https://console.firebase.google.com/project/\(projectID)/genai/vertex) or verify that the \
      API is enabled in the Google Cloud Console \
      (https://console.developers.google.com/apis/api/firebaseml.googleapis.com/overview?project=\
      \(projectID)).
      """)
    }
  }

  private func parseResponse<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      if let json = String(data: data, encoding: .utf8) {
        Logging.network.error("[FirebaseVertexAI] JSON response: \(json)")
      }
      Logging.default.error("[FirebaseVertexAI] Error decoding server JSON: \(error)")
      throw error
    }
  }

  #if DEBUG
    private func cURLCommand(from request: URLRequest) -> String {
      var returnValue = "curl "
      if let allHeaders = request.allHTTPHeaderFields {
        for (key, value) in allHeaders {
          returnValue += "-H '\(key): \(value)' "
        }
      }

      guard let url = request.url else { return "" }
      returnValue += "'\(url.absoluteString)' "

      guard let body = request.httpBody,
            let jsonStr = String(bytes: body, encoding: .utf8) else { return "" }
      let escapedJSON = jsonStr.replacingOccurrences(of: "'", with: "'\\''")
      returnValue += "-d '\(escapedJSON)'"

      return returnValue
    }

    private func printCURLCommand(from request: URLRequest) {
      let command = cURLCommand(from: request)
      Logging.verbose.debug("""
      [FirebaseVertexAI] Creating request with the equivalent cURL command:
      ----- cURL command -----
      \(command, privacy: .private)
      ------------------------
      """)
    }
  #endif // DEBUG
}
