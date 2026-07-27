# Brewery Findings Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Brewery safer and more trustworthy by fixing command execution, visible failure handling, package identity collisions, crash-prone parsing, Homebrew metadata accuracy, and rough UI copy.

**Architecture:** Keep the existing small SwiftUI app structure, but introduce narrow model/helper types where they remove real risk. The command layer returns structured results, the view model owns user-facing command failure state, and views consume typed package identities instead of bare strings.

**Tech Stack:** Swift 5, SwiftUI, AppKit, Foundation `Process`, XCTest, Xcode macOS app target with macOS 13.0 deployment target.

## Global Constraints

- Keep `MACOSX_DEPLOYMENT_TARGET = 13.0`.
- Do not add third-party dependencies.
- Keep Homebrew command execution outside App Sandbox; current project setting is `ENABLE_APP_SANDBOX = NO`.
- Preserve the existing app flow: sidebar, home, search, detail, settings.
- Do not run destructive Homebrew commands during automated tests.
- Use `/opt/homebrew/bin/brew` and `/usr/local/bin/brew` as supported Homebrew executable candidates.
- Keep user-facing copy in English for this pass, matching the current app.

---

## File Structure

- Create `BreweryTests/BreweryCommandTests.swift`: unit tests for command process construction and structured command results.
- Create `BreweryTests/BreweryParsingTests.swift`: unit tests for safe model parsing, URL validation, and Homebrew metadata parsing.
- Create `BreweryTests/PackageIDTests.swift`: unit tests proving formula and cask identities do not collide.
- Create `Brewery/model/PackageIdentity.swift`: `PackageKind` and `PackageID` model types.
- Create `Brewery/model/BreweryMetadata.swift`: pure parsing helpers and outdated result DTOs.
- Modify `Brewery/util/BreweryCommand.swift`: replace shell string execution with direct executable execution and return `BreweryCommandResult`.
- Modify `Brewery/util/BreweryLogger.swift`: log structured command results including exit code.
- Modify `Brewery/model/BrewViewModel.swift`: consume `BreweryCommandResult`, publish command failure state, maintain typed package lookup and outdated sets.
- Modify `Brewery/data/BreweryData.swift`: remove force unwraps and align outdated display with view model helpers.
- Modify `Brewery/View/MainView.swift`: use `PackageID?` selection and present command failure alerts.
- Modify `Brewery/View/SideBarView.swift`: tag rows with typed identities and render outdated state via view model.
- Modify `Brewery/View/BreweryDetailVeiw.swift`: accept typed identity, route dependencies as formula identities, and disable destructive buttons while operations run.
- Modify `Brewery/View/SearchView.swift`: navigate with typed identities and polish search copy.
- Modify `Brewery/View/PackagePreviewView.swift`: surface install failure through shared view model state and polish button state.
- Modify `Brewery/View/HomeView.swift`: polish button copy, disabled states, and compact layout behavior.
- Modify `Brewery/View/RowInfoView.swift`: render invalid or missing URLs without crashing.
- Modify `Brewery.xcodeproj/project.pbxproj`: add the `BreweryTests` unit test target if it does not already exist.

---

### Task 1: Add Safe Structured Homebrew Command Execution

**Files:**
- Create: `BreweryTests/BreweryCommandTests.swift`
- Modify: `Brewery/util/BreweryCommand.swift:10-52`
- Modify: `Brewery/util/BreweryLogger.swift:38-64`
- Modify: `Brewery/model/BrewViewModel.swift:190-192`
- Modify: `Brewery.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: Existing `BreweryCommand.run(_ command: [String], logOutput: Bool) async -> String`.
- Produces:
  - `struct BreweryCommandResult: Equatable`
  - `BreweryCommandResult.arguments: [String]`
  - `BreweryCommandResult.stdout: String`
  - `BreweryCommandResult.stderr: String`
  - `BreweryCommandResult.exitCode: Int32`
  - `BreweryCommandResult.succeeded: Bool`
  - `BreweryCommandResult.displayOutput: String`
  - `BreweryCommand.run(_ arguments: [String], logOutput: Bool = true) async -> BreweryCommandResult`
  - `BreweryCommand.makeProcess(brewURL: URL, arguments: [String], environment: [String: String]) -> Process`
  - `BreweryLogger.log(result: BreweryCommandResult, logOutput: Bool, duration: TimeInterval) async`

- [ ] **Step 1: Add a unit test target**

In Xcode, add a macOS Unit Testing Bundle target named `BreweryTests`.

Use these exact settings:

```text
Product Name: BreweryTests
Team: None
Organization Identifier: yyytir777
Language: Swift
Host Application: Brewery
Include Tests: Yes
```

Then confirm the scheme can see the tests:

```bash
xcodebuild -project Brewery.xcodeproj -scheme Brewery -showTestPlans
```

Expected: command completes successfully. It is acceptable if Xcode reports that the scheme uses automatic test discovery.

- [ ] **Step 2: Write the failing command construction tests**

Create `BreweryTests/BreweryCommandTests.swift` with:

```swift
import XCTest
@testable import Brewery

final class BreweryCommandTests: XCTestCase {
    func testMakeProcessUsesBrewExecutableDirectly() {
        let process = BreweryCommand.makeProcess(
            brewURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            arguments: ["search", "git"],
            environment: ["PATH": "/opt/homebrew/bin"]
        )

        XCTAssertEqual(process.executableURL?.path, "/opt/homebrew/bin/brew")
        XCTAssertEqual(process.arguments, ["search", "git"])
    }

    func testMakeProcessDoesNotShellJoinArguments() {
        let suspiciousQuery = "git; echo injected"
        let process = BreweryCommand.makeProcess(
            brewURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            arguments: ["search", suspiciousQuery],
            environment: ["PATH": "/opt/homebrew/bin"]
        )

        XCTAssertEqual(process.arguments, ["search", suspiciousQuery])
        XCTAssertFalse(process.arguments?.joined(separator: " ").contains("brew search") ?? true)
    }

    func testCommandResultSuccessFlagAndDisplayOutput() {
        let success = BreweryCommandResult(
            arguments: ["search", "git"],
            stdout: "git\n",
            stderr: "",
            exitCode: 0
        )
        let failure = BreweryCommandResult(
            arguments: ["install", "missing-package"],
            stdout: "",
            stderr: "Error: No formulae found.\n",
            exitCode: 1
        )

        XCTAssertTrue(success.succeeded)
        XCTAssertEqual(success.displayOutput, "git\n")
        XCTAssertFalse(failure.succeeded)
        XCTAssertEqual(failure.displayOutput, "Error: No formulae found.\n")
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS' -only-testing:BreweryTests/BreweryCommandTests
```

Expected: FAIL because `BreweryCommandResult` and `makeProcess` do not exist yet.

- [ ] **Step 4: Implement structured direct execution**

Replace `Brewery/util/BreweryCommand.swift` with:

```swift
import Foundation

struct BreweryCommandResult: Equatable {
    let arguments: [String]
    let stdout: String
    let stderr: String
    let exitCode: Int32

    var succeeded: Bool { exitCode == 0 }
    var displayOutput: String { stdout.isEmpty ? stderr : stdout }
}

final class BreweryCommand {
    private static let brewCandidatePaths = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew"
    ]

    static func run(_ arguments: [String], logOutput: Bool = true) async -> BreweryCommandResult {
        await Task.detached(priority: .userInitiated) {
            let start = Date()

            guard let brewURL = resolveBrewURL() else {
                let result = BreweryCommandResult(
                    arguments: arguments,
                    stdout: "",
                    stderr: "Homebrew executable not found at /opt/homebrew/bin/brew or /usr/local/bin/brew.",
                    exitCode: 127
                )
                await BreweryLogger.shared.log(result: result, logOutput: logOutput, duration: Date().timeIntervalSince(start))
                return result
            }

            let process = makeProcess(
                brewURL: brewURL,
                arguments: arguments,
                environment: makeEnvironment()
            )

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                let result = BreweryCommandResult(
                    arguments: arguments,
                    stdout: "",
                    stderr: error.localizedDescription,
                    exitCode: 126
                )
                await BreweryLogger.shared.log(result: result, logOutput: logOutput, duration: Date().timeIntervalSince(start))
                return result
            }

            async let stdoutRead = Task.detached(priority: .userInitiated) {
                stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            }.value
            async let stderrRead = Task.detached(priority: .userInitiated) {
                stderrPipe.fileHandleForReading.readDataToEndOfFile()
            }.value

            let (stdoutData, stderrData) = await (stdoutRead, stderrRead)
            process.waitUntilExit()

            let result = BreweryCommandResult(
                arguments: arguments,
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? "",
                exitCode: process.terminationStatus
            )

            await BreweryLogger.shared.log(result: result, logOutput: logOutput, duration: Date().timeIntervalSince(start))
            return result
        }.value
    }

    static func makeProcess(brewURL: URL, arguments: [String], environment: [String: String]) -> Process {
        let process = Process()
        process.executableURL = brewURL
        process.arguments = arguments
        process.environment = environment
        return process
    }

    private static func resolveBrewURL() -> URL? {
        for path in brewCandidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func makeEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let currentPath = environment["PATH"] ?? ""
        environment["TERM"] = "dumb"
        environment["HOME"] = NSHomeDirectory()
        environment["PATH"] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            currentPath
        ]
        .filter { !$0.isEmpty }
        .joined(separator: ":")
        return environment
    }
}
```

Replace `BreweryLogger.log(command:stdout:stderr:duration:)` with:

```swift
func log(result: BreweryCommandResult, logOutput: Bool, duration: TimeInterval) async {
    let timestamp = dateFormatter.string(from: Date())
    var lines = ["[\(timestamp)] CMD: brew \(result.arguments.joined(separator: " "))"]

    if logOutput, !result.stdout.isEmpty {
        lines.append("[\(timestamp)] OUT: \(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
    } else if !logOutput {
        lines.append("[\(timestamp)] OUT: (output skipped)")
    }

    if !result.stderr.isEmpty {
        lines.append("[\(timestamp)] ERR: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    lines.append("[\(timestamp)] EXIT: \(result.exitCode)")
    lines.append("[\(timestamp)] DONE (\(String(format: "%.2f", duration))s)\n")

    let entry = lines.joined(separator: "\n") + "\n"
    guard let data = entry.data(using: .utf8) else { return }

    if FileManager.default.fileExists(atPath: fileURL.path) {
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    } else {
        try? data.write(to: fileURL, options: .atomic)
    }
}
```

Temporarily preserve the existing view model behavior by changing `BrewViewModel.exec` to:

```swift
private func exec(_ args: [String], logOutput: Bool = true) async -> String {
    await BreweryCommand.run(args, logOutput: logOutput).displayOutput
}
```

- [ ] **Step 5: Run command tests**

Run:

```bash
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS' -only-testing:BreweryTests/BreweryCommandTests
```

Expected: PASS.

- [ ] **Step 6: Build the app**

Run:

```bash
xcodebuild build -project Brewery.xcodeproj -scheme Brewery -configuration Debug -derivedDataPath /private/tmp/brewery-derived
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Brewery/util/BreweryCommand.swift Brewery/util/BreweryLogger.swift Brewery/model/BrewViewModel.swift BreweryTests/BreweryCommandTests.swift Brewery.xcodeproj/project.pbxproj
git commit -m "fix: execute brew without shell interpolation"
```

---

### Task 2: Surface Homebrew Command Failures in the UI

**Files:**
- Modify: `Brewery/model/BrewViewModel.swift:53-192`
- Modify: `Brewery/View/MainView.swift:17-52`
- Modify: `Brewery/View/PackagePreviewView.swift:73-83`
- Test: `BreweryTests/BreweryCommandTests.swift`

**Interfaces:**
- Consumes:
  - `BreweryCommandResult` from Task 1.
  - `BreweryCommand.run(_ arguments: [String], logOutput: Bool = true) async -> BreweryCommandResult` from Task 1.
- Produces:
  - `BreweryViewModel.lastCommandError: BreweryCommandResult?`
  - `BreweryViewModel.commandErrorMessage: String`
  - `BreweryViewModel.clearCommandError()`
  - `BreweryViewModel.recordFailure(_ result: BreweryCommandResult)`
  - `BreweryViewModel.execResult(_ args: [String], logOutput: Bool = true) async -> BreweryCommandResult`

- [ ] **Step 1: Add unit tests for failure message formatting**

Append to `BreweryTests/BreweryCommandTests.swift`:

```swift
@MainActor
final class BreweryViewModelCommandErrorTests: XCTestCase {
    func testRecordFailurePublishesReadableMessage() {
        let vm = BreweryViewModel(loadOnInit: false)
        let result = BreweryCommandResult(
            arguments: ["install", "definitely-missing-package"],
            stdout: "",
            stderr: "Error: No formulae or casks found.\n",
            exitCode: 1
        )

        vm.recordFailure(result)

        XCTAssertEqual(vm.lastCommandError, result)
        XCTAssertEqual(
            vm.commandErrorMessage,
            "brew install definitely-missing-package failed with exit code 1.\n\nError: No formulae or casks found."
        )
    }

    func testClearCommandErrorRemovesPublishedFailure() {
        let vm = BreweryViewModel(loadOnInit: false)
        vm.recordFailure(BreweryCommandResult(arguments: ["update"], stdout: "", stderr: "failed", exitCode: 1))

        vm.clearCommandError()

        XCTAssertNil(vm.lastCommandError)
        XCTAssertEqual(vm.commandErrorMessage, "")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS' -only-testing:BreweryTests/BreweryViewModelCommandErrorTests
```

Expected: FAIL because `BreweryViewModel(loadOnInit:)`, `recordFailure`, `clearCommandError`, and command error properties do not exist.

- [ ] **Step 3: Add view model failure state**

In `Brewery/model/BrewViewModel.swift`, change the initializer and add failure state:

```swift
@Published var lastCommandError: BreweryCommandResult?

var commandErrorMessage: String {
    guard let result = lastCommandError else { return "" }
    let command = "brew " + result.arguments.joined(separator: " ")
    let output = result.displayOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    if output.isEmpty {
        return "\(command) failed with exit code \(result.exitCode)."
    }
    return "\(command) failed with exit code \(result.exitCode).\n\n\(output)"
}

init(loadOnInit: Bool = true) {
    if loadOnInit {
        Task { await loadInstalled() }
    }
}

func recordFailure(_ result: BreweryCommandResult) {
    guard !result.succeeded else { return }
    lastCommandError = result
}

func clearCommandError() {
    lastCommandError = nil
}

private func execResult(_ args: [String], logOutput: Bool = true) async -> BreweryCommandResult {
    let result = await BreweryCommand.run(args, logOutput: logOutput)
    if !result.succeeded {
        recordFailure(result)
    }
    return result
}

private func exec(_ args: [String], logOutput: Bool = true) async -> String {
    await execResult(args, logOutput: logOutput).displayOutput
}
```

For command methods that mutate packages, keep the operation-specific set cleanup and rely on `execResult`:

```swift
public func installFormula(name: String) async {
    installingPackages.insert(name)
    defer { installingPackages.remove(name) }

    let result = await execResult(["install", name])
    guard result.succeeded else { return }
    await loadAllBrew()
}
```

Apply the same success guard pattern to:

```swift
updateBrew(name:isCask:)
brewSelfUpdate()
brewCleanUp()
uninstallCask(name:)
uninstallCaskWithZap(name:)
uninstallFormula(name:)
installCask(name:)
installFormula(name:)
```

- [ ] **Step 4: Add the alert to `MainView`**

In `Brewery/View/MainView.swift`, attach this alert to the root view after `.toolbar`:

```swift
.alert("Homebrew Command Failed", isPresented: Binding(
    get: { vm.lastCommandError != nil },
    set: { isPresented in
        if !isPresented {
            vm.clearCommandError()
        }
    }
)) {
    Button("OK") {
        vm.clearCommandError()
    }
} message: {
    Text(vm.commandErrorMessage)
}
```

- [ ] **Step 5: Improve preview install button state**

In `Brewery/View/PackagePreviewView.swift`, replace the install button label with:

```swift
Button(vm.installingPackages.contains(name) ? "Installing..." : "Install") {
    Task {
        if isCask { await vm.installCask(name: name) }
        else { await vm.installFormula(name: name) }
    }
}
.buttonStyle(.borderedProminent)
.disabled(vm.installingPackages.contains(name))
```

- [ ] **Step 6: Run tests**

Run:

```bash
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS' -only-testing:BreweryTests/BreweryViewModelCommandErrorTests
```

Expected: PASS.

- [ ] **Step 7: Build the app**

Run:

```bash
xcodebuild build -project Brewery.xcodeproj -scheme Brewery -configuration Debug -derivedDataPath /private/tmp/brewery-derived
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add Brewery/model/BrewViewModel.swift Brewery/View/MainView.swift Brewery/View/PackagePreviewView.swift BreweryTests/BreweryCommandTests.swift
git commit -m "fix: show homebrew command failures"
```

---

### Task 3: Use Typed Package Identity for Formula and Cask Selection

**Files:**
- Create: `Brewery/model/PackageIdentity.swift`
- Create: `BreweryTests/PackageIDTests.swift`
- Modify: `Brewery/data/BreweryData.swift:8-12`
- Modify: `Brewery/model/BrewViewModel.swift:45-51`
- Modify: `Brewery/View/MainView.swift:13-35`
- Modify: `Brewery/View/SideBarView.swift:13-55`
- Modify: `Brewery/View/BreweryDetailVeiw.swift:15-40`
- Modify: `Brewery/View/SearchView.swift:12-53`

**Interfaces:**
- Consumes: Existing formula and cask model names.
- Produces:
  - `enum PackageKind: String, Codable, Hashable { case formula, cask }`
  - `struct PackageID: Hashable, Identifiable, Codable`
  - `PackageID.kind: PackageKind`
  - `PackageID.name: String`
  - `PackageID.id: String`
  - `PackageID.formula(_ name: String) -> PackageID`
  - `PackageID.cask(_ name: String) -> PackageID`
  - `SearchResult.packageID: PackageID`
  - `BreweryViewModel.formula(for id: PackageID) -> BreweryFormula?`
  - `BreweryViewModel.cask(for id: PackageID) -> BreweryCask?`

- [ ] **Step 1: Write identity collision tests**

Create `BreweryTests/PackageIDTests.swift` with:

```swift
import XCTest
@testable import Brewery

final class PackageIDTests: XCTestCase {
    func testFormulaAndCaskWithSameNameHaveDifferentIdentity() {
        let formula = PackageID.formula("foo")
        let cask = PackageID.cask("foo")

        XCTAssertNotEqual(formula, cask)
        XCTAssertEqual(formula.id, "formula:foo")
        XCTAssertEqual(cask.id, "cask:foo")
    }

    func testSearchResultExposesTypedPackageID() {
        let formulaResult = SearchResult(name: "git", isCask: false)
        let caskResult = SearchResult(name: "firefox", isCask: true)

        XCTAssertEqual(formulaResult.packageID, .formula("git"))
        XCTAssertEqual(caskResult.packageID, .cask("firefox"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS' -only-testing:BreweryTests/PackageIDTests
```

Expected: FAIL because `PackageID` and `SearchResult.packageID` do not exist.

- [ ] **Step 3: Create package identity model**

Create `Brewery/model/PackageIdentity.swift`:

```swift
import Foundation

enum PackageKind: String, Codable, Hashable {
    case formula
    case cask
}

struct PackageID: Hashable, Identifiable, Codable {
    let kind: PackageKind
    let name: String

    var id: String { "\(kind.rawValue):\(name)" }

    static func formula(_ name: String) -> PackageID {
        PackageID(kind: .formula, name: name)
    }

    static func cask(_ name: String) -> PackageID {
        PackageID(kind: .cask, name: name)
    }
}
```

Modify `SearchResult` in `Brewery/data/BreweryData.swift`:

```swift
struct SearchResult: Decodable, Identifiable {
    var id: String { packageID.id }
    var packageID: PackageID { isCask ? .cask(name) : .formula(name) }
    let name: String
    let isCask: Bool
}
```

- [ ] **Step 4: Update view model lookup helpers**

In `Brewery/model/BrewViewModel.swift`, keep existing string helpers for compatibility and add typed helpers:

```swift
func formula(for id: PackageID) -> BreweryFormula? {
    guard id.kind == .formula else { return nil }
    return formulaMap[id.name]
}

func cask(for id: PackageID) -> BreweryCask? {
    guard id.kind == .cask else { return nil }
    return caskMap[id.name]
}
```

- [ ] **Step 5: Update main selection flow**

In `Brewery/View/MainView.swift`, change:

```swift
@State private var selected: String? = nil
```

to:

```swift
@State private var selected: PackageID? = nil
```

Change detail routing to:

```swift
if let selected {
    BreweryDetailView(vm: vm, packageID: selected) { dep in
        selected = .formula(dep)
    }
    .id(selected.id)
    .frame(minWidth: 380)
}
```

- [ ] **Step 6: Update sidebar tags**

In `Brewery/View/SideBarView.swift`, change the binding:

```swift
@Binding var selected: PackageID?
```

For casks:

```swift
Text(cask.name)
    .tag(PackageID.cask(cask.name) as PackageID?)
```

For formulae:

```swift
Text(formula.name)
    .tag(PackageID.formula(formula.name) as PackageID?)
```

- [ ] **Step 7: Update detail view identity**

In `Brewery/View/BreweryDetailVeiw.swift`, replace:

```swift
let name: String
```

with:

```swift
let packageID: PackageID
```

Update body lookup:

```swift
if let formula = vm.formula(for: packageID) {
    detailFormulaSection(formula: formula)
} else if let cask = vm.cask(for: packageID) {
    detailCaskSection(cask: cask)
} else {
    Text("Information not found.")
        .foregroundStyle(.secondary)
}
```

Update navigation title and info fetch:

```swift
.navigationTitle(packageID.name)
.task(id: packageID.id) {
    brewInfoText = await vm.fetchInfo(name: packageID.name)
}
```

- [ ] **Step 8: Update search navigation**

In `Brewery/View/SearchView.swift`, change:

```swift
@Binding var selected: String?
```

to:

```swift
@Binding var selected: PackageID?
```

Change row action:

```swift
selected = result.packageID
showSearch = false
```

- [ ] **Step 9: Run identity tests**

Run:

```bash
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS' -only-testing:BreweryTests/PackageIDTests
```

Expected: PASS.

- [ ] **Step 10: Build the app**

Run:

```bash
xcodebuild build -project Brewery.xcodeproj -scheme Brewery -configuration Debug -derivedDataPath /private/tmp/brewery-derived
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 11: Commit**

```bash
git add Brewery/model/PackageIdentity.swift Brewery/data/BreweryData.swift Brewery/model/BrewViewModel.swift Brewery/View/MainView.swift Brewery/View/SideBarView.swift Brewery/View/BreweryDetailVeiw.swift Brewery/View/SearchView.swift BreweryTests/PackageIDTests.swift
git commit -m "fix: distinguish formula and cask selection"
```

---

### Task 4: Remove Crash-Prone Force Unwraps in Model and Link Rendering

**Files:**
- Create: `BreweryTests/BreweryParsingTests.swift`
- Modify: `Brewery/data/BreweryData.swift:30-32`
- Modify: `Brewery/View/RowInfoView.swift:25-42`

**Interfaces:**
- Consumes: Existing `BreweryFormula.installed_date` and `infoLinkRow(key:url:)`.
- Produces:
  - `BreweryFormula.installed_date: Double?` returns nil when `installed` is empty.
  - `validatedHTTPURL(from value: String) -> URL?`
  - `infoLinkRow(key: String, url: String) -> some View` no longer force unwraps.

- [ ] **Step 1: Write parsing and URL tests**

Create `BreweryTests/BreweryParsingTests.swift` with:

```swift
import XCTest
@testable import Brewery

final class BreweryParsingTests: XCTestCase {
    func testFormulaInstalledDateIsNilWhenInstalledArrayIsEmpty() {
        let formula = BreweryFormula(
            name: "empty",
            full_name: "empty",
            tap: "homebrew/core",
            desc: nil,
            homepage: "https://example.com",
            license: nil,
            outdated: false,
            dependencies: [],
            installed: [],
            versions: FormulaVersions(stable: "1.0.0", head: nil, bottle: nil)
        )

        XCTAssertNil(formula.installed_date)
    }

    func testValidatedHTTPURLAcceptsHTTPAndHTTPSOnly() {
        XCTAssertEqual(validatedHTTPURL(from: "https://brew.sh")?.absoluteString, "https://brew.sh")
        XCTAssertEqual(validatedHTTPURL(from: "http://example.com")?.absoluteString, "http://example.com")
        XCTAssertNil(validatedHTTPURL(from: ""))
        XCTAssertNil(validatedHTTPURL(from: "not a url"))
        XCTAssertNil(validatedHTTPURL(from: "file:///etc/passwd"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS' -only-testing:BreweryTests/BreweryParsingTests
```

Expected: FAIL because `installed_date` force unwraps or `validatedHTTPURL` does not exist.

- [ ] **Step 3: Make installed date safe**

In `Brewery/data/BreweryData.swift`, change:

```swift
var installed_date: Double? { installed.first!.time }
```

to:

```swift
var installed_date: Double? { installed.first?.time }
```

- [ ] **Step 4: Make link rendering safe**

In `Brewery/View/RowInfoView.swift`, add:

```swift
func validatedHTTPURL(from value: String) -> URL? {
    guard let url = URL(string: value),
          let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme) else {
        return nil
    }
    return url
}
```

Replace the current `Link(url, destination: URL(string: url)!)` block with:

```swift
if let destination = validatedHTTPURL(from: url) {
    Link(url, destination: destination)
        .onHover { hovering in
            hovering ? NSCursor.pointingHand.push() : NSCursor.pop()
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .textSelection(.enabled)
} else {
    Text(url.isEmpty ? "unknown" : url)
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
}
```

- [ ] **Step 5: Run parsing tests**

Run:

```bash
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS' -only-testing:BreweryTests/BreweryParsingTests
```

Expected: PASS.

- [ ] **Step 6: Build the app**

Run:

```bash
xcodebuild build -project Brewery.xcodeproj -scheme Brewery -configuration Debug -derivedDataPath /private/tmp/brewery-derived
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Brewery/data/BreweryData.swift Brewery/View/RowInfoView.swift BreweryTests/BreweryParsingTests.swift
git commit -m "fix: avoid crashes from missing data"
```

---

### Task 5: Parse Homebrew Metadata and Outdated State More Reliably

**Files:**
- Create: `Brewery/model/BreweryMetadata.swift`
- Modify: `Brewery/model/BrewViewModel.swift:75-110`
- Modify: `Brewery/View/HomeView.swift:14-18`
- Modify: `Brewery/View/SideBarView.swift:23-26,42-45`
- Modify: `Brewery/View/BreweryDetailVeiw.swift:54-74,177-198`
- Test: `BreweryTests/BreweryParsingTests.swift`

**Interfaces:**
- Consumes:
  - `BreweryCommandResult` from Task 1.
  - `PackageID` from Task 3.
- Produces:
  - `enum BreweryMetadata`
  - `BreweryMetadata.parseVersion(from output: String) -> String`
  - `BreweryMetadata.parseSize(from output: String) -> String`
  - `struct BrewOutdatedResult: Decodable`
  - `BreweryViewModel.outdatedFormulaNames: Set<String>`
  - `BreweryViewModel.outdatedCaskNames: Set<String>`
  - `BreweryViewModel.isOutdated(_ id: PackageID) -> Bool`
  - `BreweryViewModel.outdatedCount: Int`

- [ ] **Step 1: Add metadata parser tests**

Append to `BreweryTests/BreweryParsingTests.swift`:

```swift
final class BreweryMetadataTests: XCTestCase {
    func testParseVersionUsesFirstNonEmptyLine() {
        let output = "\nHomebrew 4.5.0\nHomebrew/homebrew-core abc123\n"

        XCTAssertEqual(BreweryMetadata.parseVersion(from: output), "Homebrew 4.5.0")
    }

    func testParseSizeUsesLastCommaSeparatedComponentWhenPresent() {
        let output = "Homebrew 4.5.0 (/opt/homebrew)\n24 files, 74.3MB\n"

        XCTAssertEqual(BreweryMetadata.parseSize(from: output), "74.3MB")
    }

    func testParseSizeReturnsUnknownForEmptyOutput() {
        XCTAssertEqual(BreweryMetadata.parseSize(from: ""), "unknown")
    }

    func testOutdatedResultDecodesFormulaeAndCasks() throws {
        let json = """
        {
          "formulae": [
            { "name": "git", "installed_versions": ["2.1.0"], "current_version": "2.2.0", "pinned": false, "pinned_version": null }
          ],
          "casks": [
            { "name": "firefox", "installed_versions": ["120.0"], "current_version": "121.0" }
          ]
        }
        """

        let result = try JSONDecoder().decode(BrewOutdatedResult.self, from: Data(json.utf8))

        XCTAssertEqual(result.formulae.map(\.name), ["git"])
        XCTAssertEqual(result.casks.map(\.name), ["firefox"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS' -only-testing:BreweryTests/BreweryMetadataTests
```

Expected: FAIL because `BreweryMetadata` and `BrewOutdatedResult` do not exist.

- [ ] **Step 3: Create metadata parsing helpers**

Create `Brewery/model/BreweryMetadata.swift`:

```swift
import Foundation

enum BreweryMetadata {
    static func parseVersion(from output: String) -> String {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "unknown"
    }

    static func parseSize(from output: String) -> String {
        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines.reversed() {
            let pieces = line
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if let last = pieces.last, last.range(of: #"^\d+(\.\d+)?\s?(KB|MB|GB|TB)$"#, options: .regularExpression) != nil {
                return last
            }
        }

        return "unknown"
    }
}

struct BrewOutdatedResult: Decodable {
    let formulae: [OutdatedFormula]
    let casks: [OutdatedCask]
}

struct OutdatedFormula: Decodable {
    let name: String
}

struct OutdatedCask: Decodable {
    let name: String
}
```

- [ ] **Step 4: Use metadata parser in view model**

In `Brewery/model/BrewViewModel.swift`, add:

```swift
@Published private(set) var outdatedFormulaNames: Set<String> = []
@Published private(set) var outdatedCaskNames: Set<String> = []

var outdatedCount: Int {
    outdatedFormulaNames.count + outdatedCaskNames.count
}

func isOutdated(_ id: PackageID) -> Bool {
    switch id.kind {
    case .formula:
        return outdatedFormulaNames.contains(id.name)
    case .cask:
        return outdatedCaskNames.contains(id.name)
    }
}
```

Change `loadBrewMeta()` to:

```swift
public func loadBrewMeta() async {
    let version = await exec(["--version"])
    brewVersion = BreweryMetadata.parseVersion(from: version)

    let info = await exec(["info"])
    brewSize = BreweryMetadata.parseSize(from: info)
}
```

Add:

```swift
private func loadOutdatedPackages() async {
    let json = await exec(["outdated", "--json=v2"], logOutput: false)
    guard let data = json.data(using: .utf8) else {
        outdatedFormulaNames = []
        outdatedCaskNames = []
        return
    }

    do {
        let result = try JSONDecoder().decode(BrewOutdatedResult.self, from: data)
        outdatedFormulaNames = Set(result.formulae.map(\.name))
        outdatedCaskNames = Set(result.casks.map(\.name))
    } catch {
        outdatedFormulaNames = []
        outdatedCaskNames = []
    }
}
```

Change `loadInstalled()` to:

```swift
func loadInstalled() async {
    isLoading = true
    await loadAllBrew()
    await loadOutdatedPackages()
    await loadBrewMeta()
    isLoading = false
}
```

After successful install, uninstall, update, cleanup, and self-update, call:

```swift
await loadAllBrew()
await loadOutdatedPackages()
```

- [ ] **Step 5: Update outdated UI usage**

In `Brewery/View/HomeView.swift`, replace the local `outdatedCount` computed property usage with:

```swift
StatCard(title: "Outdated", value: "\(vm.outdatedCount)", isLoading: vm.isLoading)
```

In `Brewery/View/SideBarView.swift`, replace cask outdated checks with:

```swift
if vm.isOutdated(.cask(cask.name)) {
    Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(.orange)
}
```

Replace formula outdated checks with:

```swift
if vm.isOutdated(.formula(formula.name)) {
    Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(.orange)
}
```

In `Brewery/View/BreweryDetailVeiw.swift`, replace formula outdated checks:

```swift
if vm.isOutdated(.formula(formula.name)) {
    Text("-> \(formula.latest_version)")
        .font(.subheadline)
        .foregroundStyle(.orange)
        .textSelection(.enabled)
    ...
} else {
    Text("Latest")
        .font(.subheadline)
        .foregroundStyle(.green)
}
```

Replace cask outdated checks:

```swift
if vm.isOutdated(.cask(cask.name)) {
    Text("-> \(cask.latest_version)")
        .font(.subheadline)
        .foregroundStyle(.orange)
        .textSelection(.enabled)
    ...
} else {
    Text("Latest")
        .font(.subheadline)
        .foregroundStyle(.green)
        .textSelection(.enabled)
}
```

- [ ] **Step 6: Run metadata tests**

Run:

```bash
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS' -only-testing:BreweryTests/BreweryMetadataTests
```

Expected: PASS.

- [ ] **Step 7: Build the app**

Run:

```bash
xcodebuild build -project Brewery.xcodeproj -scheme Brewery -configuration Debug -derivedDataPath /private/tmp/brewery-derived
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add Brewery/model/BreweryMetadata.swift Brewery/model/BrewViewModel.swift Brewery/View/HomeView.swift Brewery/View/SideBarView.swift Brewery/View/BreweryDetailVeiw.swift BreweryTests/BreweryParsingTests.swift
git commit -m "fix: derive outdated state from brew outdated"
```

---

### Task 6: Polish User-Facing Copy and Small-Screen Layout

**Files:**
- Modify: `Brewery/View/HomeView.swift:22-69`
- Modify: `Brewery/View/SearchView.swift:20-55`
- Modify: `Brewery/View/BreweryDetailVeiw.swift:64-68,140-163,187-191,238-280`
- Modify: `Brewery/View/PackagePreviewView.swift:40-83`
- Modify: `Brewery/View/RowInfoView.swift:10-42`

**Interfaces:**
- Consumes:
  - Existing SwiftUI views.
  - `BreweryViewModel.isRunningUpdate`, `isRunningCleanup`, `installingPackages`, `uninstallingPackages`, and `updatingPackageNames`.
- Produces:
  - Corrected text: `Cleaning...`, `Search for a formula or cask`.
  - Consistent button labels: `Update`, `Uninstall`, `Uninstall and Delete Data`, `Brew Update`, `Brew Cleanup`.
  - Cask auto-update display: `Yes` or `No`.
  - Buttons disabled while their matching command is already running.

- [ ] **Step 1: Fix home copy and command button states**

In `Brewery/View/HomeView.swift`, change cleanup label:

```swift
Label(vm.isRunningCleanup ? "Cleaning..." : "Brew Cleanup", systemImage: "trash")
```

Add cleanup disabled state:

```swift
.disabled(vm.isRunningCleanup)
```

Keep update disabled state:

```swift
.disabled(vm.isRunningUpdate)
```

- [ ] **Step 2: Fix search copy**

In `Brewery/View/SearchView.swift`, change:

```swift
Text("Search for a formla or cask")
```

to:

```swift
Text("Search for a formula or cask")
```

- [ ] **Step 3: Standardize detail action labels**

In `Brewery/View/BreweryDetailVeiw.swift`, change formula update button:

```swift
Button("Update") {
    Task { await vm.updateBrew(name: formula.name, isCask: false) }
}
```

Change formula uninstall button:

```swift
Button("Uninstall", role: .destructive) {
    zapOnUninstall = false
    showUninstallConfirm = true
}
.disabled(vm.uninstallingPackages.contains(formula.name))
```

Change cask update button:

```swift
Button("Update") {
    Task { await vm.updateBrew(name: cask.name, isCask: true) }
}
```

Change cask menu labels:

```swift
Button("Uninstall", role: .destructive) {
    zapOnUninstall = false
    showUninstallConfirm = true
}

Button("Uninstall and Delete Data", role: .destructive) {
    zapOnUninstall = true
    showUninstallConfirm = true
}
```

Change auto-update row:

```swift
infoRow(key: "Auto updates", value: cask.auto_updates == true ? "Yes" : "No")
```

- [ ] **Step 4: Make row text fit better**

In `Brewery/View/RowInfoView.swift`, update `infoRow` value text:

```swift
Text(value)
    .multilineTextAlignment(.trailing)
    .lineLimit(2)
    .truncationMode(.middle)
    .textSelection(.enabled)
```

Update the key column width:

```swift
.frame(width: 120, alignment: .leading)
```

Apply the same `width: 120` change in `infoLinkRow`.

- [ ] **Step 5: Build the app**

Run:

```bash
xcodebuild build -project Brewery.xcodeproj -scheme Brewery -configuration Debug -derivedDataPath /private/tmp/brewery-derived
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Manually inspect the main screens**

Launch the built app:

```bash
open /private/tmp/brewery-derived/Build/Products/Debug/Brewery.app
```

Check these screens:

```text
Home:
- "Cleaning..." is spelled correctly while cleanup runs.
- Brew Cleanup is disabled while cleanup runs.
- Stat cards remain readable at the default 900 x 600 window size.

Search:
- Empty state reads "Search for a formula or cask".
- Search results still show View and Install actions.

Detail:
- Update and Uninstall labels use Title Case.
- Cask auto-update row says Yes or No.
- Long homepage and version values truncate without overlapping labels.
```

- [ ] **Step 7: Commit**

```bash
git add Brewery/View/HomeView.swift Brewery/View/SearchView.swift Brewery/View/BreweryDetailVeiw.swift Brewery/View/PackagePreviewView.swift Brewery/View/RowInfoView.swift
git commit -m "polish: tighten brewery interface copy"
```

---

## Final Verification

- [ ] **Step 1: Run all tests**

```bash
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS'
```

Expected: all `BreweryTests` tests pass.

- [ ] **Step 2: Run a clean build**

```bash
xcodebuild clean build -project Brewery.xcodeproj -scheme Brewery -configuration Debug -derivedDataPath /private/tmp/brewery-derived
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run a smoke test with real Homebrew**

Launch the app and verify:

```text
Home loads installed package counts.
Sidebar shows formulae and casks.
Search for "git" returns formula results.
Opening an installed package shows detail information.
Running Brew Update either completes or shows a readable failure alert.
Opening Settings shows log file size.
```

- [ ] **Step 4: Confirm git state**

```bash
git status --short
```

Expected: no uncommitted changes except user-owned files that predated this plan.

---

## Self-Review

Spec coverage:
- Shell command injection risk is covered by Task 1.
- Missing command failure UI is covered by Task 2.
- Formula/cask identity collision is covered by Task 3.
- Force unwrap crash points are covered by Task 4.
- Brittle version, size, and outdated parsing are covered by Task 5.
- Visual copy and small layout polish are covered by Task 6.

Banned empty-step scan:
- Each task has concrete files, interfaces, code snippets, commands, and expected results.
- No deferred implementation notes remain.

Type consistency:
- `BreweryCommandResult`, `PackageID`, and `BreweryMetadata` signatures are introduced before later tasks consume them.
- View updates consistently use `PackageID` after Task 3.
- Outdated UI consistently uses `BreweryViewModel.isOutdated(_:)` after Task 5.
