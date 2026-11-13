# JNA and the UniFFI bindings are reached reflectively from native code.
-keep class com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
-keep class uniffi.koharu_core.** { *; }
-dontwarn java.awt.**
# AdMob pulls in WorkManager; Room finds each database's generated `_Impl`
# class by name, which R8 would otherwise rename or remove.
-keep class * extends androidx.room.RoomDatabase { <init>(); }
