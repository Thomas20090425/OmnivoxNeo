//
//  OmnivoxNeoApp.swift
//  OmnivoxNeo
//
//  Created by Thomas on 2026-09-03.
//

import SwiftUI

@main
struct OmnivoxNeoApp: App {
    var body: some Scene {
        WindowGroup {
            // The version check sits here, outside everything, because this is
            // the only place it can sit and still mean anything. `ContentView`
            // resolves the active profile and stands up an `AppModel`, which
            // opens a web view against somebody's live OmniVox session — so a
            // build that has been told to stop has to be stopped before that
            // view is ever constructed, not after it has already signed in.
            VersionGate {
                ContentView()
            }
        }
        #if os(macOS)
        .defaultSize(width: 720, height: 860)
        #endif
    }
}
