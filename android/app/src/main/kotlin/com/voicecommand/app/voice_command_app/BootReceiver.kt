package com.voicecommand.app.voice_command_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        Log.d("VoiceOS", "BootReceiver received action: $action")
        if (Intent.ACTION_BOOT_COMPLETED == action || Intent.ACTION_MY_PACKAGE_REPLACED == action) {
            try {
                val serviceIntent = Intent(context, BackgroundVoiceService::class.java).apply {
                    this.action = "START_LISTENING"
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(serviceIntent)
                } else {
                    context.startService(serviceIntent)
                }
                Log.d("VoiceOS", "BootReceiver: Successfully started BackgroundVoiceService")
            } catch (e: Exception) {
                Log.e("VoiceOS", "BootReceiver: Failed to start BackgroundVoiceService: ${e.message}")
            }
        }
    }
}
