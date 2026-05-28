package com.3rddigitalexceptiontracking

import com.facebook.react.BaseReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.module.model.ReactModuleInfoProvider
import java.util.HashMap

class 3rddigitalExceptionTrackingPackage : BaseReactPackage() {
  override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? {
    return if (name == 3rddigitalExceptionTrackingModule.NAME) {
      3rddigitalExceptionTrackingModule(reactContext)
    } else {
      null
    }
  }

  override fun getReactModuleInfoProvider() = ReactModuleInfoProvider {
    mapOf(
      3rddigitalExceptionTrackingModule.NAME to ReactModuleInfo(
        name = 3rddigitalExceptionTrackingModule.NAME,
        className = 3rddigitalExceptionTrackingModule.NAME,
        canOverrideExistingModule = false,
        needsEagerInit = false,
        isCxxModule = false,
        isTurboModule = true
      )
    )
  }
}
