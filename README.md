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

These files are meant to be copied, not depended on — there is no package,
podspec, or Gradle module here yet. Drop the file into the consuming app and
change nothing but the Kotlin `package` line, which every consumer sets to
wherever the file landed. Each file declares the types it answers with, so a
copy is complete on its own.

Android also needs three permissions in the consuming app's manifest —
`INTERNET`, plus `ACCESS_NETWORK_STATE` to read what networks exist and
`CHANGE_NETWORK_STATE` to ask for the cellular one — and `kotlinx-coroutines`
on the classpath.

## Where the copies live

`verified-demo` carries four copies, all identical to these apart from the
Kotlin `package` line:

- `android/app/src/main/java/network/verified/demo/cellular/VerifiedCellular.kt`
- `ios/verified-demo/Cellular/VerifiedCellular.swift`
- `flutter/{android,ios}/…/VerifiedCellular.{kt,swift}`, behind a plugin wrapper
- `react-native/modules/verified-cellular/{android,ios}/`, behind an Expo module

Change this repo first, then re-copy outward.

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE.md)
file for details.
