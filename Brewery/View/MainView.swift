import SwiftUI

struct MainView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @ObservedObject var vm: BreweryViewModel
    @State private var navigation = NavigationHistory()
    @State private var discoverFocusRequest = 0
    @State private var installedFocusRequest = 0
    @State private var showOperations = false
    @State private var previousInstalledIDs: Set<PackageID> = []
    @State private var installedQuery = ""
    @State private var installedKind: PackageKind?
    @State private var installedSelection: Set<PackageID> = []
    @StateObject private var discoverViewModel: DiscoverViewModel
    #if DEBUG
    private var completeFixtureOperation: (() -> Void)?

    func fixtureOperationControl(_ action: @escaping () -> Void) -> Self {
        var view = self
        view.completeFixtureOperation = action
        return view
    }
    #endif

    init(vm: BreweryViewModel, catalogService: (any CatalogServing)? = nil) {
        self.vm = vm
        let values = AppPreferences.shared.values
        _navigation = State(initialValue: NavigationHistory(current: values.initialDestination))
        _installedQuery = State(initialValue: values.initialQuery)
        _installedKind = State(initialValue: values.initialKind)
        _discoverViewModel = StateObject(wrappedValue: DiscoverViewModel(service: catalogService ?? CatalogService.production(), preferences: AppPreferences.shared))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(vm: vm, destination: navigation.current) { navigation.navigate(to: $0) }
                .navigationSplitViewColumnWidth(min: 170, ideal: preferences.values.rememberWindow ? preferences.values.sidebarWidth : 190, max: 240)
                .background {
                    GeometryReader { geometry in
                        Color.clear.onChange(of: geometry.size.width) { width in
                            if preferences.values.rememberWindow && width >= 170 && width <= 240 {
                                preferences.values.sidebarWidth = width
                            }
                        }
                    }
                }
        } detail: {
            if vm.isHomebrewAvailable == false && navigation.current != .discover {
                homebrewSetup
            } else {
                destinationView
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { navigation.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .accessibilityIdentifier("toolbar.back")
                    .disabled(!navigation.canGoBack).keyboardShortcut("[", modifiers: .command).help("Back (⌘[)")
                Button { navigation.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                    .disabled(!navigation.canGoForward).keyboardShortcut("]", modifiers: .command).help("Forward (⌘])")
            }
            ToolbarItemGroup(placement: .automatic) {
                Button(action: focusSearch) { Label("Search", systemImage: "magnifyingglass") }
                    .accessibilityIdentifier("toolbar.search").keyboardShortcut("f", modifiers: .command).help("Search (⌘F)")
                Button(action: refreshCurrent) { Label("Refresh", systemImage: "arrow.clockwise") }
                    .accessibilityIdentifier("toolbar.refresh").keyboardShortcut("r", modifiers: .command).disabled(isRefreshing).help("Refresh current list (⌘R)")
                Button { showOperations = true } label: {
                    Label(vm.hasPendingOperations ? "Activity — In Progress" : "Activity", systemImage: vm.hasPendingOperations ? "clock.badge.exclamationmark" : "clock")
                }.accessibilityIdentifier("toolbar.activity").help("View operations and output")
            }
        }
        .sheet(isPresented: $showOperations) {
            #if DEBUG
            OperationsView(vm: vm).fixtureOperationControl(completeFixtureOperation)
            #else
            OperationsView(vm: vm)
            #endif
        }
        .alert("Homebrew Command Failed", isPresented: Binding(get: { vm.lastCommandError != nil }, set: { if !$0 { vm.clearCommandError() } })) {
            Button("OK") { vm.clearCommandError() }
        } message: { Text(vm.commandErrorMessage) }
        .onAppear { previousInstalledIDs = vm.installedPackageIDs }
        .onChange(of: navigation.current) { destination in
            switch destination {
            case .home: preferences.values.lastPage = "home"
            case .discover: preferences.values.lastPage = "search"
            case .installed(let updates): preferences.values.lastPage = updates ? "updates" : "installed"
            case .package: break
            }
        }
        .onReceive(preferences.resetEvents) {
            installedQuery = ""
            installedKind = nil
        }
        .onChange(of: installedQuery) { _ in saveFilters() }
        .onChange(of: installedKind) { _ in saveFilters() }
        .onChange(of: preferences.values.defaultKind) { value in
            installedKind = PackageKind(rawValue: value)
        }
        .onChange(of: preferences.values.rememberFilters) { enabled in
            if enabled { saveFilters() }
            else {
                preferences.values.hasSavedFilters = false
                preferences.values.savedQuery = ""
                preferences.values.savedKind = "all"
            }
        }
        .onChange(of: vm.installedPackageIDs) { newIDs in
            navigation.removePackages(previousInstalledIDs.subtracting(newIDs))
            installedSelection.formIntersection(newIDs)
            previousInstalledIDs = newIDs
        }
    }

    @ViewBuilder private var destinationView: some View {
        switch navigation.current {
        case .discover:
            DiscoverView(viewModel: discoverViewModel, breweryViewModel: vm, focusRequest: discoverFocusRequest) {
                navigation.navigate(to: .package($0))
            }.frame(minWidth: 560, minHeight: 360)
        case .installed(let outdatedOnly):
            InstalledPackagesView(
                vm: vm, outdatedOnly: outdatedOnly, focusRequest: installedFocusRequest,
                onOpenPackage: { navigation.navigate(to: .package($0)) },
                onChangeOutdatedFilter: { navigation.navigate(to: .installed(outdatedOnly: $0)) },
                query: $installedQuery, kind: $installedKind, selection: $installedSelection
            ).frame(minWidth: 560, minHeight: 360)
        case .package(let packageID):
            if vm.formula(for: packageID) != nil || vm.cask(for: packageID) != nil {
                BreweryDetailView(vm: vm, packageID: packageID) { navigation.navigate(to: .package(.formula($0))) }
                    .id(packageID.id).frame(minWidth: 380)
            } else {
                VStack(spacing: 12) {
                    Text("This package is no longer installed.").font(.headline)
                    Button("View Installed Packages") { navigation.navigate(to: .installed(outdatedOnly: false)) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .home:
            HomeView(vm: vm) { navigation.navigate(to: $0) }.frame(minWidth: 380, minHeight: 280, alignment: .top)
        }
    }

    private var homebrewSetup: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Connect Homebrew").font(.title2.bold())
            Text("Brewery could not find Homebrew. Install it using the official guide, then try again.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Link("Homebrew Installation Guide", destination: URL(string: "https://brew.sh")!)
            if let error = vm.inventoryError { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Button("Retry Connection") { Task { await vm.loadInstalled() } }.disabled(vm.isLoading)
                .accessibilityIdentifier("homebrew.retry")
            if vm.isLoading { ProgressView() }
        }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func saveFilters() {
        guard preferences.values.rememberFilters else { return }
        preferences.values.hasSavedFilters = true
        preferences.values.savedQuery = installedQuery
        preferences.values.savedKind = installedKind?.rawValue ?? "all"
    }

    private var isRefreshing: Bool { navigation.current == .discover ? discoverViewModel.isRefreshing : vm.isLoading }
    private func refreshCurrent() {
        Task {
            if navigation.current == .discover { await discoverViewModel.refresh(force: true) }
            else { await vm.loadInstalled() }
        }
    }
    private func focusSearch() {
        switch navigation.current {
        case .installed: installedFocusRequest += 1
        case .home, .discover, .package:
            navigation.navigate(to: .discover)
            discoverFocusRequest += 1
        }
    }
}

#Preview {
    MainView(vm: BreweryViewModel(loadOnInit: false))
}
