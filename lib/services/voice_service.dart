import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';

enum AssistantState {
  inactive,      // Normal phone operation, not showing assistant overlay
  wakeWordMode,  // Listening in the background for "Hey Assistant" or "Hey VoiceOS"
  listening,     // Assistant overlay is visible and actively listening for a command
  processing,    // Assistant is processing or executing a command
  speaking,      // Assistant is speaking a vocal response
  recordingVoicemail // Assistant is recording voicemail from the caller
}

class VoiceService extends ChangeNotifier {
  static final VoiceService _instance = VoiceService._internal();
  factory VoiceService() => _instance;
  VoiceService._internal() {
    _initTts();
    _initStt();
    fetchInstalledApps();
    _setupMethodChannel();
    _loadVoicemails();
  }

  static const _channel = MethodChannel('com.voicecommand.app/launcher');

  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();

  bool _isSttInitialized = false;
  bool _isTtsInitialized = false;
  int _sttErrorCount = 0;

  AssistantState _state = AssistantState.inactive;
  AssistantState get state => _state;

  bool _isMinimized = false;
  bool get isMinimized => _isMinimized;

  void setAppResumed(bool resumed) {
    _isMinimized = !resumed;
    _updateTouchableState();
    notifyListeners();
  }

  Future<void> _updateTouchableState() async {
    if (kIsWeb) return;
    try {
      final bool isActive = _state != AssistantState.inactive && _state != AssistantState.wakeWordMode;
      final bool touchable = !_isMinimized || isActive;
      await _channel.invokeMethod('setWindowTouchable', {'touchable': touchable});
    } catch (e) {
      debugPrint("Error setting touchable state: $e");
    }
  }

  void _updateState(AssistantState newState) {
    if (_state != newState) {
      _state = newState;
      _updateTouchableState();
      notifyListeners();
    }
  }

  String _lastTranscript = "";
  String get lastTranscript => _lastTranscript;

  String _assistantResponse = "";
  String get assistantResponse => _assistantResponse;

  String _currentScreen = "home"; // home, settings
  String get currentScreen => _currentScreen;

  bool _useVoiceFeedback = true;
  bool get useVoiceFeedback => _useVoiceFeedback;

  List<Map<String, String>> installedApps = [];

  // Timer for restarting listening to bypass limits
  Timer? _sttTimeoutTimer;

  // Track if we explicitly stopped listening
  bool _explicitlyStopped = false;

  Future<void> _initTts() async {
    try {
      await _tts.setLanguage("en-US");
      await _tts.setPitch(1.0);
      await _tts.setSpeechRate(0.5);

      _tts.setCompletionHandler(() {
        if (_state == AssistantState.speaking) {
          if (_assistantResponse.contains("record it")) {
            _startVoicemailRecording();
          } else if (_assistantResponse.contains("listening") || 
              _assistantResponse.contains("What would you like") ||
              _assistantResponse.contains("help")) {
            _startListeningForCommand();
          } else {
            _startWakeWordMode();
          }
        }
      });
      _isTtsInitialized = true;
    } catch (e) {
      debugPrint("TTS Init Error: $e");
    }
  }

  Future<void> _initStt() async {
    try {
      _isSttInitialized = await _speech.initialize(
        onStatus: (status) {
          debugPrint("STT Status: $status");
          if (status == "listening") {
            _sttErrorCount = 0;
          }
          if (status == "done" || status == "notListening") {
            _handleSttStopped();
          }
        },
        onError: (error) {
          debugPrint("STT Error: $error");
          _sttErrorCount++;
          _handleSttStopped();
        },
      );
      if (_isSttInitialized) {
        _sttErrorCount = 0;
      } else {
        _sttErrorCount++;
        _retryInitStt();
      }
      notifyListeners();
    } catch (e) {
      debugPrint("STT Init Error: $e");
      _sttErrorCount++;
      _retryInitStt();
    }
  }

  void _retryInitStt() {
    final backoffSeconds = (1 << _sttErrorCount).clamp(1, 30);
    debugPrint("Retrying STT initialization in $backoffSeconds seconds...");
    Future.delayed(Duration(seconds: backoffSeconds), () {
      if (!_isSttInitialized && !_explicitlyStopped) {
        _initStt();
      }
    });
  }

  // Request permissions and start the wake word listener
  Future<bool> startVoiceOS() async {
    if (kIsWeb) {
      _explicitlyStopped = false;
      _startWakeWordMode();
      return true;
    } else {
      var status = await Permission.microphone.status;
      if (!status.isGranted) {
        status = await Permission.microphone.request();
      }
      if (status.isGranted) {
        _explicitlyStopped = false;
        _startWakeWordMode();
        return true;
      }
    }
    return false;
  }

  void stopVoiceOS() {
    _explicitlyStopped = true;
    _sttTimeoutTimer?.cancel();
    _speech.stop();
    _tts.stop();
    _channel.invokeMethod('stopBackgroundListening').catchError((e) {
      debugPrint("Error stopping background listening: $e");
    });
    _updateState(AssistantState.inactive);
  }

  void toggleVoiceFeedback(bool value) {
    _useVoiceFeedback = value;
    notifyListeners();
  }

  void setScreen(String screen) {
    _currentScreen = screen;
    notifyListeners();
  }

  Future<void> fetchInstalledApps() async {
    if (kIsWeb) return;
    try {
      final List<dynamic>? apps = await _channel.invokeMethod<List<dynamic>>('getInstalledApps');
      if (apps != null) {
        installedApps = apps.map((app) {
          final map = app as Map;
          return {
            "name": (map["name"] as String? ?? "Unknown"),
            "packageName": (map["packageName"] as String? ?? ""),
          };
        }).toList();
        installedApps.sort((a, b) => a["name"]!.toLowerCase().compareTo(b["name"]!.toLowerCase()));
        notifyListeners();
      }
    } catch (e) {
      debugPrint("Failed to fetch installed apps: $e");
    }
  }

  Future<void> minimizeApp() async {
    if (kIsWeb) return;
    try {
      _isMinimized = true;
      await _updateTouchableState();
      await _channel.invokeMethod('minimizeApp');
      notifyListeners();
    } catch (e) {
      debugPrint("Failed to minimize: $e");
    }
  }

  Future<void> bringToForeground() async {
    if (kIsWeb) return;
    try {
      _isMinimized = false;
      await _updateTouchableState();
      await _channel.invokeMethod('bringToForeground');
      notifyListeners();
    } catch (e) {
      debugPrint("Failed to bring to foreground: $e");
    }
  }

  Future<bool> launchAppByName(String name) async {
    if (kIsWeb) return false;
    try {
      final bool? success = await _channel.invokeMethod<bool>('launchAppByName', {'name': name});
      return success ?? false;
    } catch (e) {
      debugPrint("Failed to launch app: $e");
      return false;
    }
  }

  Future<bool> launchPackage(String packageName) async {
    if (kIsWeb) return false;
    try {
      final bool? success = await _channel.invokeMethod<bool>('launchPackage', {'packageName': packageName});
      return success ?? false;
    } catch (e) {
      debugPrint("Failed to launch package: $e");
      return false;
    }
  }

  Future<bool> dialNumber(String number) async {
    if (kIsWeb) return false;
    try {
      final bool? success = await _channel.invokeMethod<bool>('dialNumber', {'number': number});
      return success ?? false;
    } catch (e) {
      debugPrint("Failed to dial number: $e");
      return false;
    }
  }

  Future<bool> sendSMS(String number, String message) async {
    if (kIsWeb) return false;
    try {
      final bool? success = await _channel.invokeMethod<bool>('sendSMS', {'number': number, 'message': message});
      return success ?? false;
    } catch (e) {
      debugPrint("Failed to send SMS: $e");
      return false;
    }
  }

  // Speak a message and set assistant state
  Future<void> speak(String text) async {
    _assistantResponse = text;
    _updateState(AssistantState.speaking);


    if (_useVoiceFeedback && _isTtsInitialized) {
      await _speech.stop(); // Stop listening while speaking
      await _tts.speak(text);
    } else {
      Future.delayed(const Duration(seconds: 2), () {
        if (_state == AssistantState.speaking) {
          if (_assistantResponse.contains("listening") || 
              _assistantResponse.contains("What would you like") ||
              _assistantResponse.contains("help")) {
            _startListeningForCommand();
          } else {
            _startWakeWordMode();
          }
        }
      });
    }
  }

  // Listen for the Wake Word ("Hey Assistant" or "Hey VoiceOS")
  void _startWakeWordMode() {
    if (_explicitlyStopped) return;
    _lastTranscript = "";
    _updateState(AssistantState.wakeWordMode);


    _channel.invokeMethod('startBackgroundListening').catchError((e) {
      debugPrint("Failed to start native background listening: $e");
    });
  }

  // Triggered when Wake Word is heard
  void _triggerWakeUp() {
    _sttTimeoutTimer?.cancel();
    _speech.stop();
    _channel.invokeMethod('stopBackgroundListening').catchError((e) {
      debugPrint("Failed to stop native background listening: $e");
    });
    bringToForeground().then((_) {
      speak("Yes, I'm listening. What would you like me to do?");
    });
  }

  // Manually trigger the assistant (e.g. by tapping the floating mic button)
  void triggerAssistantManual() {
    _sttTimeoutTimer?.cancel();
    _speech.stop();
    bringToForeground().then((_) {
      speak("How can I help you?");
    });
  }

  // Stop listening for voice without speaking fallback
  void stopListeningOnly() {
    _sttTimeoutTimer?.cancel();
    if (_speech.isListening) {
      _speech.stop();
    }
    _state = AssistantState.processing;
    notifyListeners();
  }

  // Force start listening for a command
  void startListeningForCommand() {
    _explicitlyStopped = false;
    _tts.stop();
    if (_speech.isListening) {
      _speech.stop().then((_) {
        Future.delayed(const Duration(milliseconds: 300), () {
          _startListeningForCommand();
        });
      });
    } else {
      _startListeningForCommand();
    }
  }

  // Listen for the actual command
  void _startListeningForCommand() {
    if (_explicitlyStopped) return;
    _lastTranscript = "";
    _updateState(AssistantState.listening);


    if (!_isSttInitialized) return;
    if (_speech.isListening) return; // Prevent concurrent listening errors

    _channel.invokeMethod('stopBackgroundListening').catchError((e) {
      debugPrint("Failed to stop native background listening: $e");
    });

    _speech.listen(
      onResult: (result) {
        _lastTranscript = result.recognizedWords;
        notifyListeners();

        if (result.finalResult) {
          _processCommand(result.recognizedWords);
        }
      },
      listenFor: const Duration(seconds: 15), // Increase limit for command listening
      pauseFor: const Duration(seconds: 10),  // Allow time to formulate commands
      partialResults: true,
      cancelOnError: false,
      listenMode: stt.ListenMode.confirmation,
    );
  }

  void _handleSttStopped() {
    if (_explicitlyStopped) return;

    if (_state == AssistantState.wakeWordMode) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (_state == AssistantState.wakeWordMode) {
          _startWakeWordMode();
        }
      });
    } else if (_state == AssistantState.listening) {
      if (_lastTranscript.isNotEmpty) {
        _processCommand(_lastTranscript);
      } else {
        speak("I didn't catch that. Let me know when you need me.");
      }
    } else if (_state == AssistantState.recordingVoicemail) {
      if (_lastTranscript.trim().isNotEmpty) {
        saveVoicemail(_lastTranscript);
        _lastTranscript = "";
      }
      _updateState(AssistantState.inactive);
      _startWakeWordMode();
    }
  }

  void _setupMethodChannel() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onCallAnswered':
          final args = call.arguments != null ? Map<String, dynamic>.from(call.arguments as Map) : <String, dynamic>{};
          await handleCallAnsweredNatively(args);
          break;
        case 'onCallEnded':
          final args = call.arguments != null ? Map<String, dynamic>.from(call.arguments as Map) : <String, dynamic>{};
          await handleCallEndedNatively(args);
          break;
        case 'onWakeWordDetected':
          _triggerWakeUp();
          break;
      }
    });
  }

  final List<Map<String, String>> _recordedVoicemails = [];
  List<Map<String, String>> get recordedVoicemails => _recordedVoicemails;

  // Active call details
  String _activeCallerName = "";
  String _activeCallerNumber = "";
  String _activeAudioPath = "";

  // Audio playback state
  String? _playingPath;
  String? get playingPath => _playingPath;

  bool _isPlaying = false;
  bool get isPlaying => _isPlaying;

  int _audioDuration = 0;
  int get audioDuration => _audioDuration;

  int _audioPosition = 0;
  int get audioPosition => _audioPosition;

  Timer? _playbackTimer;

  Future<void> handleCallAnsweredNatively(Map<String, dynamic> data) async {
    _activeCallerName = data['callerName'] ?? 'Unknown';
    _activeCallerNumber = data['callerNumber'] ?? '';
    _activeAudioPath = '';
    await bringToForeground();
    await Future.delayed(const Duration(milliseconds: 1200));
    try {
      await _channel.invokeMethod('enableSpeakerphone');
    } catch (e) {
      debugPrint("Failed to enable speakerphone: $e");
    }
    await speak("If you want to say anything, just tell me. I will record it.");
  }

  Future<void> handleCallEndedNatively(Map<String, dynamic> data) async {
    _activeAudioPath = data['audioPath'] ?? '';
    try {
      await _channel.invokeMethod('disableSpeakerphone');
    } catch (e) {
      debugPrint("Failed to disable speakerphone: $e");
    }
    if (_state == AssistantState.recordingVoicemail || _speech.isListening) {
      await _speech.stop();
      final msg = _lastTranscript.trim();
      if (msg.isNotEmpty || _activeAudioPath.isNotEmpty) {
        saveVoicemail(
          msg.isNotEmpty ? msg : "(No voice message transcribed)",
          callerName: _activeCallerName,
          callerNumber: _activeCallerNumber,
          audioPath: _activeAudioPath,
        );
      }
      _state = AssistantState.inactive;
      _startWakeWordMode();
    }
  }

  // Audio Playback Controls
  Future<void> playVoicemailAudio(String path) async {
    try {
      if (_playingPath == path && !_isPlaying) {
        final success = await _channel.invokeMethod<bool>('resumeAudio');
        if (success == true) {
          _isPlaying = true;
          _startPlaybackTimer();
          notifyListeners();
        }
      } else {
        // Stop any current playing
        if (_isPlaying) {
          await stopVoicemailAudio();
        }
        final success = await _channel.invokeMethod<bool>('playAudio', {'path': path});
        if (success == true) {
          _playingPath = path;
          _isPlaying = true;
          final dur = await _channel.invokeMethod<int>('getAudioDuration', {'path': path});
          _audioDuration = dur ?? 0;
          _audioPosition = 0;
          _startPlaybackTimer();
          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint("Play Audio Error: $e");
    }
  }

  Future<void> pauseVoicemailAudio() async {
    try {
      final success = await _channel.invokeMethod<bool>('pauseAudio');
      if (success == true) {
        _isPlaying = false;
        _playbackTimer?.cancel();
        notifyListeners();
      }
    } catch (e) {
      debugPrint("Pause Audio Error: $e");
    }
  }

  Future<void> stopVoicemailAudio() async {
    try {
      await _channel.invokeMethod('stopAudio');
      _isPlaying = false;
      _playingPath = null;
      _audioPosition = 0;
      _audioDuration = 0;
      _playbackTimer?.cancel();
      notifyListeners();
    } catch (e) {
      debugPrint("Stop Audio Error: $e");
    }
  }

  Future<void> seekVoicemailAudio(int positionMs) async {
    try {
      final success = await _channel.invokeMethod<bool>('seekAudio', {'position': positionMs});
      if (success == true) {
        _audioPosition = positionMs;
        notifyListeners();
      }
    } catch (e) {
      debugPrint("Seek Audio Error: $e");
    }
  }

  void _startPlaybackTimer() {
    _playbackTimer?.cancel();
    _playbackTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) async {
      try {
        final playing = await _channel.invokeMethod<bool>('isAudioPlaying') ?? false;
        if (!playing) {
          _isPlaying = false;
          _playingPath = null;
          timer.cancel();
          notifyListeners();
          return;
        }
        final pos = await _channel.invokeMethod<int>('getAudioPosition') ?? 0;
        _audioPosition = pos;
        notifyListeners();
      } catch (e) {
        timer.cancel();
      }
    });
  }

  void _startVoicemailRecording() {
    _lastTranscript = "";
    _updateState(AssistantState.recordingVoicemail);


    if (!_isSttInitialized) return;
    if (_speech.isListening) return;

    _channel.invokeMethod('stopBackgroundListening').catchError((e) {
      debugPrint("Failed to stop native background listening: $e");
    });

    _speech.listen(
      onResult: (result) {
        _lastTranscript = result.recognizedWords;
        notifyListeners();
      },
      listenFor: const Duration(seconds: 60),
      pauseFor: const Duration(seconds: 15), // Increase pause limit for incoming callers
      partialResults: true,
      cancelOnError: false,
      listenMode: stt.ListenMode.dictation,
    );
  }

  Future<File> get _localFile async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/voicemails.json');
  }

  Future<void> _loadVoicemails() async {
    try {
      final file = await _localFile;
      if (await file.exists()) {
        final contents = await file.readAsString();
        final List<dynamic> jsonList = jsonDecode(contents);
        _recordedVoicemails.clear();
        _recordedVoicemails.addAll(jsonList.map((item) => Map<String, String>.from(item)));
        notifyListeners();
      }
    } catch (e) {
      debugPrint("Error loading voicemails: $e");
    }
  }

  Future<void> _saveVoicemailsToDisk() async {
    try {
      final file = await _localFile;
      final contents = jsonEncode(_recordedVoicemails);
      await file.writeAsString(contents);
    } catch (e) {
      debugPrint("Error saving voicemails: $e");
    }
  }

  void saveVoicemail(String message, {String? callerName, String? callerNumber, String? audioPath}) {
    final now = DateTime.now();
    final timeStr = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
    final dateStr = "${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}";
    _recordedVoicemails.add({
      'time': timeStr,
      'date': dateStr,
      'message': message,
      'callerName': callerName ?? '',
      'callerNumber': callerNumber ?? '',
      'audioPath': audioPath ?? '',
    });
    _saveVoicemailsToDisk();
    notifyListeners();
  }

  void deleteVoicemail(int index) {
    if (index >= 0 && index < _recordedVoicemails.length) {
      _recordedVoicemails.removeAt(index);
      _saveVoicemailsToDisk();
      notifyListeners();
    }
  }

  List<Map<String, String>> getSuggestionsForMessage(String message) {
    final List<Map<String, String>> suggestions = [];
    final text = message.toLowerCase();

    // 1. Phone number detection
    final phoneRegex = RegExp(r'\b\d{10}\b|\b\d{3}[-.\s]??\d{3}[-.\s]??\d{4}\b');
    final match = phoneRegex.firstMatch(message);
    if (match != null) {
      suggestions.add({
        'type': 'call',
        'title': 'Call Back',
        'value': match.group(0)!,
      });
    } else if (text.contains('call me') || text.contains('call back') || text.contains('dial')) {
      suggestions.add({
        'type': 'call_generic',
        'title': 'Open Dialer',
        'value': '',
      });
    }

    // 2. Schedule / Meeting detection
    final scheduleKeywords = [
      'meet', 'meeting', 'tomorrow', 'schedule', 'appointment', 'reminder', 'remind',
      'pm', 'am', 'oclock', 'o\'clock', 'today', 'monday', 'tuesday', 'wednesday',
      'thursday', 'friday', 'saturday', 'sunday', 'calendar', 'at 5', 'at 6', 'at 7',
      'at 8', 'at 9', 'at 10', 'at 11', 'at 12', 'at 1', 'at 2', 'at 3', 'at 4'
    ];
    
    bool hasScheduleKeyword = false;
    for (var keyword in scheduleKeywords) {
      if (text.contains(keyword)) {
        hasScheduleKeyword = true;
        break;
      }
    }

    if (hasScheduleKeyword) {
      String reminderTitle = "Follow up: call message";
      if (text.contains("meet")) {
        reminderTitle = "Meeting from voicemail";
      } else if (text.contains("remind")) {
        reminderTitle = "Reminder from voicemail";
      }
      suggestions.add({
        'type': 'reminder',
        'title': 'Create Reminder',
        'value': reminderTitle,
      });
    }

    return suggestions;
  }

  // Run a typed text command directly (fallback/keyboard input)
  void processTextCommand(String textCommand) {
    if (textCommand.trim().isEmpty) return;
    _lastTranscript = textCommand;
    _updateState(AssistantState.processing);

    _processCommand(textCommand);
  }

  // NLP Command parsing logic
  Future<void> _processCommand(String text) async {
    _updateState(AssistantState.processing);


    // 1. Clean the input text of polite prefixes and wake words
    String command = text.toLowerCase().trim();
    
    // Strip common filler words
    final fillers = [
      "please", "can you", "could you", "would you", "hey", "assistant", 
      "voiceos", "google", "ok google", "hey google", "hi", "hello", "system"
    ];
    
    // Keep stripping fillers from the start of the command
    bool stripped = true;
    while (stripped) {
      stripped = false;
      for (var filler in fillers) {
        if (command.startsWith(filler)) {
          command = command.substring(filler.length).trim();
          stripped = true;
        }
      }
      // strip leading punctuation
      command = command.replaceAll(RegExp(r"^[,\s.?!\-]+"), "").trim();
    }
    
    debugPrint("Parsed command after cleaning: $command");

    // Check for minimize/close commands
    final minimizeKeywords = ["go home", "go back", "close", "exit", "minimize", "quit", "hide", "back"];
    if (minimizeKeywords.contains(command) || command.isEmpty) {
      await speak("Minimizing.");
      await minimizeApp();
      return;
    }

    // 2. Extract action triggers (allowing matches anywhere, not just at ^)
    final openRegex = RegExp(r"(?:open|launch|start|run|go\s+to)\s+(.+)");
    final callRegex = RegExp(r"(?:call|dial|phone|make\s+a\s+call\s+to)\s+(.+)");
    final msgRegex = RegExp(r"(?:send\s+message\s+to|send\s+text\s+to|text|message|whatsapp)\s+(.+?)(?:\s+(?:saying|with\s+text|texting|to\s+say))?\s+(.+)");
    final searchRegex = RegExp(r"(?:search\s+for|search|google|find|look\s+up|what\s+is|how\s+to)\s+(.+)");

    // 3. Process Messaging
    if (msgRegex.hasMatch(command)) {
      final match = msgRegex.firstMatch(command);
      final recipient = match?.group(1) ?? "";
      final message = match?.group(2) ?? "";
      if (recipient.isNotEmpty && message.isNotEmpty) {
        final isNumber = RegExp(r"^[0-9\s+\-\*#]+$").hasMatch(recipient);
        if (isNumber) {
          await speak("Sending message to $recipient.");
          await _channel.invokeMethod('sendSMS', {'number': recipient.replaceAll(' ', ''), 'message': message});
          await minimizeApp();
        } else {
          if (recipient.toLowerCase().contains("whatsapp") || command.contains("whatsapp")) {
            await speak("Opening WhatsApp.");
            await launchAppByName("whatsapp");
          } else {
            await speak("Opening messages for $recipient.");
            final success = await launchAppByName("messages");
            if (!success) {
              await launchAppByName("messaging");
            }
          }
          await minimizeApp();
        }
        return;
      }
    }

    // 4. Process Calling
    if (callRegex.hasMatch(command)) {
      final match = callRegex.firstMatch(command);
      final target = match?.group(1) ?? "";
      if (target.isNotEmpty) {
        final isNumber = RegExp(r"^[0-9\s+\-\*#]+$").hasMatch(target);
        if (isNumber) {
          await speak("Calling $target.");
          await _channel.invokeMethod('dialNumber', {'number': target.replaceAll(' ', '')});
          await minimizeApp();
        } else {
          await speak("Opening dialer to call $target.");
          final success = await launchAppByName("phone");
          if (!success) {
            await launchAppByName("dialer");
          }
          await minimizeApp();
        }
        return;
      }
    }

    // 5. Process App Opening
    if (openRegex.hasMatch(command)) {
      final match = openRegex.firstMatch(command);
      final appName = match?.group(1) ?? "";
      if (appName.isNotEmpty) {
        await speak("Opening $appName.");
        final success = await launchAppByName(appName);
        if (success) {
          await minimizeApp();
        } else {
          await speak("I couldn't find an app named $appName on your device.");
        }
        return;
      }
    }

    // 6. Process Web Search
    if (searchRegex.hasMatch(command)) {
      final match = searchRegex.firstMatch(command);
      final query = match?.group(1) ?? "";
      if (query.isNotEmpty) {
        await speak("Searching for $query.");
        final searchUrl = "https://www.google.com/search?q=${Uri.encodeComponent(query)}";
        await _channel.invokeMethod('openUrl', {'url': searchUrl});
        await minimizeApp();
        return;
      }
    }

    // 7. Fallback 1: Try to launch app directly by name matching (if command is short)
    if (command.length < 25) {
      final success = await launchAppByName(command);
      if (success) {
        await speak("Opening $command.");
        await minimizeApp();
        return;
      }
    }

    // 8. Fallback 2: Perform Google search on original query
    await speak("Searching for $text.");
    final searchUrl = "https://www.google.com/search?q=${Uri.encodeComponent(text)}";
    await _channel.invokeMethod('openUrl', {'url': searchUrl});
    await minimizeApp();
  }

  // Simulation Tools for Debugging
  void simulateWakeWord() {
    _triggerWakeUp();
  }

  Future<void> simulateIncomingCall(String name, String number) async {
    await handleCallAnsweredNatively({
      'callerName': name,
      'callerNumber': number,
    });
  }

  Future<void> simulateCallEnded() async {
    await handleCallEndedNatively({
      'audioPath': '',
    });
  }
}
