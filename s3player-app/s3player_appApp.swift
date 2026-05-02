//
//  s3player_appApp.swift
//  s3player-app
//
//  Created by it3 on 5/1/26.
//

import SwiftUI

@main
struct s3player_appApp: App {
    @StateObject private var auth = AuthViewModel()

    var body: some Scene {
        WindowGroup {
            if auth.isAuthenticated {
                ContentView(auth: auth)
            } else {
                LoginView(auth: auth)
            }
        }
    }
}
