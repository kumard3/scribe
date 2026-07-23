# Add project specific ProGuard rules here.
# By default, the flags in this file are appended to flags specified
# in /usr/local/Cellar/android-sdk/24.3.3/tools/proguard/proguard-android.txt
# You can edit the include path and order by changing the proguardFiles
# directive in build.gradle.
#
# For more details, see
#   http://developer.android.com/guide/developing/tools/proguard.html

# react-native-reanimated
-keep class com.swmansion.reanimated.** { *; }
-keep class com.facebook.react.turbomodule.** { *; }

# Native STT/translation libs reached over JNI/reflection, keep so R8 can't
# strip classes the .so layers call into. Required before enabling minify.
-keep class com.k2fsa.sherpa.onnx.** { *; }
-keep class com.rnwhisper.** { *; }
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.** { *; }
-keepclasseswithmembernames class * { native <methods>; }

# Our own native modules registered with React (Moonshine, Flow Bubble).
-keep class ai.localvoice.app.** { *; }

# Add any project specific keep options here:
