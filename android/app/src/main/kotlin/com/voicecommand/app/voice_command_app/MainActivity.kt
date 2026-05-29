package com.voicecommand.app.voice_command_app

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.ContactsContract
import android.provider.Settings
import android.telecom.TelecomManager
import android.telephony.TelephonyManager
import android.view.KeyEvent
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.voicecommand.app/launcher"
    private var methodChannel: MethodChannel? = null
    private var phoneStateReceiver: BroadcastReceiver? = null
    private val PERMISSION_REQUEST_CODE = 123
    private var wakeWordPending = false

    // Call tracking
    private var activeCallerNumber: String? = null
    private var activeCallerName: String? = null

    // Audio recording
    private var mediaRecorder: MediaRecorder? = null
    private var audioRecordingFile: File? = null

    // Audio playback
    private var mediaPlayer: MediaPlayer? = null
    private var currentPlayingPath: String? = null

    // Volume tracking
    private var originalMusicVolume: Int? = null
    private var originalVoiceVolume: Int? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Make the window touch-through and non-focusable so it doesn't block interactions with other apps
        window.addFlags(
            android.view.WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
            android.view.WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
        )
        handleIntent(intent)
        checkAndRequestPermissions()
        registerPhoneStateReceiver()
        checkActiveRingingState()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        intent?.let {
            val actionVal = it.action ?: it.getStringExtra("action")
            if (actionVal == "wake_word_detected") {
                if (methodChannel != null) {
                    notifyFlutterWakeWordDetected()
                } else {
                    wakeWordPending = true
                }
            }
            if (it.hasExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)) {
                val number = it.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)
                if (number != null && number.isNotEmpty()) {
                    activeCallerNumber = number
                    activeCallerName = getContactName(this, number) ?: "Unknown Caller"
                }
            }
        }
    }

    private fun notifyFlutterWakeWordDetected() {
        Handler(Looper.getMainLooper()).post {
            methodChannel?.invokeMethod("onWakeWordDetected", null)
        }
    }

    private fun controlBackgroundListening(start: Boolean) {
        try {
            val serviceIntent = Intent(this, BackgroundVoiceService::class.java).apply {
                action = if (start) "START_LISTENING" else "STOP_LISTENING"
            }
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                startForegroundService(serviceIntent)
            } else {
                startService(serviceIntent)
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        unregisterPhoneReceiver()
        stopRecordingCallAudio()
        stopAudio()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel = channel

        if (wakeWordPending) {
            wakeWordPending = false
            notifyFlutterWakeWordDetected()
        }

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "launchAppByName" -> {
                    val appName = call.argument<String>("name")
                    if (appName != null) {
                        val success = launchAppByName(appName)
                        result.success(success)
                    } else {
                        result.error("BAD_ARGS", "App name cannot be null", null)
                    }
                }
                "launchPackage" -> {
                    val packageName = call.argument<String>("packageName")
                    if (packageName != null) {
                        val success = launchPackage(packageName)
                        result.success(success)
                    } else {
                        result.error("BAD_ARGS", "Package name cannot be null", null)
                    }
                }
                "getInstalledApps" -> {
                    val appsList = getInstalledApps()
                    result.success(appsList)
                }
                "dialNumber" -> {
                    val number = call.argument<String>("number")
                    if (number != null) {
                        val success = dialNumber(number)
                        result.success(success)
                    } else {
                        result.error("BAD_ARGS", "Number cannot be null", null)
                    }
                }
                "sendSMS" -> {
                    val number = call.argument<String>("number")
                    val message = call.argument<String>("message")
                    val success = sendSMS(number ?: "", message ?: "")
                    result.success(success)
                }
                "openUrl" -> {
                    val url = call.argument<String>("url")
                    if (url != null) {
                        val success = openUrl(url)
                        result.success(success)
                    } else {
                        result.error("BAD_ARGS", "URL cannot be null", null)
                    }
                }
                "minimizeApp" -> {
                    minimizeApp()
                    result.success(true)
                }
                "bringToForeground" -> {
                    bringToForeground()
                    result.success(true)
                }
                "startBackgroundListening" -> {
                    controlBackgroundListening(true)
                    result.success(true)
                }
                "stopBackgroundListening" -> {
                    controlBackgroundListening(false)
                    result.success(true)
                }
                "enableSpeakerphone" -> {
                    enableSpeakerphone()
                    result.success(true)
                }
                "disableSpeakerphone" -> {
                    disableSpeakerphone()
                    result.success(true)
                }
                "playAudio" -> {
                    val path = call.argument<String>("path")
                    if (path != null) {
                        result.success(playAudio(path))
                    } else {
                        result.error("BAD_ARGS", "Path cannot be null", null)
                    }
                }
                "pauseAudio" -> {
                    result.success(pauseAudio())
                }
                "resumeAudio" -> {
                    result.success(resumeAudio())
                }
                "seekAudio" -> {
                    val position = call.argument<Int>("position")
                    if (position != null) {
                        result.success(seekAudio(position))
                    } else {
                        result.error("BAD_ARGS", "Position cannot be null", null)
                    }
                }
                "stopAudio" -> {
                    result.success(stopAudio())
                }
                "getAudioDuration" -> {
                    val path = call.argument<String>("path")
                    if (path != null) {
                        result.success(getAudioDuration(path))
                    } else {
                        result.error("BAD_ARGS", "Path cannot be null", null)
                    }
                }
                "getAudioPosition" -> {
                    result.success(getAudioPosition())
                }
                "isAudioPlaying" -> {
                    result.success(isAudioPlaying())
                }
                "getCurrentPlayingPath" -> {
                    result.success(currentPlayingPath)
                }
                "setWindowTouchable" -> {
                    val touchable = call.argument<Boolean>("touchable") ?: false
                    setWindowTouchable(touchable)
                    result.success(true)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun checkAndRequestPermissions() {
        val permissions = mutableListOf<String>()
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) {
            permissions.add(Manifest.permission.READ_PHONE_STATE)
        }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) {
            permissions.add(Manifest.permission.READ_CONTACTS)
        }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_CALL_LOG) != PackageManager.PERMISSION_GRANTED) {
            permissions.add(Manifest.permission.READ_CALL_LOG)
        }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            permissions.add(Manifest.permission.RECORD_AUDIO)
        }
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.ANSWER_PHONE_CALLS) != PackageManager.PERMISSION_GRANTED) {
                permissions.add(Manifest.permission.ANSWER_PHONE_CALLS)
            }
        }
        if (permissions.isNotEmpty()) {
            ActivityCompat.requestPermissions(this, permissions.toTypedArray(), PERMISSION_REQUEST_CODE)
        }

        // Request overlay draw permission if not granted (needed for background startup)
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
            if (!Settings.canDrawOverlays(this)) {
                val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(intent)
            }
        }
    }


    private fun checkActiveRingingState() {
        try {
            val telephonyManager = getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
            if (telephonyManager.callState == TelephonyManager.CALL_STATE_RINGING) {
                Handler(Looper.getMainLooper()).postDelayed({
                    answerCallAndEnableSpeaker()
                }, 1500)
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun registerPhoneStateReceiver() {
        phoneStateReceiver = object : BroadcastReceiver() {
            private var isAnswering = false

            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == TelephonyManager.ACTION_PHONE_STATE_CHANGED) {
                    val state = intent.getStringExtra(TelephonyManager.EXTRA_STATE)
                    if (state == TelephonyManager.EXTRA_STATE_RINGING) {
                        val number = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)
                        if (number != null && number.isNotEmpty()) {
                            activeCallerNumber = number
                            context?.let {
                                activeCallerName = getContactName(it, number) ?: "Unknown Caller"
                            }
                        }
                        if (!isAnswering) {
                            isAnswering = true
                            Handler(Looper.getMainLooper()).postDelayed({
                                answerCallAndEnableSpeaker()
                                isAnswering = false
                            }, 1500)
                        }
                    } else if (state == TelephonyManager.EXTRA_STATE_OFFHOOK) {
                        // Ensure speakerphone remains enabled as the call connects
                        Handler(Looper.getMainLooper()).postDelayed({
                            enableSpeakerphone()
                        }, 1000)
                        Handler(Looper.getMainLooper()).postDelayed({
                            enableSpeakerphone()
                        }, 2500)
                    } else if (state == TelephonyManager.EXTRA_STATE_IDLE) {
                        disableSpeakerphone()
                        notifyFlutterCallEnded()
                    }
                }
            }
        }
        val filter = IntentFilter(TelephonyManager.ACTION_PHONE_STATE_CHANGED)
        registerReceiver(phoneStateReceiver, filter)
    }

    private fun unregisterPhoneReceiver() {
        phoneStateReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (e: Exception) {
                // Ignore
            }
        }
    }

    private fun answerCallAndEnableSpeaker() {
        try {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                val telecomManager = getSystemService(Context.TELECOM_SERVICE) as TelecomManager
                if (ContextCompat.checkSelfPermission(this, Manifest.permission.ANSWER_PHONE_CALLS) == PackageManager.PERMISSION_GRANTED) {
                    telecomManager.acceptRingingCall()
                    enableSpeakerphone()
                    startRecordingCallAudio()
                    notifyFlutterCallAnswered()
                } else {
                    fallbackAnswerCall()
                }
            } else {
                fallbackAnswerCall()
            }
        } catch (e: Exception) {
            fallbackAnswerCall()
        }
    }

    private fun fallbackAnswerCall() {
        try {
            val mediaButtonIntent = Intent(Intent.ACTION_MEDIA_BUTTON).apply {
                putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_HEADSETHOOK))
            }
            sendOrderedBroadcast(mediaButtonIntent, null)

            val mediaButtonIntentUp = Intent(Intent.ACTION_MEDIA_BUTTON).apply {
                putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_HEADSETHOOK))
            }
            sendOrderedBroadcast(mediaButtonIntentUp, null)
            
            enableSpeakerphone()
            startRecordingCallAudio()
            notifyFlutterCallAnswered()
        } catch (e: Exception) {
            // Ignore
        }
    }

    private fun enableSpeakerphone() {
        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            
            // Save original volumes if not already stored
            if (originalMusicVolume == null) {
                originalMusicVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
            }
            if (originalVoiceVolume == null) {
                originalVoiceVolume = audioManager.getStreamVolume(AudioManager.STREAM_VOICE_CALL)
            }

            // Set streams to maximum volume for text-to-speech clarity
            val maxMusic = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, maxMusic, 0)

            val maxVoice = audioManager.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL)
            audioManager.setStreamVolume(AudioManager.STREAM_VOICE_CALL, maxVoice, 0)

            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            audioManager.isSpeakerphoneOn = true
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun disableSpeakerphone() {
        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioManager.isSpeakerphoneOn = false
            audioManager.mode = AudioManager.MODE_NORMAL

            // Restore original volumes if saved
            originalMusicVolume?.let {
                audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, it, 0)
                originalMusicVolume = null
            }
            originalVoiceVolume?.let {
                audioManager.setStreamVolume(AudioManager.STREAM_VOICE_CALL, it, 0)
                originalVoiceVolume = null
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun notifyFlutterCallAnswered() {
        val data = mapOf(
            "callerNumber" to (activeCallerNumber ?: ""),
            "callerName" to (activeCallerName ?: "Unknown")
        )
        Handler(Looper.getMainLooper()).post {
            methodChannel?.invokeMethod("onCallAnswered", data)
        }
    }

    private fun notifyFlutterCallEnded() {
        val audioPath = stopRecordingCallAudio()
        val data = mapOf(
            "audioPath" to (audioPath ?: "")
        )
        Handler(Looper.getMainLooper()).post {
            methodChannel?.invokeMethod("onCallEnded", data)
        }
        // Reset caller tracking
        activeCallerNumber = null
        activeCallerName = null
    }

    // Audio recording logic
    private fun startRecordingCallAudio() {
        try {
            val cacheDir = externalCacheDir ?: cacheDir
            audioRecordingFile = File.createTempFile("voicemail_rec_", ".mp4", cacheDir)
            
            mediaRecorder = MediaRecorder().apply {
                setAudioSource(MediaRecorder.AudioSource.MIC)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                setAudioEncodingBitRate(128000)
                setAudioSamplingRate(44100)
                setOutputFile(audioRecordingFile!!.absolutePath)
                prepare()
                start()
            }
        } catch (e: Exception) {
            e.printStackTrace()
            mediaRecorder = null
            audioRecordingFile = null
        }
    }

    private fun stopRecordingCallAudio(): String? {
        var filePath: String? = null
        try {
            mediaRecorder?.let {
                it.stop()
                it.release()
                filePath = audioRecordingFile?.absolutePath
            }
        } catch (e: Exception) {
            e.printStackTrace()
        } finally {
            mediaRecorder = null
            audioRecordingFile = null
        }
        return filePath
    }

    // Audio playback logic
    private fun playAudio(path: String): Boolean {
        try {
            mediaPlayer?.stop()
            mediaPlayer?.release()
            
            mediaPlayer = MediaPlayer().apply {
                setDataSource(path)
                prepare()
                start()
            }
            currentPlayingPath = path
            return true
        } catch (e: Exception) {
            e.printStackTrace()
            return false
        }
    }

    private fun pauseAudio(): Boolean {
        mediaPlayer?.let {
            if (it.isPlaying) {
                it.pause()
                return true
            }
        }
        return false
    }

    private fun resumeAudio(): Boolean {
        mediaPlayer?.let {
            if (!it.isPlaying) {
                it.start()
                return true
            }
        }
        return false
    }

    private fun stopAudio(): Boolean {
        mediaPlayer?.let {
            it.stop()
            it.release()
        }
        mediaPlayer = null
        currentPlayingPath = null
        return true
    }

    private fun seekAudio(position: Int): Boolean {
        mediaPlayer?.let {
            it.seekTo(position)
            return true
        }
        return false
    }

    private fun getAudioDuration(path: String): Int {
        var mp: MediaPlayer? = null
        try {
            mp = MediaPlayer()
            mp.setDataSource(path)
            mp.prepare()
            val duration = mp.duration
            mp.release()
            return duration
        } catch (e: Exception) {
            mp?.release()
            return 0
        }
    }

    private fun getAudioPosition(): Int {
        return mediaPlayer?.currentPosition ?: 0
    }

    private fun isAudioPlaying(): Boolean {
        return mediaPlayer?.isPlaying ?: false
    }

    // Contacts Lookup query
    private fun getContactName(context: Context, phoneNumber: String?): String? {
        if (phoneNumber == null || phoneNumber.isEmpty()) return null
        val uri = Uri.withAppendedPath(
            ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
            Uri.encode(phoneNumber)
        )
        val projection = arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME)
        var contactName: String? = null
        try {
            context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    contactName = cursor.getString(cursor.getColumnIndexOrThrow(ContactsContract.PhoneLookup.DISPLAY_NAME))
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return contactName
    }

    private fun launchPackage(packageName: String): Boolean {
        return try {
            val intent = packageManager.getLaunchIntentForPackage(packageName)
            if (intent != null) {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                true
            } else {
                false
            }
        } catch (e: Exception) {
            false
        }
    }

    private fun launchAppByName(name: String): Boolean {
        try {
            val pm = packageManager
            val mainIntent = Intent(Intent.ACTION_MAIN, null).apply {
                addCategory(Intent.CATEGORY_LAUNCHER)
            }
            val resolveInfos = pm.queryIntentActivities(mainIntent, 0)
            
            val searchName = name.lowercase(Locale.ROOT).trim()
            
            // First pass: exact name match
            for (info in resolveInfos) {
                val appLabel = info.loadLabel(pm).toString().lowercase(Locale.ROOT).trim()
                if (appLabel == searchName) {
                    val packageName = info.activityInfo.packageName
                    val intent = pm.getLaunchIntentForPackage(packageName)
                    if (intent != null) {
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        return true
                    }
                }
            }
            
            // Second pass: fuzzy contains match
            for (info in resolveInfos) {
                val appLabel = info.loadLabel(pm).toString().lowercase(Locale.ROOT).trim()
                if (appLabel.contains(searchName) || searchName.contains(appLabel)) {
                    val packageName = info.activityInfo.packageName
                    val intent = pm.getLaunchIntentForPackage(packageName)
                    if (intent != null) {
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        return true
                    }
                }
            }
            return false
        } catch (e: Exception) {
            return false
        }
    }

    private fun getInstalledApps(): List<Map<String, String>> {
        val apps = mutableListOf<Map<String, String>>()
        try {
            val pm = packageManager
            val mainIntent = Intent(Intent.ACTION_MAIN, null).apply {
                addCategory(Intent.CATEGORY_LAUNCHER)
            }
            val resolveInfos = pm.queryIntentActivities(mainIntent, 0)
            for (info in resolveInfos) {
                val appLabel = info.loadLabel(pm).toString()
                val packageName = info.activityInfo.packageName
                apps.add(mapOf("name" to appLabel, "packageName" to packageName))
            }
        } catch (e: Exception) {
            // Ignore
        }
        return apps
    }

    private fun dialNumber(number: String): Boolean {
        return try {
            val intent = Intent(Intent.ACTION_DIAL).apply {
                data = Uri.parse("tel:$number")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun sendSMS(number: String, message: String): Boolean {
        return try {
            val uri = Uri.parse("smsto:$number")
            val intent = Intent(Intent.ACTION_SENDTO, uri).apply {
                putExtra("sms_body", message)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            try {
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    data = Uri.parse("sms:$number?body=" + Uri.encode(message))
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(intent)
                true
            } catch (ex: Exception) {
                false
            }
        }
    }

    private fun openUrl(url: String): Boolean {
        return try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun minimizeApp() {
        try {
            moveTaskToBack(true)
        } catch (e: Exception) {
            // Ignore
        }
    }

    private fun bringToForeground() {
        try {
            val intent = Intent(this, MainActivity::class.java).apply {
                action = Intent.ACTION_MAIN
                addCategory(Intent.CATEGORY_LAUNCHER)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
            startActivity(intent)
        } catch (e: Exception) {
            // Ignore
        }
    }

    private fun setWindowTouchable(touchable: Boolean) {
        Handler(Looper.getMainLooper()).post {
            if (touchable) {
                window.clearFlags(
                    android.view.WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    android.view.WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                )
            } else {
                window.addFlags(
                    android.view.WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    android.view.WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                )
            }
        }
    }
}
