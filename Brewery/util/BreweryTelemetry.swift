//
//  BreweryTelemetry.swift
//  brewery
//
//  Created by Wonjae Lim on 8/5/26.
//
import Aptabase
import Foundation

/// Sends one anonymous `app_started` event per launch, so we can see how many people
/// actually use Brewery. No personal data, no IP address, and no package names.
///
/// The opt-out lives in Settings ▸ Privacy and is read once, at launch.
enum BreweryTelemetry {
    /// Shared with `SettingsView`'s `@AppStorage` so the key is spelled out in one place.
    static let isEnabledKey = "isTelemetryEnabled"

    /// Aptabase App Key. Not a secret: it is a write-only ingestion key that ships inside
    /// every copy of the app, so committing it to a public repo is expected.
    private static let appKey = "A-US-2433465353"

    private static let launchEventName = "app_started"

    /// Enabled unless the user turned it off, so an unset key means enabled.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: isEnabledKey) as? Bool ?? true
    }

    /// Called once from `App.init()`. Never throws and never blocks: `trackEvent` only
    /// enqueues, and `flush` hands the upload to a background task. A failed upload is
    /// dropped on purpose — analytics must never disturb the user.
    static func start() {
        guard isEnabled else { return }

        Aptabase.shared.initialize(appKey: appKey)
        Aptabase.shared.trackEvent(launchEventName)
        // Aptabase batches for 60s in release builds and only force-flushes on app
        // termination, where the async send can lose the race with process exit — so a
        // short session would be dropped. One event per launch gains nothing from
        // batching, so send it right away.
        Aptabase.shared.flush()
    }
}
