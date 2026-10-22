import Foundation

if CommandLine.arguments.contains("--lineage-child") {
    Thread.sleep(forTimeInterval: 60)
    exit(0)
}

// Existing fixtures use temporary homes; ignore the developer’s real config roots.
unsetenv("CLAUDE_CONFIG_DIR")
unsetenv("CODEX_HOME")

// Minimal XCTest stand-in: Command Line Tools ship no XCTest, and scripts/test.sh builds with plain swiftc.
var failures = 0
var ran = 0
var current = ""

func report(_ message: String, _ file: StaticString, _ line: UInt) {
    failures += 1
    print("FAIL \(current) \(file):\(line) \(message)")
}

func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) {
    if a != b { report("\(a) != \(b) \(message)", file, line) }
}
func XCTAssertNil<T>(_ a: T?, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) {
    if let a { report("expected nil, got \(a) \(message)", file, line) }
}
func XCTAssertTrue(_ a: Bool, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) {
    if !a { report("expected true \(message)", file, line) }
}
func XCTAssertFalse(_ a: Bool, file: StaticString = #fileID, line: UInt = #line) {
    if a { report("expected false", file, line) }
}
func XCTFail(_ message: String, file: StaticString = #fileID, line: UInt = #line) { report(message, file, line) }
struct Unwrap: Error {}
func XCTUnwrap<T>(_ a: T?, file: StaticString = #fileID, line: UInt = #line) throws -> T {
    guard let a else { report("unexpected nil", file, line); throw Unwrap() }
    return a
}

func run(_ name: String, _ body: () throws -> Void) {
    ran += 1
    current = name
    do { try body() } catch { report("threw \(error)", #fileID, #line) }
}

// AN-0.5-T1: synthetic on-disk formats, exercised through the production readers.
let sessionFixtures = SessionLogFixtureChecks()
run("fixtureClaudeSubagents") { try sessionFixtures.claudeSubagents() }
run("fixtureCodexCurrent") { try sessionFixtures.codexCurrent() }
run("fixtureCodexLegacy") { try sessionFixtures.codexLegacy() }
run("fixtureResumedReaders") { try sessionFixtures.resumedReaders() }
run("fixtureTruncatedRecovery") { try sessionFixtures.truncatedRecovery() }
run("fixtureRotation") { try sessionFixtures.rotation() }
run("fixtureResumedDiscovery") { try sessionFixtures.resumedDiscoveryExpectedFail() }
if ProcessInfo.processInfo.environment["NOTCH_EXPECTED_FAIL"] == "1" {
    run("EXPECTED-FAIL fixtureTruncatedTail") { try sessionFixtures.truncatedTailExpectedFail() }
} else {
    print("SKIP EXPECTED-FAIL fixtureTruncatedTail (NOTCH_EXPECTED_FAIL=1 to run)")
}

// Most checks assert the Russian copy; LanguageChecks switches to English for its own run.
Loc.forced = .ru
run("updateLaunchModes") { UpdateChecks().launchModes() }
run("codexAutomaticReviewRouting") { try HookTests().testCodexAutomaticReviewDoesNotWaitForAHuman() }
run("codexAutomaticMCPRoundTrip") { try HookTests().testCodexAutomaticMCPReturnsToCodexWithoutAPrompt() }
let l = LogTests(), t = TreeTests(), w = WingTests()
run("watcherTargetedPaths") { try FileWatcherChecks().changedPathsAndLiveness() }
run("watcherSubagentsAndCodex") { try FileWatcherChecks().subagentsAndOldCodexPaths() }
run("watcherProcessExit") { try FileWatcherChecks().processExitNeedsNoDiskRead() }
run("watcherExecDiscoveryAndExit") { try FileWatcherChecks().processDiscoveryDrainsExitedStreams() }
run("watcherSymlinkRoots") { try FileWatcherChecks().remapsSymlinkedRootsAndStatusDirectories() }
run("watcherQueuedDrop") { try FileWatcherChecks().queuedDropSurvivesLegacyPoll() }
run("watcherCanonicalAndLiveDelivery") { try FileWatcherChecks().canonicalEventsAndLiveDelivery() }
run("watcherExactExecInterests") { try FileWatcherChecks().execInterestsStayOnFiles() }
run("watcherNarrowRoots") { try FileWatcherChecks().narrowRootsAndInterests() }
run("watcherRetentionExpiry") { try FileWatcherChecks().nextFinishedExpiry() }
run("watcherDrops") { FileWatcherChecks().droppedEventsRequestFullScan() }
run("processRefreshRateLimit") { ProcessEventChecks().coalescesChurnWithTrailingRefresh() }
run("processArgumentsCache") { ProcessEventChecks().cachesArgumentsUntilExitReuseOrExec() }
run("incrementalEventsAndReconciliation") { try IncrementalScanChecks().eventsAndReconciliation() }
run("incrementalReconcileRootsAndExec") { try IncrementalScanChecks().reconciliationRemapsRootsAndDrainsExec() }
run("incrementalAliasesAndLegacyStatus") { try IncrementalScanChecks().aliasesAndLegacyStatus() }
run("incrementalSessionLayout") { try IncrementalScanChecks().discoveryStaysWithinSessionLayout() }
let discovery = CodexDiscoveryChecks()
run("codexResumedOldFolder") { try discovery.resumedOldFolderAndAppendedTail() }
run("codexTruncatedBoundedRead") { try discovery.resetReadsBoundedTail(replaced: false) }
run("codexReplacedBoundedRead") { try discovery.resetReadsBoundedTail(replaced: true) }
run("codexColdFolderStats") { try discovery.coldFoldersBoundStats() }
run("codexTodayListing") { try discovery.recentListingsAreNeverTrusted(today: true) }
run("codexRecentListing") { try discovery.recentListingsAreNeverTrusted(today: false) }
run("scannerCoalesces") { try discovery.overlappingPollsCoalesce() }
run("scannerBothVendors") { try l.testScannerReadsBothVendorsIntoOneProject() }
run("scannerRewrittenLog") { try ScannerRewriteChecks().rewrittenLogClearsThePreviousTurn() }
run("scannerPartialLines") { try ScannerRewriteChecks().partialLinesWaitForTheirNewline() }
run("logTimeValues") { LogTimeChecks().datesKeepTheirValues() }
run("logTimeInvalidDoesNotExtendSession") { try LogTimeChecks().invalidTimeDoesNotExtendSession() }
run("claudeProcessStatus") { try l.testClaudeProcessStatusWins() }
run("stateRules") { l.testStateRules() }
run("subagentHandback") { try l.testSubagentHandbackEndsTheSubagent() }
run("execArgs") { ExecChecks().testReadsExecRunArguments() }
run("execShell") { ExecChecks().testShellWrapperIsStripped() }
run("execRun") { try ExecChecks().testExecRunIsWorkingUntilItsProcessEnds() }
run("execRelativeCwd") { ExecIdentityChecks().relativeDirectoryUsesTheRunningProcess() }
run("execResumeCwd") { ExecIdentityChecks().resumedRunUsesTheRunningProcessDirectory() }
run("execSessionIdentity") { try ExecIdentityChecks().retainedSessionAndExecStreamMakeOneRow() }
run("execDistinctIdentity") { try ExecIdentityChecks().distinctThreadsInOneDirectoryStaySeparate() }
run("execRetainedLifecycle") { try ExecIdentityChecks().retainedSessionUsesExecLifecycle() }
run("execLongIdentity") { try ExecIdentityChecks().longExecStreamKeepsThreadIdentity() }
run("lineageNearest") { LineageChecks().testPicksTheNearestKnownParent() }
run("lineageEnv") { LineageChecks().testReadsBothVendorIdsFromTheEnvironment() }
run("rolloutPaths") { RolloutLineageChecks().rolloutPaths() }
run("rolloutOpenFile") { try RolloutLineageChecks().openRolloutFile() }
run("rolloutLineageRetention") { try RolloutLineageChecks().workerKeepsItsParentAfterExitAndReset() }
run("rolloutNativeParent") { try RolloutLineageChecks().nativeParentWins() }
run("rolloutNearestParent") { try RolloutLineageChecks().nearestParentAcrossVendors() }
run("rolloutExecMerge") { try RolloutLineageChecks().execStreamStillMerges() }
run("claudeQuestion") { try l.testClaudeQuestionWaitsUntilAnswered() }
run("nestsGrandchildren") { t.testNestsGrandchildrenUnderTheRootAndOrphansBecomeRoots() }
run("dropsFinishedProjects") { t.testProjectsWithOnlyFinishedAgentsAreDropped() }
run("attentionFirst") { t.testProjectWithAttentionSortsFirst() }
run("smallProjectDetailed") { w.testSmallProjectDrawsEveryLiveAgent() }
run("busyProjectCounters") { w.testBusyProjectSwitchesToCountersAndKeepsExceptions() }
run("crampedSummary") { w.testCrampedOrTooWideCollapsesIntoOneSummary() }
run("nothingLive") { w.testNothingLiveDrawsNothing() }
run("deliveryWaitsForReceipt") { try SecurityDeliveryChecks().waitsForReceipt() }
run("deliveryStdoutBroken") { try DeliveryFixChecks().helperStdout("broken") }
run("deliveryStdoutSuccess") { try DeliveryFixChecks().helperStdout("success") }
run("deliveryStdoutFull") { try DeliveryFixChecks().helperStdout("full") }
run("deliveryStdoutLarge") { try DeliveryFixChecks().helperStdout("large") }
run("deliveryOversizedIdentity") { try DeliveryFixChecks().oversizedIdentity() }
run("deliveryUnsentDisconnect") { try DeliveryFixChecks().unsentDisconnect() }
run("deliveryUnconfirmedExpiry") { try DeliveryFixChecks().unconfirmedExpiry() }
run("deliveryIdenticalCommands") { try DeliveryIdentityRegressionChecks().identicalCommands() }
run("deliveryQuestionRoute") { try DeliveryIdentityRegressionChecks().questionRoute() }
run("deliveryAck") { try SecurityDeliveryChecks().receiptAndFailure("ack") }
run("deliveryWriteError") { try SecurityDeliveryChecks().receiptAndFailure("write-error") }
run("deliveryAckTimeout") { try SecurityDeliveryChecks().receiptAndFailure("timeout") }
run("deliveryWrongAck") { try SecurityDeliveryChecks().receiptAndFailure("wrong-ack") }
run("deliveryFragmentedAck") { try SecurityDeliveryChecks().receiptAndFailure("fragmented-ack") }
run("deliveryDelayedAck") { try SecurityDeliveryChecks().receiptAndFailure("delayed-ack") }
run("deliveryLateAndDuplicate") { try SecurityDeliveryChecks().lateAndDuplicate() }
run("deliveryNoClick") { try SecurityDeliveryChecks().noClick() }
run("deliveryStateAndIdentity") { try SecurityDeliveryChecks().stateAndIdentity() }
let connectionChecks = ConnectionChecks()
run("connectionPartialSetRefreshesHelper") { try connectionChecks.partialSetRefreshesHelper() }
run("connectionFullSet") { try connectionChecks.fullSet() }
run("connectionStates") { try connectionChecks.states() }
run("connectionDiagnostic") { try connectionChecks.diagnostic() }
run("connectionDoctor") { try connectionChecks.doctor() }
run("connectionTrust") { try connectionChecks.trust() }
run("connectionDoctorCLI") { try connectionChecks.doctorCLI() }
let h = HookTests()
run("hookParseReply") { try h.testParsesEventAndRepliesOnlyWithAClick() }
run("hookRoundTrip") { try h.testPermissionWaitsForTheClickAndNothingWithoutTheApp() }
run("hookGone") { try h.testHungUpHookIsReportedGone() }
run("hookOverlay") { h.testOverlayWaitsUntilTheAgentMovesOn() }
run("hookInstaller") { try h.testInstallerKeepsOtherHooksAndRemovesOnlyOurs() }

// NOTCH-detail
let detail = DetailChecks()
run("detailClaude") { try detail.claude() }
run("detailCodex") { try detail.codex() }
run("codexExecCardLog") { try CodexCardLogChecks().execCardLog() }
run("codexExecCardCompletionOnly") { try CodexCardLogChecks().execCompletionWithoutStart() }
run("codexRolloutCardWebSearch") { try CodexCardLogChecks().rolloutWebSearch() }
run("codexExecCardWebActions") { try CodexCardLogChecks().execWebActionsAndDeclinedCommand() }
run("codexCardRunErrors") { try CodexCardLogChecks().codexRunErrors() }
run("detailWorktrees") { try detail.worktrees() }
run("detailTasksAndBounds") { try detail.tasksAndBounds() }
run("detailCodexOutputs") { try detail.codexOutputs() }
run("detailFailedAndStreamed") { try detail.failedAndStreamed() }
run("detailOutcomeDeduplication") { try detail.outcomeDeduplication() }
let prompts = PromptChecks()
run("promptsClaude") { try prompts.claude() }
run("promptsCodex") { try prompts.codex() }
run("promptsStartSurvivesTail") { try prompts.startSurvivesTail() }
run("promptsBounds") { try prompts.bounds() }
run("promptsWrapped") { try prompts.wrapped() }
run("promptsSubagent") { try prompts.subagent() }
run("promptsCodexLongHead") { try prompts.codexLongHead() }
run("promptsTabMigration") { prompts.migration() }
// NOTCH-usage
let usage = UsageChecks()
run("usageLimits") { try usage.limits() }
run("usageClaudeLimits") { try usage.claudeLimits() }
run("usageContext") { try usage.context() }
run("usageContextOverDefault") { try usage.contextOverDefaultWindow() }
run("usageSpend") { try usage.spend() }

run("usageIncrementalSpend") { try usage.incrementalSpend() }
run("usageCachedSpend") { try usage.cachedSpend() }

run("usageSpendCopiesAndSynthetic") { try usage.spendCopiesAndSynthetic() }
// NOTCH-jump
let j = JumpChecks()
run("jumpPreferTerminalProcess") { try j.preferTerminalProcess() }
run("jumpSkipAppServer") { j.skipAppServer() }
run("jumpResumeControls") { try j.resumeControls() }
run("jumpTerminalSelectionFallback") { j.terminalSelectionFallback() }
run("jumpPreciseCodexAndResume") { try j.preciseCodexAndResume() }
run("jumpClaudeCLI") { try j.claudeCLI() }
run("jumpClaudeDesktop") { try j.claudeDesktop() }
run("jumpCodexCLI") { try j.codex("codex_exec", desktop: false) }
run("jumpCodexDesktop") { try j.codex("Codex Desktop", desktop: true) }
run("jumpSubagents") { try j.subagents() }
run("jumpFallbackAndEditor") { try j.fallbackAndEditor() }

run("jumpMetadataEdges") { try j.metadataEdges() }
// NOTCH-always
let always = AlwaysChecks()
run("alwaysPrefixes") { try always.prefixes() }
run("alwaysRefused") { always.refused() }
run("alwaysWebAndMCP") { try always.webAndMCP() }
run("alwaysClaudeReply") { try always.reply() }
run("alwaysCodexRules") { try always.codexRules() }
run("alwaysCodexExistingFile") { try always.codexExistingFile() }
run("alwaysCodexEscapingAndLinks") { try always.codexEscapingAndLinks() }
// NOTCH-answers
let an = AnswerTests()
run("answerParse") { try an.testParsesQuestionsAndPlan() }
run("answerReply") { try an.testAnswerReplyCarriesTheChosenAnswers() }
run("planReply") { try an.testPlanAcceptAndReturnReplies() }
run("answerSocket") { try an.testSocketCarriesTheAnswerBack() }
// NOTCH-settings
let settings = SettingsChecks()
run("settingsOrdering") { settings.ordering() }
run("settingsCodable") { try settings.roundTrip() }
run("settingsLimits") { settings.limits() }
run("settingsStorage") { try settings.storage() }
run("scratchDefaults") { try settings.scratchDefaults() }
run("settingsShortcuts") { try settings.shortcuts() }

// NOTCH-ui-hooks
run("hookInstallerAnswerEntry") { try h.testInstallerAddsSynchronousPreToolUseForAnswers() }
run("hookPreToolUseReply") { try h.testPreToolUseReplyShapes() }
run("hookServerWaitsForAnswers") { try h.testServerWaitsOnlyForPermissionAndAnswerTools() }
run("hookAnswerRoute") { try h.testPermissionRequestAfterAHeldPreToolUseIsHandedBack() }
run("alwaysSocket") { try always.socketCarriesTheRule() }
run("alwaysSocketRoundTrip") { try always.socketRoundTrip() }
let finish = FinishChecks()
run("finishSummary") { finish.summary() }
run("finishWatcher") { finish.watcher() }
// NOTCH-ui-card
let card = CardChecks()
run("cardGrouping") { card.grouping() }
run("cardVisibility") { card.visibility() }
run("cardPrompts") { card.prompts() }
run("cardFormatting") { card.formatting() }
// NOTCH-ui-usage
let usageView = UsageViewChecks()
run("usageViewThresholds") { usageView.thresholds() }
run("usageViewChips") { usageView.chips() }
run("usageViewResets") { usageView.resets() }
run("usageViewContextRefresh") { usageView.contextRefresh() }
// NOTCH-ui-settings
run("uiSettingsRetention") { settings.finishedRetention() }
run("uiSettingsScannerRetention") { try settings.scannerRetention() }
run("uiSettingsRowOrder") { settings.rowRenderingOrder() }
run("uiSettingsWing") { settings.wingSettings() }

// NOTCH-fix-sec
run("securityInvalidAlwaysStdout") { try SecurityReplyChecks().invalidAlways() }

run("securityGitGlobalOptions") { SecurityHookChecks().gitGlobals() }
run("securityExactHookOwnership") { try SecurityHookChecks().exactOwnership() }

run("securityCurrentQuestionLabels") { try SecurityStateChecks().currentLabels() }
run("securityServerIdentity") { try SecurityStateChecks().serverIdentity() }
run("securityConcurrentHookEdit") { try SecurityStateChecks().concurrentEdit() }
run("securityHookEditRetries") { try SecurityStateChecks().boundedRetries() }
// NOTCH-fix-settings
run("settingsPendingVisibility") { settings.pendingVisibility() }
run("settingsLegacySort") { try settings.legacySort() }
run("settingsTreeModes") { settings.treeModes() }
run("settingsHiddenWorktree") { try settings.hiddenWorktree() }
run("settingsSessionSorts") { settings.sessionSorts() }
run("settingsFlatSessions") { settings.flatSessions() }
run("settingsVisibilityAndPass") { settings.visibilityAndPass() }
// NOTCH-fix-usage
let usageFix = UsageFixChecks()
run("usageExpiredLimits") { try usageFix.expiredLimits() }
run("usageOutputDoesNotExpandWindow") { try usageFix.outputDoesNotExpandWindow() }

run("usageConfiguredThresholds") { usageFix.configuredThresholds() }
run("usageFileCache") { try usageFix.fileCache() }
run("usageWorktreeCache") { try usageFix.worktreeCache() }

run("usageWindowSelection") { usageFix.windowSelection() }

run("usageLimitsCacheAndEarlyStop") { try usageFix.limitsCacheAndEarlyStop() }

run("usageCodexFutureAndDuration") { try usageFix.codexFutureAndDuration() }
run("pinnedServer") { try SecurityHookChecks().pinnedServer() }
run("filterOwnersAndRoots") { try SettingsChecks().filterOwnersAndRoots() }

// NOTCH-settings-presets
let presets = PresetChecks()
run("presetBrief") { presets.brief() }
run("presetDetailed") { presets.detailed() }
run("presetEverything") { presets.everything() }
run("presetOwnAndBack") { presets.ownAndBack() }
run("iconAppPresent") { try presets.iconAppPresent() }
run("iconAppMissing") { presets.iconAppMissing() }
run("iconFileMissing") { try presets.iconFileMissing() }
run("settingsNoJargon") { try presets.noJargon() }
let sessionCost = SessionCostChecks()
run("sessionCostClaude") { try sessionCost.claude() }
run("sessionCostCodex") { try sessionCost.codex() }
run("sessionCostFormat") { sessionCost.format() }
let language = LanguageChecks()
run("languageDetect") { language.detect() }
run("languageEnglish") { language.english() }
let promptVault = PromptVaultChecks()
run("promptRanking") { promptVault.ranking() }
run("promptStats") { promptVault.stats() }
run("promptFile") { try promptVault.file() }
let skills = SkillCatalogChecks()
run("skillFrontMatter") { skills.frontMatter() }
run("skillCatalog") { try skills.catalog() }
run("skillUsage") { skills.usage() }
run("skillRanking") { skills.ranking() }

let libraryChecks = SoundLibraryChecks()
run("soundLibraryStartupAndReplacedManifestLinks") { try libraryChecks.rejectsStartupDirectoryAndReplacedManifestLinks() }
run("soundLibraryOwnedCopy") { try libraryChecks.persistsOwnedCopy() }
run("soundLibraryDuplicatesAndRemoval") { try libraryChecks.duplicateNamesAndRemoval() }
run("soundLibraryBadManifest") { try libraryChecks.rejectsBadManifestAndPaths() }
run("soundLibraryRollback") { try libraryChecks.rollsBackPersistenceFailure() }
run("soundLibraryNonFiles") { try libraryChecks.rejectsSymlinkAndNonFile() }
run("soundLibraryDanglingAndReplacedDirectory") { try libraryChecks.rejectsDanglingManifestAndReplacedDirectory() }
let soundChecks = SoundChecks()
run("soundPresets") { try soundChecks.presets() }
run("soundPreferences") { try soundChecks.preferences() }
run("soundTransitions") { soundChecks.transitions() }
run("soundRequests") { soundChecks.requests() }
run("soundRequestsEn") { Loc.forced = .en; defer { Loc.forced = .ru }; soundChecks.requests() }
run("soundLimits") { soundChecks.limits() }
run("soundNativeRequests") { soundChecks.nativeRequests() }

let safeUninstall = SafeUninstallChecks()
run("appContinuesAfterClaudeComment") { try safeUninstall.appContinuesAfterClaudeComment() }
run("helperRejectsInstall") { try safeUninstall.helperRejectsInstall() }
run("auditHonorsProcessLock") { try safeUninstall.auditHonorsProcessLock() }
run("safeInstallVendorFailures") { try safeUninstall.vendorFailures("--install-hooks") }
run("safeUninstallVendorFailures") { try safeUninstall.vendorFailures("--uninstall-hooks") }
run("safeJSONCPreservation") { try safeUninstall.jsoncIsPreserved() }
run("safeInvalidConfigRoots") { try safeUninstall.invalidRootsArePreserved() }
run("safeCustomRootsWithoutEnvironment") { try safeUninstall.customRootsWithoutEnvironment() }
run("safeAuditRotation") { try safeUninstall.auditRotates() }
run("auditDeliveryResult") { try safeUninstall.auditDelivery() }
if case let .success((dir, _, _)) = SafeUninstallChecks.tools { try? FileManager.default.removeItem(at: dir) }

let configRoots = ConfigRootChecks()
run("configClaudeHooks") { try configRoots.hooks(.claude) }
run("configCodexHooks") { try configRoots.hooks(.codex) }
run("configClaudeDiscovery") { try configRoots.discovery(.claude) }
run("configCodexDiscovery") { try configRoots.discovery(.codex) }
run("configClaudeProjects") { try configRoots.claudeProjects() }
run("configSkillsLiveAndRules") { try configRoots.skillsLiveAndRules() }

let honestDone = HonestDoneChecks()
run("honestSilence") { try honestDone.silence() }
run("honestInterrupted") { try honestDone.interrupted() }
run("honestHelpers") {
    let forced = Loc.forced
    Loc.forced = .en
    defer { Loc.forced = forced }
    try honestDone.helpers()
}
run("honestNestedHelpers") { honestDone.nestedHelpers() }
run("honestAborted") { honestDone.aborted() }
run("honestHookEnds") { try honestDone.hookEnds() }
run("honestRetainedFailedExec") { try honestDone.retainedFailedExec() }
run("honestRetainedParent") { try honestDone.retainedParent() }
run("honestColdCodexParent") { try honestDone.coldCodexParent() }
run("honestHookRetention") { honestDone.hookRetention() }
run("honestHelperHookCount") { honestDone.helperHookCount() }
run("honestToast") { try honestDone.toast() }

let doneReview = DoneReviewChecks()
run("stopSurvivesProcessExit") { try doneReview.stopSurvivesExit() }
run("lastHelperRestoresCompletedParent") { doneReview.lastHelperRestoresParent() }
run("parentRetainedAfterFinalHelper") { try doneReview.parentRetainedAfterHelper() }
run("delayedStopDoesNotFinishNextTurn") { try doneReview.delayedStopDoesNotFinishNextTurn() }
for variant in ["summary", "large", "duplicate", "invalid", "partial", "no-newline"] {
    run("stopTail-" + variant) { try doneReview.stopTail(variant) }
}
run("uncorrelatedStopUsesReceiptTime") { doneReview.uncorrelatedStopUsesReceiptTime() }
run("vendorIconPreferences") { try VendorIconChecks().preferences() }
run("vendorIconResolution") { VendorIconChecks().resolution() }
run("vendorIconThemeChoice") { try VendorIconChecks().themeChoice() }

print(failures == 0 ? "OK \(ran) checks" : "\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
