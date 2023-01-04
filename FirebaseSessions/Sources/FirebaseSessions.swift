// Copyright 2022 Google LLC
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

import Foundation

// Avoids exposing internal FirebaseCore APIs to Swift users.
@_implementationOnly import FirebaseCoreExtension
@_implementationOnly import FirebaseInstallations
@_implementationOnly import GoogleDataTransport
@_implementationOnly import Promises

private enum GoogleDataTransportConfig {
  static let sessionsLogSource = "1974"
  static let sessionsTarget = GDTCORTarget.FLL
}

@objc(FIRSessions) final class Sessions: NSObject, Library, SessionsProvider {
  // MARK: - Private Variables

  /// The Firebase App ID associated with Sessions.
  private let appID: String

  /// Top-level Classes in the Sessions SDK
  private let coordinator: SessionCoordinator
  private let initiator: SessionInitiator
  private let identifiers: Identifiers
  private let appInfo: ApplicationInfo
  private let settings: SessionsSettings

  /// Subscribers
  /// `subscribers` are used to determine the Data Collection state of the Sessions SDK.
  /// If any Subscribers has Data Collection enabled, the Sessions SDK will send events
  private var subscribers: [SessionsSubscriber] = []
  /// `subscriberPromises` are used to wait until all Subscribers have registered
  /// themselves. Subscribers must have Data Collection state available upon registering.
  private var subscriberPromises: [SessionsSubscriberName: Promise<Void>] = [:]

  /// Constants
  static let SessionIDChangedNotificationName = Notification
    .Name("SessionIDChangedNotificationName")

  // MARK: - Initializers

  // Initializes the SDK and top-level classes
  required convenience init(appID: String, installations: InstallationsProtocol) {
    let googleDataTransport = GDTCORTransport(
      mappingID: GoogleDataTransportConfig.sessionsLogSource,
      transformers: nil,
      target: GoogleDataTransportConfig.sessionsTarget
    )

    let fireLogger = EventGDTLogger(googleDataTransport: googleDataTransport!)

    let identifiers = Identifiers()
    let coordinator = SessionCoordinator(
      identifiers: identifiers,
      installations: installations,
      fireLogger: fireLogger,
      sampler: SessionSampler()
    )
    let initiator = SessionInitiator()
    let appInfo = ApplicationInfo(appID: appID)
    let settings = SessionsSettings(
      appInfo: appInfo,
      installations: installations
    )

    self.init(appID: appID,
              identifiers: identifiers,
              coordinator: coordinator,
              initiator: initiator,
              appInfo: appInfo,
              settings: settings)
  }

  // Initializes the SDK and begines the process of listening for lifecycle events and logging events
  init(appID: String, identifiers: Identifiers, coordinator: SessionCoordinator,
       initiator: SessionInitiator, appInfo: ApplicationInfo, settings: SessionsSettings) {
    self.appID = appID

    self.identifiers = identifiers
    self.coordinator = coordinator
    self.initiator = initiator
    self.appInfo = appInfo
    self.settings = settings

    super.init()

    SessionsDependencies.dependencies.forEach { subscriberName in
      self.subscriberPromises[subscriberName] = Promise<Void>.pending()
    }

    Logger.logDebug("Expecting subscriptions from: \(SessionsDependencies.dependencies)")

    self.initiator.beginListening {
      // Generating a Session ID early is important as Subscriber
      // SDKs will need to read it immediately upon registration.
      self.identifiers.generateNewSessionID()
      NotificationCenter.default.post(name: Sessions.SessionIDChangedNotificationName,
                                      object: nil)
      let event = SessionStartEvent(identifiers: self.identifiers, appInfo: self.appInfo)

      // Wait until all subscriber promises have been fulfilled before
      // doing any data collection.
      all(self.subscriberPromises.values).then(on: .global(qos: .background)) { _ in
        guard self.isAnyDataCollectionEnabled() else {
          Logger
            .logDebug(
              "Data Collection is disabled for all subscribers. Skipping this Session Event"
            )
          return
        }

        Logger.logDebug("Data Collection is enabled for at least one Subscriber")

        // Fetch settings if they have expired
        self.settings.updateSettings()

        self.addEventDataCollectionState(event: event)

        self.coordinator.attemptLoggingSessionStart(event: event) { result in
        }
      }
    }
  }

  // MARK: - Data Collection

  func isAnyDataCollectionEnabled() -> Bool {
    for subscriber in subscribers {
      if subscriber.isDataCollectionEnabled {
        return true
      }
    }
    return false
  }

  func addEventDataCollectionState(event: SessionStartEvent) {
    subscribers.forEach { subscriber in
      event.set(subscriber: subscriber.sessionsSubscriberName,
                isDataCollectionEnabled: subscriber.isDataCollectionEnabled)
    }
  }

  // MARK: - SessionsProvider

  func register(subscriber: SessionsSubscriber) {
    Logger
      .logDebug(
        "Registering Sessions SDK subscriber with name: \(subscriber.sessionsSubscriberName), data collection enabled: \(subscriber.isDataCollectionEnabled)"
      )

    NotificationCenter.default.addObserver(
      forName: Sessions.SessionIDChangedNotificationName,
      object: nil,
      queue: nil
    ) { notification in
      subscriber.onSessionIDChanged(self.identifiers.sessionID)
    }
    // Immediately call the callback because the Sessions SDK starts
    // before subscribers, so subscribers will miss the first Notification
    subscriber.onSessionIDChanged(identifiers.sessionID)

    // Fulfil this subscriber's promise
    subscribers.append(subscriber)
    subscriberPromises[subscriber.sessionsSubscriberName]?.fulfill(())
  }

  // MARK: - Library conformance

  static func componentsToRegister() -> [Component] {
    return [Component(SessionsProvider.self,
                      instantiationTiming: .alwaysEager,
                      dependencies: []) { container, isCacheable in
        // Sessions SDK only works for the default app
        guard let app = container.app, app.isDefaultApp else { return nil }
        isCacheable.pointee = true
        let installations = Installations.installations(app: app)
        return self.init(appID: app.options.googleAppID, installations: installations)
      }]
  }
}
