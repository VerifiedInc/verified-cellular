# VerifiedCellular — React Native

The canonical module wrapped as a local Expo module, in three layers:

| Layer           | Files                                                                             | Knows about                     |
| --------------- | --------------------------------------------------------------------------------- | ------------------------------- |
| Native snippets | `ios/VerifiedCellular.swift`, `android/src/.../VerifiedCellular.kt`                | Cellular, HTTP, decoding        |
| Expo bridges    | `ios/VerifiedCellularModule.swift`, `android/src/.../VerifiedCellularModule.kt`   | JavaScript, nothing of cellular |
| TypeScript      | `src/index.ts` (the app's one import), `src/VerifiedCellularModule.ts` (the wire) | The app                         |

The snippets are this repo's own files: the Swift one is byte-identical to
`../ios/VerifiedCellular.swift`, the Kotlin one differs from
`../android/VerifiedCellular.kt` in its `package` line and nothing else —
`expo.modules.verifiedcellular`, because that is the module's Gradle namespace.
`diff` is the test when either changes.

The bridges answer with records rather than throwing, because an Expo exception
crosses to JavaScript as a code and a sentence and nothing else — a
`CellularError` carrying a status code or a URL would arrive stripped.
`src/index.ts` turns those records back into returned values and thrown typed
errors (`VerifiedApiError`, `CellularError`), so keep the wrapper: it is part of
the module, not a convenience.

## Using it

Copy this whole directory into your app as `modules/verified-cellular/`. Expo
autolinking discovers local modules under `modules/` on its own — copying is the
whole installation:

```bash
cp -R react-native/ <your-app>/modules/verified-cellular/
cd <your-app> && npx expo prebuild
```

A path alias keeps imports clean (`tsconfig.json`):

```json
{
  "compilerOptions": {
    "paths": {
      "verified-cellular": ["./modules/verified-cellular/src/index.ts"]
    }
  }
}
```

Then:

```ts
import {
  followRedirects,
  getDeviceIp,
  watchCellularAvailable,
  CellularError,
  VerifiedApiError,
} from 'verified-cellular';

try {
  const verification = await followRedirects(url);
} catch (error) {
  if (error instanceof VerifiedApiError) {
    // The API answered with a refusal — error.errorCode carries the product code.
  } else if (error instanceof CellularError) {
    // No answer at all — error.code names which of the six ways.
  }
}
```

## Floors and permissions

- **iOS 16**, from the podspec: the snippet builds request targets with
  `URL.path(percentEncoded:)`.
- **minSdk 26**, from the module's `build.gradle`: where
  `ConnectivityManager.requestNetwork`'s timeout overload lands. Set the app's
  floor to match (the demo does it through `expo-build-properties`).
- The three Android permissions — `INTERNET`, `ACCESS_NETWORK_STATE`,
  `CHANGE_NETWORK_STATE` — are declared in the module's own
  `AndroidManifest.xml` and merge into the app's, so the app declares nothing.
- **No web target**: binding a socket to a cellular interface has no browser
  equivalent.

A working consumer lives in `verified-demo/react-native`.
