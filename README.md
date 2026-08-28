# verified-cellular

The canonical VerifiedCellular module for our native apps: one Swift file, one
Kotlin file, no dependencies between them. Each forces its HTTP requests onto
the cellular interface even while WiFi is winning the default route, follows the
redirect chain a 1-Click verification link takes, and hands back the
verification record waiting at the end of it.

| Platform | File                          | Floor                                         |
| -------- | ----------------------------- | --------------------------------------------- |
| iOS      | `ios/VerifiedCellular.swift`  | iOS 16 (`URL.path(percentEncoded:)`)          |
| Android  | `android/VerifiedCellular.kt` | minSdk 26 (`requestNetwork` timeout overload) |

Both expose the same two calls:

- `getDeviceIp` — the IP this device shows over cellular, not the one the
  default route shows.
- `followRedirects` — GETs a URL over cellular and follows wherever it leads,
  answering with the `1ClickVerificationEntity` or the API's refusal.

## Using it

These files are meant to be copied, not depended on — nothing here is published
to a registry. Drop the file into the consuming app and change nothing but the
Kotlin `package` line, which every consumer sets to wherever the file landed.
Each file declares the types it answers with, so a copy is complete on its own.

Android also needs three permissions in the consuming app's manifest —
`INTERNET`, plus `ACCESS_NETWORK_STATE` to read what networks exist and
`CHANGE_NETWORK_STATE` to ask for the cellular one — and `kotlinx-coroutines`
on the classpath.

## React Native and Flutter

Neither framework can call the snippets directly, so each gets a thin wrapper —
copied into the consuming app the same way the snippets are:

- `react-native/` — a local Expo module: the two snippets under an Expo bridge,
  with `src/index.ts` as the app's one import. The whole directory drops into
  an app's `modules/` folder.
- `flutter/` — a MethodChannel plugin: the two snippets under a channel bridge,
  with `lib/verified_cellular.dart` as the app's one import.

The snippets inside both are these same files — byte-identical apart from the
Expo module's Kotlin `package` line, which its Gradle namespace fixes. Each
directory's README says where the files land in a consuming app and how the
bridge registers.

## Where the copies live

`verified-demo` carries copies of all of this, identical apart from the Kotlin
`package` lines:

- `android/app/src/main/java/network/verified/demo/cellular/VerifiedCellular.kt`
- `ios/verified-demo/Cellular/VerifiedCellular.swift`
- `flutter/{android,ios}/…/VerifiedCellular{,Plugin}.{kt,swift}` — this repo's
  `flutter/` wrapper
- `react-native/modules/verified-cellular/` — this repo's `react-native/`
  module

Change this repo first, then re-copy outward.

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE.md)
file for details.
