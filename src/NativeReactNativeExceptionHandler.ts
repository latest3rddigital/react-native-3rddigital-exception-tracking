import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

export type NativeExceptionHandlerOptions = {
  url: string;
  apiKey: string;
  projectKey: string;
  headers?: { [key: string]: string };
  basePayload?: { [key: string]: unknown };
  nativeFallbackEnabled?: boolean;
  executeOriginalHandler?: boolean;
  forceToQuit?: boolean;
};

export type NativeExceptionCallback = (
  exceptionString: string,
  nativePayload?: { [key: string]: unknown } | string,
  uploadedByNative?: boolean
) => void;

export interface Spec extends TurboModule {
  configureNativeExceptionHandler(options: NativeExceptionHandlerOptions): void;
  installNativeExceptionHandler(
    executeDefaultHandler: boolean,
    forceApplicationToQuit: boolean
  ): void;
  setNativeExceptionCallback(callback: NativeExceptionCallback): void;
  setHandlerforNativeExceptionIOS(
    executeDefaultHandler: boolean,
    callback: NativeExceptionCallback
  ): void;
  setHandlerforNativeException(
    executeDefaultHandler: boolean,
    forceApplicationToQuit: boolean,
    callback: NativeExceptionCallback
  ): void;
  releaseExceptionHold(handled: boolean): void;
}

export default TurboModuleRegistry.get<Spec>('ThirdDigitalExceptionTracking');
