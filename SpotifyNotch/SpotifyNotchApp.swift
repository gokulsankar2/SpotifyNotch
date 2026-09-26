//
//  SpotifyNotchApp.swift
//  SpotifyNotch
//
//  Created by Gokul Sankar on 9/25/26.
//

import SwiftUI

@main
struct SpotifyNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The app is LSUIElement: no Dock icon and no main window. The notch
        // overlay and the menu bar item are created by AppDelegate; this
        // scene exists only because `App` requires one, and `Settings` does
        // not materialise a window until it is opened.
        Settings {
            EmptyView()
        }
    }
}
