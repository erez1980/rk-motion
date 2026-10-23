# Core Image / Xcode checker CI crash investigation

CI run [40020515542](https://github.com/erez1980/rk-motion/actions/runs/40020515542) tested `a7a95c0` with Xcode 26.3 on the iPhone 16 Pro simulator, **iOS 18.5**. Its xcresult records 173 tests: 172 passed, one process crash in `EffectsExportTests/testEveryEffectExports()`. All 18 automatic director/media tests and all five UI tests passed. This is not a clean full-suite pass.

The operating-system crash report shows `EXC_BAD_ACCESS` / SIGSEGV on the `CI::complete_intermediate` queue. The crashing stack begins:

```text
libRPAC.dylib  <deduplicated_symbol>
libRPAC.dylib  findPrimitiveInfoNoAssert
libRPAC.dylib  interposed_dispatch_group_wait
CoreImage     CI::Node::remove_parentROI(...)
libdispatch   _dispatch_call_block_and_release
```

The immediate crash occurs inside Xcode's injected Thread Performance Checker. This matches the Core Image / libRPAC issue discussed by Apple DTS in [FB17767223](https://developer.apple.com/forums/thread/785954). Apple's [performance diagnostics documentation](https://developer.apple.com/documentation/xcode/diagnosing-performance-issues-early) explains that the checker inserts runtime checks and can be disabled separately from executing tests. This evidence supports an instrumentation fault; it does not prove that arbitrary application memory errors are impossible.

The generated scheme now sets `enablePerformanceAntipatternChecker="NO"` **only on TestAction**. Every functional test remains enabled. Main Thread Checker remains enabled, and the Run/Profile/Archive actions are unchanged. The generated local `.xctestrun` was inspected: `libMainThreadChecker.dylib` remains injected and `libRPAC.dylib` is absent. Re-enable the performance checker for targeted performance investigations or after validating a runtime/toolchain that fixes this issue.

The existing main baseline `b60e818` also has a failed [CI run](https://github.com/erez1980/rk-motion/actions/runs/39998029677) with an unexpected process exit during a joined-video media test. Its crash artifact was not analyzed here, so it is not claimed to have the same cause.

The failed report additionally contains invalid-frame-dimension runtime warnings. UI tests passed, but a loading/layout audit on real devices is still follow-up work. A successful rerun must include the complete effects test and the complete unit/UI suites; do not skip the crashing test or treat a retry alone as remediation. The PR's latest check records the final CI outcome.
