package com.3rddigitalexceptiontracking

import com.facebook.react.bridge.ReactApplicationContext

class 3rddigitalExceptionTrackingModule(reactContext: ReactApplicationContext) :
  Native3rddigitalExceptionTrackingSpec(reactContext) {

  override fun multiply(a: Double, b: Double): Double {
    return a * b
  }

  companion object {
    const val NAME = Native3rddigitalExceptionTrackingSpec.NAME
  }
}
