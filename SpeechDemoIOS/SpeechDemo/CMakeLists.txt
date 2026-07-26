cmake_minimum_required(VERSION 3.1)

project(SpeechDemo)

set(DEVELOPMENT_PROJECT_NAME ${CMAKE_PROJECT_NAME})
set(APP_NAME ${CMAKE_PROJECT_NAME})
set(APP_BUNDLE_IDENTIFIER "com.bytedance.ailab.speech.sdk")
set(DEPLOYMENT_TARGET 10.0)
set(APP_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")

set(CMAKE_OSX_SYSROOT "iphoneos")
set(CMAKE_XCODE_EFFECTIVE_PLATFORMS "-iphoneos;-iphonesimulator")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++14")
set(CMAKE_SUPPRESS_REGENERATION true)

set(CMAKE_IPHONEOS_SYSROOT "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk")
set(CMAKE_IPHONESIMULATOR_SYSROOT "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk")
set(XCODE_STARTUP_TARGET "SpeechDemo")
macro(ADD_FRAMEWORK fwname appname)
    find_library(FRAMEWORK_${fwname}
        NAMES ${fwname}
        PATHS ${CMAKE_IPHONESIMULATOR_SYSROOT}/System/Library ${CMAKE_IPHONEOS_SYSROOT}/System/Library
        PATH_SUFFIXES Frameworks
        NO_DEFAULT_PATH)
    if( ${FRAMEWORK_${fwname}} STREQUAL FRAMEWORK_${fwname}-NOTFOUND)
        MESSAGE(ERROR ": Framework ${fwname} not found")
    else()
        TARGET_LINK_LIBRARIES(${appname} ${FRAMEWORK_${fwname}})
        MESSAGE(STATUS "Framework ${fwname} found at ${FRAMEWORK_${fwname}}")
    endif()
endmacro(ADD_FRAMEWORK)

macro(SET_XCODE_PROPERTY TARGET XCODE_PROPERTY XCODE_VALUE XCODE_RELVERSION)
  set(XCODE_RELVERSION_I "${XCODE_RELVERSION}")
  if(XCODE_RELVERSION_I STREQUAL "All")
    set_property(TARGET ${TARGET} PROPERTY XCODE_ATTRIBUTE_${XCODE_PROPERTY} "${XCODE_VALUE}")
  else()
    set_property(TARGET ${TARGET} PROPERTY XCODE_ATTRIBUTE_${XCODE_PROPERTY}[variant=${XCODE_RELVERSION_I}] "${XCODE_VALUE}")
  endif()
endmacro(SET_XCODE_PROPERTY)

file(GLOB_RECURSE APP_HEADER_FILES "${APP_SOURCE_DIR}/*.h")
file(GLOB_RECURSE APP_SOURCE_FILES "${APP_SOURCE_DIR}/*.m")
set(INTERFACE_BUILDER
    ${APP_SOURCE_DIR}/SpeechSettingItem.xib
    ${APP_SOURCE_DIR}/Base.lproj/Main.storyboard
    ${APP_SOURCE_DIR}/Base.lproj/LaunchScreen.storyboard)

add_executable(
    ${APP_NAME}
    MACOSX_BUNDLE
    ${INTERFACE_BUILDER}
    ${APP_SOURCE_DIR}/Assets.xcassets
    ${APP_HEADER_FILES}
    ${APP_SOURCE_FILES})

set_target_properties(
    ${APP_NAME}
    PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${APP_SOURCE_DIR}/Info.plist"
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
    RESOURCE "${APP_SOURCE_DIR}/Assets.xcassets;${INTERFACE_BUILDER}")

SET_XCODE_PROPERTY(${APP_NAME} PRODUCT_BUNDLE_IDENTIFIER ${APP_BUNDLE_IDENTIFIER} All)
SET_XCODE_PROPERTY(${APP_NAME} ASSETCATALOG_COMPILER_APPICON_NAME "AppIcon" All)

ADD_FRAMEWORK(UIKit ${APP_NAME})
ADD_FRAMEWORK(Foundation ${APP_NAME})
ADD_FRAMEWORK(CoreFoundation ${APP_NAME})
ADD_FRAMEWORK(AVFoundation ${APP_NAME})
ADD_FRAMEWORK(AudioToolBox ${APP_NAME})
ADD_FRAMEWORK(Accelerate ${APP_NAME})
ADD_FRAMEWORK(AdSupport ${APP_NAME})
ADD_FRAMEWORK(CFNetwork ${APP_NAME})
ADD_FRAMEWORK(CoreGraphics ${APP_NAME})
ADD_FRAMEWORK(CoreImage ${APP_NAME})
ADD_FRAMEWORK(CoreTelephony ${APP_NAME})
ADD_FRAMEWORK(CoreText ${APP_NAME})
ADD_FRAMEWORK(MobileCoreServices ${APP_NAME})
ADD_FRAMEWORK(QuartzCore ${APP_NAME})
ADD_FRAMEWORK(Security ${APP_NAME})
ADD_FRAMEWORK(SystemConfiguration ${APP_NAME})
ADD_FRAMEWORK(JavaScriptCore ${APP_NAME})
    