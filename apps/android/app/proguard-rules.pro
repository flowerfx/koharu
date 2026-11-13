# JNA and the UniFFI bindings are reached reflectively from native code.
-keep class com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
-keep class uniffi.koharu_core.** { *; }
-dontwarn java.awt.**
