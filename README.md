# react-native-3rddigital-exception-tracking

A robust, lightweight exception tracking SDK for React Native applications. It seamlessly captures unhandled JavaScript/TypeScript errors, native Android (Java/Kotlin) crashes, and native iOS (Objective-C/Swift) exceptions, automatically reporting them to your centralized 3rdDigital monitoring dashboard via an internal API.

## Installation


```sh
npm install react-native-3rddigital-exception-tracking
```

This package uses `axios` for uploads and `react-native-device-info` to add app, OS, and device context to each payload.


## Usage


```js
import {
  captureException,
  setCurrentScreen,
  setExceptionContext,
  setupExceptionTracking,
} from 'react-native-3rddigital-exception-tracking';

const API_BASE_URL = getValueFromYourAppConfig('API_BASE_URL');
const API_KEY = getValueFromYourAppConfig('API_KEY');
const PROJECT_KEY = getValueFromYourAppConfig('PROJECT_KEY');

setupExceptionTracking({
  url: API_BASE_URL,
  apiKey: API_KEY,
  projectKey: PROJECT_KEY,
  allowedInDevMode: true,
  extraData: {
    environment: 'production',
    userId: currentUser.id,
  },
});

setCurrentScreen('Checkout');
setExceptionContext({
  userId: currentUser.id,
  plan: currentUser.plan,
});

captureException(new Error('Manual error'), {
  action: 'Pay button pressed',
});
```

`url`, `apiKey`, and `projectKey` are required. All other setup options are optional.
The SDK sends exceptions to `${url}/exceptions/ingest/${projectKey}` and handles a trailing slash in `url`.
Use `setCurrentScreen` or `setExceptionContext` whenever navigation or user/session data changes. Manual `captureException` extra data overrides setup and context values for that one payload.


## Contributing

- [Development workflow](CONTRIBUTING.md#development-workflow)
- [Sending a pull request](CONTRIBUTING.md#sending-a-pull-request)
- [Code of conduct](CODE_OF_CONDUCT.md)

## License

MIT

---

Made with [create-react-native-library](https://github.com/callstack/react-native-builder-bob)
