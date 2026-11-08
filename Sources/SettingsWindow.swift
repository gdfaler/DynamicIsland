import SwiftUI
import Combine
import ServiceManagement

/// The "launch at login" switch, which lives in the system rather than in UserDefaults.
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = SMAppService.mainApp.status == .enabled
    @Published var error: String?

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, displays, content, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("General")
        case .displays: return L("Displays")
        case .content: return L("Content")
        case .about: return L("About")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .displays: return "display"
        case .content: return "music.note"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return Color(white: 0.55)
        case .displays: return .blue
        case .content: return .pink
        case .about: return .teal
        }
    }
}

final class SettingsNavigation: ObservableObject {
    @Published var page: SettingsPage = ProcessInfo.processInfo.environment["ISLAND_SETTINGS_PAGE"]
        .flatMap(SettingsPage.init(rawValue:)) ?? .general
}

/// A System Settings–style icon: a white symbol on a colored rounded square.
private struct IconTile: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}

/// A switch with a title and a line of explanation under it.
private struct SettingToggle: View {
    var title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
    }
}

/// The settings window: a sidebar of pages and a grouped form for each, like System Settings.
struct SettingsView: View {
    @ObservedObject var settings: Settings
    @StateObject private var login = LoginItem()
    @ObservedObject var navigation: SettingsNavigation
    var checkForUpdates: () -> Void

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $navigation.page) { page in
                Label {
                    Text(page.title)
                } icon: {
                    IconTile(symbol: page.symbol, tint: page.tint)
                }
                .padding(.vertical, 2)
                .tag(page)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(190)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
        }
        .frame(width: 720, height: 540)
    }

    @ViewBuilder private var detail: some View {
        switch navigation.page {
        case .general: general
        case .displays: displays
        case .content: content
        case .about: about
        }
    }

    // MARK: Pages

    private var general: some View {
        Form {
            Section {
                SettingToggle(title: L("Expand on hover"), detail: L("Opens the island when the cursor rests on it."),
                              isOn: $settings.expandOnHover)
                SettingToggle(title: L("Trackpad haptics"), detail: L("A light tap when the island opens or reacts."),
                              isOn: $settings.haptics)
                SettingToggle(title: L("Show in fullscreen"), detail: L("Keep the island over fullscreen apps."),
                              isOn: $settings.showInFullscreen)
                SettingToggle(title: L("Menu bar icon"), detail: L("The icon that opens this menu."),
                              isOn: $settings.menuBarIcon)
                SettingToggle(title: L("Launch at login"), detail: nil,
                              isOn: Binding(get: { login.isEnabled }, set: { login.set($0) }))
                if let error = login.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section {
                SettingToggle(title: L("Check for updates automatically"),
                              detail: L("One request to the public GitHub Releases API every 12 hours; nothing else leaves your Mac."),
                              isOn: $settings.updateCheck)
                LabeledContent(L("Version"), value: UpdateChecker.currentVersion)
                Button(L("Check for updates…"), action: checkForUpdates)
            } header: {
                Text(L("Updates"))
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var displays: some View {
        Form {
            Section {
                Picker(L("Show on"), selection: $settings.displayMode) {
                    Text(L("Automatic (notch display)")).tag(DisplayMode.auto)
                    Text(L("Follow the cursor")).tag(DisplayMode.follow)
                    Text(L("All displays")).tag(DisplayMode.all)
                    Text(L("A chosen display")).tag(DisplayMode.pinned)
                }
                if settings.displayMode == .pinned {
                    Picker(L("Display"), selection: $settings.pinnedDisplay) {
                        ForEach(NSScreen.screens, id: \.uuid) { screen in
                            Text(screen.localizedName).tag(screen.uuid)
                        }
                    }
                }
            } header: {
                Text(L("Where the island lives"))
            }
            Section {
                SettingToggle(title: L("Island on displays without a notch"),
                              detail: L("A virtual notch at the top centre of the screen."),
                              isOn: $settings.virtualIsland)
                Picker(L("Look"), selection: $settings.virtualStyle) {
                    Text(L("Hidden until needed")).tag(VirtualStyle.hidden)
                    Text(L("Always visible")).tag(VirtualStyle.pill)
                    Text(L("Always visible, expand on click")).tag(VirtualStyle.clickPill)
                }
                .disabled(!settings.virtualIsland)
                Picker(L("Size"), selection: $settings.virtualScale) {
                    Text(L("Automatic")).tag(0.0)
                    ForEach([1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { scale in
                        Text("\(Int(scale * 100)) %").tag(scale)
                    }
                }
                .disabled(!settings.virtualIsland)
            } header: {
                Text(L("Without a notch"))
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var content: some View {
        Form {
            Section {
                SettingToggle(title: L("Music (Music, Spotify)"), detail: nil, isOn: $settings.music)
                SettingToggle(title: L("Music from browser (Safari, Chrome, Brave, Edge, Arc)"), detail: nil,
                              isOn: $settings.web)
                SettingToggle(title: L("Sound visualizer (screen recording)"),
                              detail: L("Needs the Screen Recording permission; only the audio is used."),
                              isOn: $settings.reactiveViz)
            } header: {
                Text(L("Music"))
            }
            Section {
                SettingToggle(title: L("Charging & low battery"), detail: nil, isOn: $settings.power)
                SettingToggle(title: L("Volume"), detail: nil, isOn: $settings.volume)
                SettingToggle(title: L("Audio devices"), detail: nil, isOn: $settings.devices)
            } header: {
                Text(L("Alerts"))
            }
            Section {
                SettingToggle(title: L("Now Playing from any app (experimental)"),
                              detail: L("Reads Now Playing from any app through a private macOS interface (via a helper process). May stop working after a macOS update."),
                              isOn: $settings.anyApp)
            } header: {
                Text(L("Experimental"))
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var about: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 84, height: 84)
                    Text("DynamicIsland").font(.title2.weight(.semibold))
                    Text(String(format: L("Version %@"), UpdateChecker.currentVersion))
                        .font(.callout).foregroundStyle(.secondary)
                    Text(L("Turns the MacBook notch into an iPhone-style dynamic island. Documented system facilities only."))
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            Section {
                Link(destination: URL(string: "https://github.com/\(UpdateChecker.repository)")!) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://github.com/\(UpdateChecker.repository)/issues")!) {
                    Label(L("Report a problem"), systemImage: "exclamationmark.bubble")
                }
                Link(destination: URL(string: "https://github.com/\(UpdateChecker.repository)/releases")!) {
                    Label(L("Release notes"), systemImage: "doc.text")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

/// Owns the window so it can be opened again from the menu.
final class SettingsWindowController {
    private var window: NSWindow?
    private let navigation = SettingsNavigation()
    private var titleWatch: AnyCancellable?

    func show(settings: Settings, checkForUpdates: @escaping () -> Void) {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(settings: settings, navigation: navigation,
                                                                  checkForUpdates: checkForUpdates))
            let window = NSWindow(contentViewController: host)
            // The title bar names the page, like System Settings.
            window.title = navigation.page.title
            titleWatch = navigation.$page.sink { [weak window] page in window?.title = page.title }
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
