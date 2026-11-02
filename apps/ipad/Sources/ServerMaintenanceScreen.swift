import SwiftUI

struct ServerMaintenanceScreen: View {
    let refreshing: Bool
    let refresh: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label(L("Server maintenance"), systemImage: "server.rack")
        } description: {
            Text(L("The app is temporarily closed for server maintenance. Please check again later."))
        } actions: {
            Button(L("Check again"), action: refresh)
                .buttonStyle(.borderedProminent)
                .disabled(refreshing)
                .accessibilityIdentifier("server-maintenance-retry")
            if refreshing { ProgressView() }
        }
        .tint(.pink)
        .accessibilityIdentifier("server-maintenance")
    }
}
