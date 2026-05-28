import axios from 'axios';
import { Platform } from 'react-native';
import DeviceInfo from 'react-native-device-info';
import ThirdDigitalExceptionTracking from './NativeReactNativeExceptionHandler';

const noop = () => {};

export type ExtraData = Record<string, unknown>;
export type ExceptionContext = ExtraData & {
  screenName?: string;
};

export type JSExceptionHandler = (error: Error, isFatal?: boolean) => void;

export type NativeExceptionHandler = (
  exceptionString: string,
  payload?: ExtraData,
  uploadedByNative?: boolean
) => boolean | void | Promise<boolean | void>;

export type ExceptionSource = 'react' | 'native';

export type ExceptionPayloadInput = {
  source: ExceptionSource;
  title: string;
  message: string;
  stackTrace?: string;
  metadata?: ExtraData;
  extraData?: ExtraData;
};

export type ExceptionPayload = {
  source: ExceptionSource;
  title: string;
  message: string;
  stackTrace: string;
  platform: typeof Platform.OS;
  timestamp: string;
  projectKey: string;
  appVersion: string;
  buildNumber: string;
  bundleId: string;
  deviceId: string;
  osInfo: {
    osName: typeof Platform.OS;
    osVersion: string;
    apiLevel?: string | number;
  };
  deviceInfo: {
    brand: string;
    manufacturer?: string;
    model: string;
    deviceId: string;
    systemName: string;
    systemVersion: string;
    isTablet: boolean;
    deviceType: string;
    hasNotch: boolean;
  };
  metadata: ExtraData;
  extraData: ExtraData;
};

export type SetupExceptionTrackingOptions = {
  url: string;
  apiKey: string;
  projectKey: string;
  headers?: Record<string, string>;
  extraData?: ExceptionContext;
  nativeFallbackEnabled?: boolean;
  executeOriginalHandler?: boolean;
  forceToQuit?: boolean;
  allowedInDevMode?: boolean;
  installJSHandler?: boolean;
  installNativeHandler?: boolean;
  onBeforeSend?: (
    payload: ExceptionPayload
  ) => ExceptionPayload | null | Promise<ExceptionPayload | null>;
  onJSException?: (error: Error, isFatal?: boolean) => void;
  onNativeException?: (
    exceptionString: string,
    payload?: ExtraData,
    uploadedByNative?: boolean
  ) => void;
};

export type NativeExceptionHandlerOptions = {
  url: string;
  apiKey: string;
  projectKey: string;
  headers?: Record<string, string>;
  basePayload?: ExtraData;
  nativeFallbackEnabled?: boolean;
  executeOriginalHandler?: boolean;
  forceToQuit?: boolean;
};

type ErrorUtilsLike = {
  getGlobalHandler: () => JSExceptionHandler;
  setGlobalHandler: (handler: JSExceptionHandler) => void;
  reportError: (...args: unknown[]) => void;
};

let currentConfig: SetupExceptionTrackingOptions | undefined;
let currentContext: ExceptionContext = {};

const getIngestUrl = (url: string, projectKey: string) => {
  const baseUrl = url.replace(/\/+$/, '');
  return `${baseUrl}/exceptions/ingest/${encodeURIComponent(projectKey)}`;
};

const getErrorUtils = () => {
  return (
    globalThis as typeof globalThis & {
      ErrorUtils: ErrorUtilsLike;
    }
  ).ErrorUtils;
};

const getHeaders = () => {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    ...currentConfig?.headers,
  };

  headers['Api-Key'] = currentConfig?.apiKey ?? '';

  return headers;
};

const assertRequiredConfig = (options: SetupExceptionTrackingOptions) => {
  const missingFields = (['url', 'apiKey', 'projectKey'] as const).filter(
    (field) => !options[field]?.trim()
  );

  if (missingFields.length > 0) {
    throw new Error(
      `Exception tracking setup is missing required field(s): ${missingFields.join(
        ', '
      )}`
    );
  }
};

const releaseNativeExceptionHold = (handled = true) => {
  ThirdDigitalExceptionTracking?.releaseExceptionHold?.(handled);
};

const normalizeNativePayload = (nativePayload?: ExtraData | string) => {
  if (typeof nativePayload !== 'string') {
    return nativePayload;
  }

  try {
    return JSON.parse(nativePayload) as ExtraData;
  } catch {
    return { stackTrace: nativePayload };
  }
};

const getDeviceInfo = () => {
  return {
    appVersion: DeviceInfo.getVersion(),
    buildNumber: DeviceInfo.getBuildNumber(),
    bundleId: DeviceInfo.getBundleId(),
    deviceId: DeviceInfo.getDeviceId(),
    osInfo: {
      osName: Platform.OS,
      osVersion: DeviceInfo.getSystemVersion(),
      apiLevel: Platform.OS === 'android' ? Platform.Version : undefined,
    },
    deviceInfo: {
      brand: DeviceInfo.getBrand(),
      manufacturer: DeviceInfo.getManufacturerSync?.(),
      model: DeviceInfo.getModel(),
      deviceId: DeviceInfo.getDeviceId(),
      systemName: DeviceInfo.getSystemName(),
      systemVersion: DeviceInfo.getSystemVersion(),
      isTablet: DeviceInfo.isTablet(),
      deviceType: DeviceInfo.getDeviceType(),
      hasNotch: DeviceInfo.hasNotch(),
    },
  };
};

const createNativeExceptionCallback = (
  customErrorHandler: NativeExceptionHandler
) => {
  return (
    exceptionString: string,
    nativePayload?: ExtraData | string,
    uploadedByNative?: boolean
  ) => {
    try {
      const payload = normalizeNativePayload(nativePayload);
      Promise.resolve(
        customErrorHandler(exceptionString, payload, uploadedByNative)
      )
        .then((result) => {
          releaseNativeExceptionHold(uploadedByNative || result !== false);
        })
        .catch((error) => {
          console.error('Native exception handler failed:', error);
          releaseNativeExceptionHold(Boolean(uploadedByNative));
        });
    } catch (error) {
      console.error('Native exception handler failed:', error);
      releaseNativeExceptionHold(Boolean(uploadedByNative));
    }
  };
};

export const buildExceptionPayload = ({
  source,
  title,
  message,
  stackTrace = '',
  metadata = {},
  extraData = {},
}: ExceptionPayloadInput): ExceptionPayload => {
  const configExtraData = currentConfig?.extraData ?? {};
  const deviceContext = getDeviceInfo();

  return {
    source,
    title,
    message,
    stackTrace,
    platform: Platform.OS,
    timestamp: new Date().toISOString(),
    projectKey: currentConfig?.projectKey ?? '',
    ...deviceContext,
    metadata: {
      ...metadata,
      framework: 'react-native',
    },
    extraData: {
      ...configExtraData,
      ...currentContext,
      ...extraData,
    },
  };
};

export const setExceptionContext = (context: ExceptionContext) => {
  currentContext = {
    ...currentContext,
    ...context,
  };
};

export const clearExceptionContext = (keys?: Array<keyof ExceptionContext>) => {
  if (!keys) {
    currentContext = {};
    return;
  }

  keys.forEach((key) => {
    delete currentContext[key];
  });
};

export const setCurrentScreen = (screenName: string) => {
  setExceptionContext({ screenName });
};

export const logException = async (
  payload: ExceptionPayload
): Promise<boolean> => {
  if (!currentConfig?.url) {
    console.warn(
      'Exception tracking is not configured. Call setupExceptionTracking first.'
    );
    return false;
  }

  const preparedPayload = currentConfig.onBeforeSend
    ? await currentConfig.onBeforeSend(payload)
    : payload;

  if (!preparedPayload) {
    return false;
  }

  try {
    const response = await axios.post(
      getIngestUrl(currentConfig.url, currentConfig.projectKey),
      preparedPayload,
      {
        headers: getHeaders(),
      }
    );

    return response.status >= 200 && response.status < 300;
  } catch (error) {
    console.error('Failed to log exception:', error);
    return false;
  }
};

export const captureException = async (error: Error, extraData?: ExtraData) => {
  return logException(
    buildExceptionPayload({
      source: 'react',
      title: error.name || 'Unhandled JS Exception',
      message: error.message || 'No message provided',
      stackTrace: error.stack ?? '',
      extraData,
    })
  );
};

export const setJSExceptionHandler = (
  customHandler: JSExceptionHandler = noop,
  allowedInDevMode = false
) => {
  if (
    typeof allowedInDevMode !== 'boolean' ||
    typeof customHandler !== 'function'
  ) {
    console.log(
      'setJSExceptionHandler is called with wrong argument types.. first argument should be callback function and second argument is optional should be a boolean'
    );
    console.log(
      'Not setting the JS handler .. please fix setJSExceptionHandler call'
    );
    return;
  }
  const allowed = allowedInDevMode ? true : !__DEV__;
  if (allowed) {
    const errorUtils = getErrorUtils();
    errorUtils.setGlobalHandler(customHandler);
  } else {
    console.log(
      'Skipping setJSExceptionHandler: Reason: In DEV mode and allowedInDevMode = false'
    );
  }
};

export const getJSExceptionHandler = () => getErrorUtils().getGlobalHandler();

export const configureNativeExceptionHandler = (
  options: NativeExceptionHandlerOptions
) => {
  if (!ThirdDigitalExceptionTracking?.configureNativeExceptionHandler) {
    console.log(
      'ThirdDigitalExceptionTracking native module is not linked. Rebuild the native app and try again.'
    );
    return;
  }

  ThirdDigitalExceptionTracking.configureNativeExceptionHandler(options);
};

export const setNativeExceptionHandler = (
  customErrorHandler: NativeExceptionHandler = noop,
  forceApplicationToQuit = false,
  executeDefaultHandler = true
) => {
  if (
    typeof customErrorHandler !== 'function' ||
    typeof forceApplicationToQuit !== 'boolean'
  ) {
    console.log(
      'setNativeExceptionHandler is called with wrong argument types.. first argument should be callback function and second argument is optional should be a boolean'
    );
    console.log(
      'Not setting the native handler .. please fix setNativeExceptionHandler call'
    );
    return;
  }

  if (!ThirdDigitalExceptionTracking?.setHandlerforNativeException) {
    console.log(
      'ThirdDigitalExceptionTracking native module is not linked. Rebuild the native app and try again.'
    );
    return;
  }

  ThirdDigitalExceptionTracking.setHandlerforNativeException(
    executeDefaultHandler,
    forceApplicationToQuit,
    createNativeExceptionCallback(customErrorHandler)
  );
};

export const setNativeExceptionCallback = (
  customErrorHandler: NativeExceptionHandler = noop
) => {
  if (typeof customErrorHandler !== 'function') {
    console.log(
      'setNativeExceptionCallback is called with wrong argument type. First argument should be callback function.'
    );
    return;
  }

  if (!ThirdDigitalExceptionTracking?.setNativeExceptionCallback) {
    console.log(
      'ThirdDigitalExceptionTracking native module is not linked. Rebuild the native app and try again.'
    );
    return;
  }

  ThirdDigitalExceptionTracking.setNativeExceptionCallback(
    createNativeExceptionCallback(customErrorHandler)
  );
};

const setNativeExceptionHandlerIOS = (
  customErrorHandler: NativeExceptionHandler,
  executeDefaultHandler = true
) => {
  if (!ThirdDigitalExceptionTracking?.setHandlerforNativeExceptionIOS) {
    console.log(
      'ThirdDigitalExceptionTracking iOS native module is not linked. Rebuild the native app and try again.'
    );
    return;
  }

  ThirdDigitalExceptionTracking.setHandlerforNativeExceptionIOS(
    executeDefaultHandler,
    createNativeExceptionCallback(customErrorHandler)
  );
};

export const installNativeExceptionHandler = (
  forceApplicationToQuit = false,
  executeDefaultHandler = true
) => {
  if (!ThirdDigitalExceptionTracking?.installNativeExceptionHandler) {
    console.log(
      'ThirdDigitalExceptionTracking native module is not linked. Rebuild the native app and try again.'
    );
    return;
  }

  ThirdDigitalExceptionTracking.installNativeExceptionHandler(
    executeDefaultHandler,
    forceApplicationToQuit
  );
};

export const setupExceptionTracking = (
  options: SetupExceptionTrackingOptions
) => {
  assertRequiredConfig(options);

  currentConfig = {
    nativeFallbackEnabled: true,
    executeOriginalHandler: true,
    forceToQuit: false,
    installJSHandler: true,
    installNativeHandler: true,
    ...options,
  };

  const baseNativePayload = buildExceptionPayload({
    source: 'native',
    title: 'Native Exception',
    message: 'Native exception handler configured',
    stackTrace: '',
    metadata: {
      projectKey: currentConfig.projectKey,
    },
  });

  configureNativeExceptionHandler({
    url: getIngestUrl(currentConfig.url, currentConfig.projectKey),
    apiKey: currentConfig.apiKey,
    projectKey: currentConfig.projectKey,
    headers: currentConfig.headers,
    nativeFallbackEnabled: currentConfig.nativeFallbackEnabled,
    executeOriginalHandler: currentConfig.executeOriginalHandler,
    forceToQuit: currentConfig.forceToQuit,
    basePayload: baseNativePayload,
  });

  if (currentConfig.installJSHandler) {
    setJSExceptionHandler((error, isFatal) => {
      logException(
        buildExceptionPayload({
          source: 'react',
          title: error?.name || 'Unhandled JS Exception',
          message: error?.message || 'No message provided',
          stackTrace: error?.stack ?? '',
          metadata: { isFatal },
        })
      ).catch((logError) => {
        console.error('Failed to log JS exception:', logError);
      });
      currentConfig?.onJSException?.(error, isFatal);
    }, currentConfig.allowedInDevMode);
  }

  if (currentConfig.installNativeHandler) {
    if (Platform.OS === 'ios') {
      setNativeExceptionHandlerIOS(
        async (exceptionString, nativePayload, uploadedByNative) => {
          currentConfig?.onNativeException?.(
            exceptionString,
            nativePayload,
            uploadedByNative
          );

          if (uploadedByNative) {
            return true;
          }

          const payload =
            (nativePayload as ExceptionPayload | undefined) ??
            buildExceptionPayload({
              source: 'native',
              title: 'Unhandled Native Exception',
              message: exceptionString || 'No message provided',
              stackTrace: exceptionString,
              metadata: { uploadedDuringCrash: true },
            });

          return logException(payload as ExceptionPayload);
        },
        currentConfig.executeOriginalHandler
      );
    } else {
      setNativeExceptionHandler(
        async (exceptionString, nativePayload, uploadedByNative) => {
          currentConfig?.onNativeException?.(
            exceptionString,
            nativePayload,
            uploadedByNative
          );

          if (uploadedByNative) {
            return true;
          }

          const payload =
            (nativePayload as ExceptionPayload | undefined) ??
            buildExceptionPayload({
              source: 'native',
              title: 'Unhandled Native Exception',
              message: exceptionString || 'No message provided',
              stackTrace: exceptionString,
              metadata: { uploadedDuringCrash: true },
            });

          return logException(payload as ExceptionPayload);
        },
        currentConfig.forceToQuit,
        currentConfig.executeOriginalHandler
      );
    }
  }
};

export default {
  setupExceptionTracking,
  captureException,
  buildExceptionPayload,
  logException,
  setExceptionContext,
  clearExceptionContext,
  setCurrentScreen,
  setJSExceptionHandler,
  getJSExceptionHandler,
  configureNativeExceptionHandler,
  installNativeExceptionHandler,
  setNativeExceptionCallback,
  setNativeExceptionHandler,
};
