import SwiftUI

/// Minimal host app.
///
/// Its only jobs are to hold the credential in the shared App Group and to
/// register the domain. Everything the user actually does happens in Finder.
@main
struct PlinthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ConnectView()
                .frame(width: 420)
                .fixedSize()
        }
        .windowResizability(.contentSize)
    }
}

/// 🔴 Registration lives here, at app scope — NOT on a view's `.task`.
/// See the note on `DriveDomain.register()`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await DriveDomain.register() }
    }
}

struct ConnectView: View {
    @AppStorage("lastBaseURL") private var baseURL = "http://127.0.0.1:8080/dav"
    @State private var account = ""
    @State private var password = ""
    @State private var registered = false
    @State private var status = ""

    var body: some View {
        Form {
            Section {
                TextField("Server", text: $baseURL)
                TextField("Account", text: $account)
                SecureField("Password", text: $password)
            } footer: {
                Text("The reference server accepts any non-empty account and password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Connect") {
                        Credentials.store(account: account, password: password, baseURL: baseURL)
                        Task {
                            await DriveDomain.register()
                            registered = await DriveDomain.isRegistered()
                            status = registered
                                ? "Registered. Look under Locations in Finder."
                                : "Registration failed — see Console for [plinth]."
                        }
                    }
                    .disabled(account.isEmpty || password.isEmpty || baseURL.isEmpty)

                    Button("Reveal in Finder") {
                        Task { await DriveDomain.revealInFinder() }
                    }
                    .disabled(!registered)

                    Spacer()

                    Button("Remove drive", role: .destructive) {
                        Task {
                            await DriveDomain.unregister()
                            registered = await DriveDomain.isRegistered()
                            status = "Domain removed."
                        }
                    }
                }
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { registered = await DriveDomain.isRegistered() }
    }
}
