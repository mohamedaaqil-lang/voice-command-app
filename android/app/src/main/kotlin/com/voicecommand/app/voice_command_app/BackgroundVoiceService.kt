package com.voicecommand.app.voice_command_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import androidx.core.app.NotificationCompat
import java.util.Locale

class BackgroundVoiceService : Service() {
    private val CHANNEL_ID = "voiceos_background_channel"
    private val NOTIFICATION_ID = 9999

    private var speechRecognizer: SpeechRecognizer? = null
    private var isListening = false
    private var consecutiveErrorCount = 0
    private val restartHandler = Handler(Looper.getMainLooper())
    private val restartRunnable = Runnable { startListening() }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notificationIntent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, notificationIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("VoiceOS Assistant Active")
            .setContentText("Listening for wake word...")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            e.printStackTrace()
            try {
                // Fallback to standard startForeground if microphone type is rejected (e.g. no permission yet)
                startForeground(NOTIFICATION_ID, notification)
            } catch (ex: Exception) {
                ex.printStackTrace()
            }
        }

        val action = intent?.action
        Log.d("VoiceOS", "Service onStartCommand action: $action")
        when (action) {
            "START_LISTENING" -> {
                isListening = true
                startListening()
            }
            "STOP_LISTENING" -> {
                stopListening()
            }
            else -> {
                isListening = true
                startListening()
            }
        }

        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? {
        return null
    }

    override fun onDestroy() {
        super.onDestroy()
        stopListening()
        speechRecognizer?.destroy()
        speechRecognizer = null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val serviceChannel = NotificationChannel(
                CHANNEL_ID,
                "VoiceOS Service Channel",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(serviceChannel)
        }
    }

    private fun startListening() {
        if (!isListening) return

        try {
            // Destroy the old recognizer to clear any busy/deadlock states
            speechRecognizer?.destroy()
            speechRecognizer = SpeechRecognizer.createSpeechRecognizer(this).apply {
                setRecognitionListener(recognitionListener)
            }

            val recognizerIntent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault().toString())
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
            }
            speechRecognizer?.startListening(recognizerIntent)
            Log.d("VoiceOS", "Native STT: Started listening successfully")
        } catch (e: Exception) {
            Log.e("VoiceOS", "Native STT Start Error: ${e.message}")
            consecutiveErrorCount++
            scheduleRestart()
        }
    }

    private fun stopListening() {
        Log.d("VoiceOS", "Native STT: Stopping listening")
        isListening = false
        restartHandler.removeCallbacks(restartRunnable)
        try {
            speechRecognizer?.stopListening()
            speechRecognizer?.cancel()
        } catch (e: Exception) {
            Log.e("VoiceOS", "Native STT Stop Error: ${e.message}")
        }
    }

    private fun scheduleRestart() {
        restartHandler.removeCallbacks(restartRunnable)
        val delay = (500 * (1 shl consecutiveErrorCount)).coerceAtMost(10000).toLong()
        Log.d("VoiceOS", "Native STT: Scheduling restart in ${delay}ms (errors: $consecutiveErrorCount)")
        restartHandler.postDelayed(restartRunnable, delay)
    }

    private fun containsWakeWord(text: String): Boolean {
        val cleanText = text.lowercase(Locale.ROOT).replace(Regex("[^a-z0-9\\s]"), " ")
        val words = cleanText.split(Regex("\\s+"))
        return words.contains("hey") || 
               words.contains("hay") || 
               words.contains("assistant") || 
               words.contains("google") || 
               words.contains("voiceos") ||
               words.contains("voice")
    }

    private fun triggerWakeUp() {
        Log.d("VoiceOS", "Wake word detected natively! Triggering activity wake up...")
        stopListening()

        try {
            val activityIntent = Intent(this, MainActivity::class.java).apply {
                action = "wake_word_detected"
                putExtra("action", "wake_word_detected")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
            startActivity(activityIntent)
        } catch (e: Exception) {
            Log.e("VoiceOS", "Failed to start MainActivity: ${e.message}")
        }
    }

    private val recognitionListener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {
            Log.d("VoiceOS", "Native STT: Ready for speech")
            consecutiveErrorCount = 0
        }

        override fun onBeginningOfSpeech() {
            Log.d("VoiceOS", "Native STT: Beginning of speech")
        }

        override fun onRmsChanged(rmsdB: Float) {}

        override fun onBufferReceived(buffer: ByteArray?) {}

        override fun onEndOfSpeech() {
            Log.d("VoiceOS", "Native STT: End of speech")
        }

        override fun onError(error: Int) {
            val errorMsg = when (error) {
                SpeechRecognizer.ERROR_AUDIO -> "Audio recording error"
                SpeechRecognizer.ERROR_CLIENT -> "Client side error"
                SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Insufficient permissions"
                SpeechRecognizer.ERROR_NETWORK -> "Network error"
                SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "Network timeout"
                SpeechRecognizer.ERROR_NO_MATCH -> "No match found"
                SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "RecognitionService busy"
                SpeechRecognizer.ERROR_SERVER -> "Server sends error"
                SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "No speech input"
                else -> "Unknown error"
            }
            Log.e("VoiceOS", "Native STT Error: $errorMsg ($error)")

            if (isListening) {
                if (error != SpeechRecognizer.ERROR_NO_MATCH && error != SpeechRecognizer.ERROR_SPEECH_TIMEOUT) {
                    consecutiveErrorCount++
                }
                scheduleRestart()
            }
        }

        override fun onResults(results: Bundle?) {
            Log.d("VoiceOS", "Native STT: onResults")
            val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            if (matches != null) {
                for (match in matches) {
                    Log.d("VoiceOS", "Native STT Result: $match")
                    if (containsWakeWord(match)) {
                        triggerWakeUp()
                        return
                    }
                }
            }
            if (isListening) {
                consecutiveErrorCount = 0
                scheduleRestart()
            }
        }

        override fun onPartialResults(partialResults: Bundle?) {
            val matches = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            if (matches != null) {
                for (match in matches) {
                    Log.d("VoiceOS", "Native STT Partial: $match")
                    if (containsWakeWord(match)) {
                        triggerWakeUp()
                        return
                    }
                }
            }
        }

        override fun onEvent(eventType: Int, params: Bundle?) {}
    }
}
