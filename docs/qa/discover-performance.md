# Discover performance measurement

The last measured Release search recording reduced binding-to-AppKit-window-update p95 from 379.48 to 140.02 ms in one repeated workload on Apple M5 Pro. This is not raw key-event latency, GPU presentation time, or an FPS result. A separate final Refresh recording confirms cache/index work off main and one uncached row calculation; the evidence and its limits are reported separately below.

## Measured revision and later validation

The measured performance revision uses a shared background `CatalogExecutor` for cache access, validation and network JSON decoding; detached `CatalogIndex` preparation; cached natural-sort ranks; batched catalog/ranking publication; and `.id(scrollRequest)` on the List container. Rows retain their implicit `Identifiable` IDs. `catalogRevision` protects applied newer catalogs while permitting local results to appear during a pending refresh.

At the time of recording, this revision had passed 127 unit tests (0 failed/skipped), the full strict-concurrency build, and Universal Release compilation for arm64/x86_64. The UI target built for testing; compilation is not a completed UI test run. The exact measured binary was then relaunched and used for `search-index-final.trace` and `refresh-index-final.trace` (PID 41789). The earlier screen-lock interruption no longer blocks these final measurements.

Measured Universal executable: `/private/tmp/brewery-qa-completion/index-list-final/release-DD/Build/Products/Release/Brewery.app/Contents/MacOS/Brewery`, SHA-256 `98d38ad3604d1a59b736bffcb8606101e27fb7d7fb0c21ac0cd743af7ae07ca7`.

| Performance source | SHA-256 |
|---|---|
| `DiscoverViewModel.swift` | `451990bfd12049f8b5b7ce28e9db5fd0f7e1c409ac1df5ab4c38881d3441ae6a` |
| `DiscoverView.swift` | `be5d0cae3fd45c3933480a2a48f5b02e7bbe616ac3168ed101f26419d87e3668` |
| `CatalogService.swift` | `7e6f83793725965615bfd034aed882ddb561a0b1648aba7f2547ca00e356b9ea` |

These captures precede the later `BreweryCommand` completion fix, which replaced run-loop waiting with a termination callback and GCD pipe drains. The command-completion-stage Universal Release executable is `/private/tmp/brewery-qa-completion/command-completion-final/release-DD/Build/Products/Release/Brewery.app/Contents/MacOS/Brewery`, SHA-256 `21a038c2bf5cd0f33260435f251821519cbf360f880f2a2a48ef555795d88316`; its command source has SHA-256 `e4e09eaad4b321ba6befbb1b530f3679734eb5eddca27e97b1808d41afc7976b`. That revision passed 133 unit tests with strict concurrency and Swift warnings as errors, plus UI build-for-testing and Universal Release compilation. It has not received a new search/Refresh performance recording. In the tables below, “final” means the last measured performance revision, not this newer product binary.

The subsequent installed-version correction passed 141 strict unit tests (0 failed/skipped). After the async UI teardown adjustment, strict UI build-for-testing and Universal Release builds also succeeded. The latest executable is under `installed-version-final/release-DD/Build/Products/Release/Brewery.app/Contents/MacOS/Brewery`, SHA-256 `5d089548feb0c8af185b883aa7f85aa846f27e3c993aa07d7810155b5fa3d297`. It has no new performance capture. The same three performance source hashes were reverified against the measurement manifest, current files, and all five latest build manifests; `installed-version-final/performance-scope-verification.json` records the comparison. Neither later product binary replaces the measured `98d38…` binary in the results below.

The three performance files in the table were rehashed after the command fix and still match the measurement-time hashes, both `command-completion-final/inputs-final-before.json` and `inputs-final-after.json`, and the current worktree. `command-completion-final/performance-scope-verification.json` records this comparison and both executable hashes. This establishes unchanged performance source files; it does not turn the earlier runtime measurements into measurements of the newer executable.

Automated evidence is under `/private/tmp/brewery-qa-completion/search-index/final-verification.1wMoMh/` (`verification.json`, `summary.json`, `strict-build.log`) and `index-list-final/artifact-validation.log`. Build success and passing tests establish neither latency nor frame smoothness; the following runtime evidence is separate.

## Final search comparison

The baseline and final recordings used the same 64-replacement protocol with warm catalog, All type, 30-day period and an initially empty search, on Apple M5 Pro MacBook Pro (64 GB), macOS 26.6.2 (25G83), Xcode 26.6. Both were 60-second Time Profiler + Hitches + os_signpost recordings. Native input used accessibility observations only before and after each batch, with no per-edit hierarchy capture or competing SwiftUI trace finalizer.

The baseline (`search-controlled.trace`, PID 81158) retained explicit per-row `.id(row.id)` and synchronous scroll callbacks. The final binary (`search-index-final.trace`, PID 41789) includes the performance changes described at the start of this document. These are different source revisions; the comparison does not isolate the contribution of each final change.

| Measurement | Original baseline | Final binary |
|---|---:|---:|
| Changed-binding intervals | 228 | 228 |
| Completed (`outcome=updated`) | 89 | 94 |
| Superseded, excluded from completed latency | 139 | 134 |
| Completed median | 164.38 ms | 89.18 ms |
| Completed p95, nearest rank | 379.48 ms | 140.02 ms |
| Completed maximum | 493.19 ms | 152.63 ms |
| `DiscoverRows` calls, including cache hits | 335 | 276 |
| `DiscoverRows` median | 0.0119 ms | 0.0141 ms |
| `DiscoverRows` p95 | 48.78 ms | 60.21 ms |
| `DiscoverRows` maximum | 72.77 ms | 71.05 ms |
| `DiscoverRows` accumulated duration | 2,751.93 ms | 2,964.15 ms |

Completed median decreased 45.8% and p95 decreased 63.1% in this pair. Row-computation p95 and accumulated duration did not improve; the data do not support a claim that every component became faster. A replacement can generate multiple changed bindings, and coalescing changes which ones complete. The 89/94 completed samples are not matched observations or 64 whole-query measurements. Superseded intervals remain separate (median 0.590/0.588 ms; p95 1.081/1.045 ms). The native input loops took 20.37/11.244 seconds, which is execution context, not a product-latency metric.

| Query-active main-thread CPU stack membership | Baseline | Final binary |
|---|---:|---:|
| All main-thread sample weight | 17,223 ms | 9,213 ms |
| List/Table paths | 10,167 ms | 3,653 ms |
| `OutlineListCoordinator.diffRows` | 7,272 ms | 277 ms |
| `DiscoverView.rows.getter` | 2,743 ms | 2,962 ms |
| Accessibility hierarchy paths | 7 ms | 12 ms |

These are inclusive sampled weights during the union of query intervals, not independently additive CPU durations. They support substantially reduced list reconciliation work rather than reduced row-computation work.

The baseline contained 30 query-overlapping potential Microhangs; the final recording contained none overlapping query intervals. Its one 391.89 ms Microhang occurred outside the query batch. Hitches recorded one 16.67 ms baseline hitch outside the query batch and zero in the final capture. Frame tables were populated, but app-update coverage was only eight rows in each run. Zero classified hitches or query-overlapping hangs does not prove hitch-free typing, a frame rate, or GPU presentation latency. No `CatalogSearchIndex` interval occurred in this warm search capture; the separate Refresh recording below measures it.

## Final Refresh observation

`refresh-index-final.trace` attached to the same final binary/PID for 20 seconds. The view had warm data, empty search, All type and the 30-day period. One native Refresh click was followed by confirmation that catalog, Formula and Cask freshness times all changed to 3:23 PM. This run is separate from the search batch.

| Refresh measurement | List/Task stage | Executor-only stage | Final binary |
|---|---:|---:|---:|
| Cache reads / writes | 4 / 2, main | 4 / 2, worker | 4 / 2, worker |
| Cache-read accumulated duration | 418.78 ms | 350.00 ms | 116.14 ms |
| Cache-read maximum | 142.94 ms | 132.56 ms | 35.27 ms |
| Cache-write accumulated duration | 173.85 ms | 161.12 ms | 49.59 ms |
| Cache-write maximum | 108.53 ms | 107.96 ms | 29.16 ms |
| `CatalogSearchIndex` | Not instrumented | Not instrumented | 1 × 36.53 ms, worker |
| `DiscoverRows` calls including hits | 6 | 9 | 6 |
| Substantial uncached row calculations | 1 × 239.18 ms | 200.00 + 201.26 ms | 1 × 61.54 ms |
| `DiscoverRows` accumulated duration | 239.34 ms | 401.54 ms | 61.62 ms |

The final six cache intervals and single index interval began and ended on non-main thread `0x7bc229`. Cache intervals totaled 165.73 ms and include encoding/decoding, not only disk I/O. The detached index-preparation closure had 33 ms of worker sample weight and no main-thread stack samples. No main-thread catalog-worker or JSON decode/encode samples were observed. These support background execution and a single post-refresh row rebuild; the differing cache-duration totals alone do not isolate the effect of the indexing change, because network, observation and scheduling conditions vary between these single runs.

Two potential Microhangs lasted 378.53 and 367.40 ms, with 313 and 305 ms of accessibility hierarchy sample weight. Neither overlapped rows or index preparation; the first overlapped worker cache work in time, without main-thread cache/JSON stack samples. They are AX-heavy observations and are not treated as ordinary refresh-latency measurements. The AX-free 549/533 ms Hangs seen in the executor-only stage were not observed in this final capture. Whole-recording main-thread sample weight was 1,056 ms, including 620 ms in AX paths; that total is not a product refresh CPU-duration measurement.

Hitches contained zero rows, with only one app-update row. This does not establish FPS, GPU presentation timing, or stall-free refreshing. There is no button-to-refresh-completion signpost, and one refresh with four reads/two writes is not enough for a population p95. The final search result and final Refresh observation answer different questions.

## Intermediate evidence

Earlier recordings remain useful for identifying the measured changes, but are not final-binary results. In particular, the historical filename `search-final.trace` refers to the **List/Task intermediate**, not the final source or binary.

| Stage and trace | Distinguishing implementation | Observed evidence |
|---|---|---|
| Baseline: `search-controlled` | Explicit per-row ID | Search median/p95 164.38/379.48 ms |
| List/Task intermediate: `search-final` | Implicit row IDs; cancellable yield-and-scroll task | Search median/p95 82.17/204.96 ms; 91 completed, 137 superseded |
| Pre-executor Refresh: `search-refresh` | Cache and decoding still on MainActor | Six cache intervals, all main; 1,211.45 ms cache/row-overlapping Hang |
| Executor-only intermediate: `search-refresh-background` | Cache/JSON work on shared worker | Six cache intervals off main; two row calculations and 549.30/533.40 ms Hangs remained |
| Final: `search-index-final` | Background index, batched publication, List-container identity | Search results in the primary table above |
| Final Refresh: `refresh-index-final` | Same final binary | Six cache spans and index off main; one 61.54 ms uncached row calculation |

The two completed intermediate Refresh captures each used one native Refresh click, warm data, empty search, All type and 30-day period. Accessibility inspection confirmed catalog, Formula and Cask freshness times updated. Signposts include decode/encode and file operations; they do not measure disk I/O alone, and there is no button-to-refresh-completion interval.

| Intermediate Refresh measurement | Before executor (PID 90751) | After executor (PID 13881) |
|---|---:|---:|
| Cache reads/writes | 4/2, all main | 4/2, all worker `0x79fa38` |
| Cache-read accumulated / maximum | 418.78 / 142.94 ms | 350.00 / 132.56 ms |
| Cache-write accumulated / maximum | 173.85 / 108.53 ms | 161.12 / 107.96 ms |
| Main-thread catalog service/worker sample weight | 1,188 ms | 0 ms |
| Main-thread JSON decode / encode sample weight | 908 / 171 ms | 0 / 0 ms |
| `DiscoverRows` accumulated / maximum | 239.34 / 239.18 ms | 401.54 / 201.26 ms |

All six cache intervals in the executor-only capture began and ended on a worker. That worker had 339 ms of cache-read, 140 ms of cache-write and 710 ms of JSON-decoding sample weight. Its concurrent main-thread activity during cache intervals was 479 ms, including 477 ms in accessibility hierarchy paths: time overlap alone would misattribute observation overhead to cache execution.

The pre-executor 1,211.45 ms Hang had no AX samples and overlapped cache work and rows. A separate 342.73 ms Microhang was dominated by catalog JSON decoding. The executor-only capture instead showed two AX-free Hangs of 549.30/533.40 ms alongside roughly 200 ms row calculations, corresponding to separate catalog and ranking application. Those observations motivated the final batching/index change; the final Refresh follow-up is reported separately above. Both intermediate Refresh recordings also contained AX-heavy Hangs, excluded from ordinary-refresh interpretation. Neither is an end-to-end refresh-latency benchmark.

## Metric definitions and reproduction

Signposts are enabled by the recorder and do not log search text, package names or inventory contents.

| Interval | Start → end | Interpretation |
|---|---|---|
| `QueryToWindowUpdate` | Changed TextField binding → next AppKit window update after SwiftUI updates the probe | Main-thread binding-to-window-update path, not key event or display presentation |
| `DiscoverRows` | ViewModel.rows entry → return | Cached or filtering/sorting calls; multiple calls per edit |
| `CatalogCacheRead` | Cache read entry → decode result | Read/decode on the recorded thread |
| `CatalogCacheWrite` | Cache write entry → atomic save return | Encode/directory creation/write on the recorded thread |
| `CatalogSearchIndex` | Detached preparation entry → normalized fields/natural-sort ranks ready | Added in final source; measured in final Refresh, not the warm search batch |

Only `outcome=updated` belongs in completed latency statistics. Superseded edits and abandoned screens close outstanding intervals separately. Each window owns its tracker. Durations are exported in nanoseconds; p95 uses sorted index `ceil(0.95 × n) - 1`.

1. Build Release with `xcodebuild -project Brewery.xcodeproj -scheme Brewery -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/brewery-perf CODE_SIGNING_ALLOWED=NO build`.
2. Open that exact app, enter Discover, select All/30 days, clear search and wait for catalog/rankings. Record hardware, OS, Xcode, appearance, window dimensions, catalog count, cache state and binary/source hashes.
3. Run `zsh scripts/qa/profile_discover.sh PID /private/tmp/brewery-search.trace 60`. Default `light` mode uses Time Profiler, Hitches and os_signpost. Existing output paths, non-Brewery executables and durations outside 5–60 seconds are rejected. The script does not synthesize input or bypass privacy permissions.
4. Use native Command-A then `typeText` for each value below; an empty value uses Backspace. Repeat the 32-value sequence twice. Observe accessibility only before and after the batch, and retain at least 30 completed intervals. Keep other package work and trace exports idle.
5. Separately record one native Refresh click for 20 seconds. Inspect cache and index thread IDs/durations, row calls, CPU and potential hangs. Keep observations distinct from product work and report any AX overhead.

```text
g, gi, git, p, py, python, node, json, zzqaxnoresult, "",
g, gi, git, p, py, python, node, processor, zzqaxnoresult, "",
g, gi, git, p, py, python, node, json, zzqaxnoresult, "", git, ""
```

The script exports TOC, signposts and Hitches. For additional tables use `xcrun xctrace export --input TRACE --xpath '/trace-toc/run[@number="1"]/data/table[@schema="SCHEMA"]' --output XML`, choosing `time-profile`, `potential-hangs`, `hitches-frame-lifetimes` or `hitches-updates`. Resolve XML `id`/`ref` before calculating stacks or intervals. For separate SwiftUI graph diagnosis, use the script's `swiftui` mode for 5–15 seconds; graph reconstruction can be expensive.

## Artifacts and limitations

All raw traces and analysis artifacts are under `/private/tmp/brewery-qa-completion/`. Each analyzed trace stem has TOC, intervals, Hitches, CPU, hangs, frames and updates XML, plus analysis JSON. Session-local `analyze_trace.py STEM` and `analyze_refresh.py STEM` reproduce the calculations. `search-comparison-manifest.json` records stage-specific source/binary hashes; its historical `final` key means the List/Task intermediate, and `current_candidate` identifies the measured performance binary, before the later command-completion fix.

| Trace | Capture time, 2026-10-03 KST | Executable SHA-256 |
|---|---|---|
| `search-controlled` | 14:22:55.324–14:23:56.116 | `a157be518dc26247fd2a322f8c2828174241c80ffbf6e23d7723a42770ad1d20` |
| `search-final` | 14:32:49.802–14:33:50.451 | `ea706969dc0b18fe07d45bd0d4f204e5e17a97baf020496b3d957d6670fc565c` |
| `search-refresh` | 14:39:15.201–14:39:35.846 | Same List/Task intermediate |
| `search-refresh-background` | 14:51:16.655–14:51:37.361 | `cc65af7456af2276e77cf4b0819aca2a11dc0839a912f0cfd5ee4dd0dde931e8` |
| `search-index-final` | 15:17:53.247–15:18:54.005 | Final binary hash above |
| `refresh-index-final` | 15:22:55.795–15:23:16.422 | Same final binary |

This is one baseline/final pair on one machine, not a hardware-wide guarantee. Exact baseline window dimensions and catalog count were not recorded. A later public-cache read found 16,400 packages (8,625 Formula, 7,775 Cask); do not retroactively assign that count to earlier captures. Catalog refreshes occurred between stages, so equal package contents are not established.

Native checks on the preceding build with unchanged performance source hashes confirmed first Command-F focus, typing, and a separated scroll→observe→All/90-day change returning to offset 0. A batched scroll followed immediately by a filter click continued scrolling the new results in both Task and List-identity candidates. That fast-input/inertia boundary remains unresolved; List identity is not claimed to fix it.

Earlier idle probes established recording access only. The original 60-second `search-interaction.trace` spent over 15 minutes finalizing a roughly 1.1 GB SwiftUI graph with about 9 GB recorder memory. Samples showed Instruments graph reconstruction/serialization, not Brewery search execution. Its verified task-owned recorder was stopped with SIGINT then SIGTERM; raw trace and `search-interaction-stop.json` remain, with no usable latency result. `search-light.trace` had per-edit AX snapshots, a competing finalizer and different period/window history; it is excluded from the comparison. `search-implicit-id.trace` is another superseded intermediate.

PERF-01 has both search and Refresh evidence for the measured performance revision within the definitions above. Intel runtime, minimum-supported-macOS runtime and broad GPU/frame validation are unverified. Universal compilation does not verify Intel runtime performance.
