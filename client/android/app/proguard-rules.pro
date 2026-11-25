# WebRTC (chat de voz): R8 no debe quitar ni renombrar las clases a las que llama el código nativo.
-keep class org.webrtc.** { *; }
-keep class com.cloudwebrtc.webrtc.** { *; }
-dontwarn org.webrtc.**
