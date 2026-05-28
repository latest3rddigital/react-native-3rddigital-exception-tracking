package com.thirddigitalexceptiontracking

import com.facebook.react.BaseReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.module.model.ReactModuleInfoProvider

class ThirdDigitalExceptionTrackingPackage : BaseReactPackage() {
  override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? {
    return if (name == ThirdDigitalExceptionTrackingModule.NAME) {
      ThirdDigitalExceptionTrackingModule(reactContext)
    } else {
      null
    }
  }

  override fun getReactModuleInfoProvider() = ReactModuleInfoProvider {
    mapOf(
      ThirdDigitalExceptionTrackingModule.NAME to ReactModuleInfo(
        name = ThirdDigitalExceptionTrackingModule.NAME,
        className = ThirdDigitalExceptionTrackingModule.NAME,
        canOverrideExistingModule = false,
        needsEagerInit = false,
        isCxxModule = false,
        isTurboModule = true
      )
    )
  }
}
