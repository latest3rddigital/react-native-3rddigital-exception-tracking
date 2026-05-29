# react-native-3rddigital-exception-tracking

A lightweight exception tracking SDK for React Native apps. It captures unhandled JavaScript errors, native Android crashes, native iOS exceptions, and manually reported errors, then sends them to the 3rdDigital exception ingest API with app, OS, device, screen, user, and custom context.

## Installation

```sh
npm install react-native-3rddigital-exception-tracking
```

This package uses `axios` for uploads and `react-native-device-info` to add app, OS, and device context to each payload.

## Basic Usage

```ts
import {
  captureException,
  setCurrentScreen,
  setExceptionContext,
  setupExceptionTracking,
} from 'react-native-3rddigital-exception-tracking';

setupExceptionTracking({
  url: 'https://your-api.example.com',
  apiKey: 'YOUR_API_KEY',
  projectKey: 'YOUR_PROJECT_ENVIRONMENT_KEY',
  extraData: {
    environment: 'production',
    releaseChannel: 'app-store',
    userInfo: {
      id: currentUser.id,
      email: currentUser.email,
    },
  },
});

setCurrentScreen('Checkout');

setExceptionContext({
  sessionId: currentSession.id,
  cartId: currentCart.id,
});

captureException(new Error('Payment failed'), {
  action: 'Pay button pressed',
  requestId: 'req_123',
  exceptionData: {
    handled: true,
  },
});
```

`url`, `apiKey`, and `projectKey` are required. The SDK sends exceptions to `${url}/exceptions/ingest/${projectKey}` and safely handles trailing slashes in `url`.

## Setup Options

| Field | Required | Description |
| --- | --- | --- |
| `url` | Yes | Base API URL. The SDK appends `/exceptions/ingest/${projectKey}`. |
| `apiKey` | Yes | API key sent in the `Api-Key` header. |
| `projectKey` | Yes | Project environment key used in the ingest URL. |
| `headers` | No | Extra request headers. `Content-Type` and `Api-Key` are set automatically. |
| `extraData` | No | App-wide custom context added to every payload. |
| `allowedInDevMode` | No | Allows JS handler installation in development. Defaults to `false`. |
| `installJSHandler` | No | Installs the global JS exception handler. Defaults to `true`. |
| `installNativeHandler` | No | Installs native Android/iOS handlers. Defaults to `true`. |
| `nativeFallbackEnabled` | No | Allows native code to upload during a native crash. Defaults to `true`. |
| `executeOriginalHandler` | No | Calls the previously installed native crash handler after this SDK. Defaults to `true`. |
| `forceToQuit` | No | Forces app termination after native crash handling. Defaults to `false`. |
| `onBeforeSend` | No | Last chance to edit or drop JS-uploaded payloads. Return `null` to skip. |
| `onJSException` | No | Callback after the SDK receives an unhandled JS exception. |
| `onNativeException` | No | Callback after the SDK receives a native exception callback. |

## Custom Data

There are three places to pass custom data. Later values override earlier values when the same custom key is used.

| API | Scope | Example fields |
| --- | --- | --- |
| `setupExceptionTracking({ extraData })` | Sent with every exception. | `environment`, `releaseChannel`, `userInfo` |
| `setExceptionContext(context)` | Sent with every later exception until cleared. | `sessionId`, `accountId`, `cartId` |
| `captureException(error, extraData)` | Sent only with that manual exception. | `action`, `requestId`, `exceptionData` |

Use `setCurrentScreen(screenName)` as a shortcut for `setExceptionContext({ screenName })`.

```ts
setExceptionContext({
  screenName: 'Profile',
  userInfo: {
    id: 'user_123',
    email: 'user@example.com',
  },
  organizationId: 'org_456',
});

clearExceptionContext(['organizationId']);
clearExceptionContext(); // clears all current context
```

## Payload Fields

The SDK always sends `source: 'react-native'` because the backend uses `source` for grouping and source distribution. JS vs native is sent separately as `exceptionSource` and `stackSource`.

SDK generated top-level fields:

| Field | Value |
| --- | --- |
| `source` | Always `react-native`. Do not change this in `onBeforeSend`. |
| `exceptionSource` | `js` for JS/manual exceptions, `native` for native crashes. |
| `stackSource` | Source of the stack trace, usually same as `exceptionSource`. |
| `title`, `message`, `stackTrace` | Error name, message, and stack trace. |
| `timestamp`, `reportedAt` | ISO timestamp when the SDK built the payload. |
| `appVersion`, `buildNumber`, `readableVersion`, `bundleId` | App identity from `react-native-device-info`. |
| `deviceId`, `installationId` | Stable unique device/install identifier used by backend device counting. |
| `platform`, `osInfo`, `deviceInfo` | Platform, OS, and hardware details. |
| `memoryInfo`, `storageInfo`, `batteryInfo` | Available memory, disk, and power details. |
| `screenName` | Copied from custom context when provided. |
| `userInfo` | Copied from custom context when provided. |
| `metadata` | SDK metadata plus exception metadata. |
| `exceptionData` | Structured exception details. |
| `otherDetails` | Merged custom data from setup, context, and manual capture. |
| `extraData` | Same merged custom data as `otherDetails`, kept for SDK consumers. |

Recommended user fields:

| Field | Where to pass | Backend behavior |
| --- | --- | --- |
| `screenName` | `setCurrentScreen` or `setExceptionContext` | Promoted to top-level `screenName`. |
| `userInfo` | `extraData`, `setExceptionContext`, or manual capture | Promoted to top-level `userInfo`. |
| `exceptionData` | Manual capture or context | Merged into top-level `exceptionData`. |
| Any other custom key | Any custom data API | Stored in `otherDetails` and `extraData`. |

Avoid overriding these top-level fields in `onBeforeSend` unless you are intentionally changing backend grouping/counting behavior: `source`, `deviceId`, `title`, `message`, `stackTrace`, `appVersion`, `buildNumber`, `reportedAt`.

Private routing/auth values such as `url`, `apiKey`, `headers`, `ingestUrl`, `project`, and `projectKey` are used for upload configuration only and are removed from the JSON payload body.

## Manual Capture

```ts
try {
  await submitOrder();
} catch (error) {
  await captureException(error as Error, {
    screenName: 'Checkout',
    action: 'submitOrder',
    orderId,
    requestId,
    exceptionData: {
      handled: true,
      paymentProvider: 'stripe',
    },
  });
}
```

## Advanced

Use `onBeforeSend` to remove sensitive values or attach final app state before upload.

```ts
setupExceptionTracking({
  url,
  apiKey,
  projectKey,
  onBeforeSend: (payload) => {
    return {
      ...payload,
      otherDetails: {
        ...payload.otherDetails,
        networkStatus: getNetworkStatus(),
      },
    };
  },
});
```

## Release Checklist

```sh
yarn typecheck
yarn lint
yarn prepare
npm pack --dry-run
npm publish --access public
```

## Contributing

- [Development workflow](CONTRIBUTING.md#development-workflow)
- [Sending a pull request](CONTRIBUTING.md#sending-a-pull-request)
- [Code of conduct](CODE_OF_CONDUCT.md)

## License

MIT
