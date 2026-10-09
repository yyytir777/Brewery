import SwiftUI

@main
struct breweryApp: App {
    @ObservedObject private var preferences = AppPreferences.shared
    @StateObject private var breweryViewModel: BreweryViewModel
    private let catalogService: any CatalogServing
    #if DEBUG
    private let uiTestFixture: BreweryUITestFixture?
    #endif

    init() {
        #if DEBUG
        if let configuration = BreweryUITestScenario.configuration(arguments: ProcessInfo.processInfo.arguments,
                                                                   environment: ProcessInfo.processInfo.environment,
                                                                   bundleInfo: Bundle.main.infoDictionary ?? [:]) {
            let fixture = BreweryUITestFixture(configuration: configuration)
            uiTestFixture = fixture
            catalogService = fixture
            _breweryViewModel = StateObject(wrappedValue: BreweryViewModel(commandRunner: { await fixture.run($0, $1) }))
            return
        }
        uiTestFixture = nil
        #endif
        catalogService = CatalogService.production()
        _breweryViewModel = StateObject(wrappedValue: BreweryViewModel(loadOnInit: false, checkOutdatedOnLaunch: false))
    }

    var body: some Scene {
        WindowGroup {
            Group {
            #if DEBUG
            if let error = uiTestFixture?.configurationError {
                VStack(spacing: 12) {
                    Text("UI Test Fixture Error").font(.headline)
                    Text(error).multilineTextAlignment(.center)
                }.padding(32).frame(minWidth: 500, minHeight: 240)
                    .accessibilityIdentifier("fixture.error")
            } else if let fixture = uiTestFixture, fixture.requiresManualOperationCompletion {
                MainView(vm: breweryViewModel, catalogService: catalogService)
                    .fixtureOperationControl { fixture.completeFirstMutation() }
            } else {
                MainView(vm: breweryViewModel, catalogService: catalogService)
            }
            #else
            MainView(vm: breweryViewModel, catalogService: catalogService)
            #endif
            }
            .modifier(PreferencesAppearance())
            .disabled(breweryViewModel.isPreparingAppUpdate)
            .background(RememberWindowFrame(enabled: preferences.values.rememberWindow).frame(width: 0, height: 0))
            .task { SettingsRuntime.shared.start(vm: breweryViewModel) }
        }
            .defaultSize(width: 900, height: 600)
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(after: .appInfo) {
                    CheckForBreweryUpdatesButton(vm: breweryViewModel)
                }
            }
        Settings {
            #if DEBUG
            if uiTestFixture != nil {
                SettingsView(vm: breweryViewModel, catalogService: catalogService, allowsSystemActions: false)
                    .modifier(PreferencesAppearance())
            } else {
                SettingsView(vm: breweryViewModel, catalogService: catalogService)
                    .modifier(PreferencesAppearance())
            }
            #else
            SettingsView(vm: breweryViewModel, catalogService: catalogService)
                    .modifier(PreferencesAppearance())
            #endif
        }
    }
}
