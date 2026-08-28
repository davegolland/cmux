# Xcode Security Settings

Security build-setting decisions for cmux. This audit covers the macOS
application project and its C, C++, Objective-C, and Swift sources.

## Enabled settings

- `GCC_WARN_ABOUT_RETURN_TYPE` to `YES_ERROR`: already enabled in Debug and Release.
- `GCC_WARN_UNINITIALIZED_AUTOS` to `YES_AGGRESSIVE`: already enabled in Debug and Release.
- `GCC_WARN_64_TO_32_BIT_CONVERSION`: already enabled in Debug and Release.
- `CLANG_WARN_IMPLICIT_FALLTHROUGH`: enabled at project level.
- `GCC_TREAT_IMPLICIT_FUNCTION_DECLARATIONS_AS_ERRORS`: enabled at project level.
- `CLANG_ANALYZER_SECURITY_FLOATLOOPCOUNTER`: enabled at project level.
- `CLANG_ANALYZER_SECURITY_INSECUREAPI_RAND`: enabled at project level.
- `CLANG_ANALYZER_SECURITY_INSECUREAPI_STRCPY`: enabled at project level.

## Disabled settings

No catalog security warning is explicitly disabled. `ENABLE_HARDENED_RUNTIME` is
currently `NO` for the Debug and Release app configurations, but it is outside
this audit's Enhanced Security capability and remains a separate signing and
entitlement decision.

## Deferred

- `ENABLE_ENHANCED_SECURITY`: deferred. cmux embeds Ghostty and JavaScriptCore,
  uses JIT and unsigned-executable-memory entitlements, and links Swift packages
  and other binary dependencies. Enabling the capability requires an arm64e
  dependency audit and a signed-runtime compatibility test.
- `com.apple.security.hardened-process.checked-allocations`: deferred with
  Enhanced Security. Hardware and soft-mode support must be confirmed first.
- `ENABLE_C_BOUNDS_SAFETY`: deferred. Existing C code needs annotation-based
  adoption and a separate migration plan.
- `ENABLE_CPLUSPLUS_BOUNDS_SAFE_BUFFERS`: deferred. Existing C++ code needs a
  separate buffer-model migration plan.
- Additional noisy diagnostics such as `CLANG_WARN_SUSPICIOUS_IMPLICIT_CONVERSION`,
  `GCC_WARN_SIGN_COMPARE`, and experimental buffer-overflow checkers: deferred
  until a warning-volume baseline is available.
