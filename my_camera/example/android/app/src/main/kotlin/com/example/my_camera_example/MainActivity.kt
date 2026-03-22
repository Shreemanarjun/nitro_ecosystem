package com.example.my_camera_example

import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    companion object {
        init {
            System.loadLibrary("my_camera")
        }
    }
}
