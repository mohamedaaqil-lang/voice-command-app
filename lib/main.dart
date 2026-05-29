import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'services/voice_service.dart';
import 'widgets/voice_wave.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VoiceOSApp());
}

class VoiceOSApp extends StatelessWidget {
  const VoiceOSApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VoiceOS Headless Launcher',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const PhoneShell(),
    );
  }
}

class PhoneShell extends StatefulWidget {
  const PhoneShell({super.key});

  @override
  State<PhoneShell> createState() => _PhoneShellState();
}

class _PhoneShellState extends State<PhoneShell> with WidgetsBindingObserver {
  final VoiceService _voiceService = VoiceService();
  final TextEditingController _textController = TextEditingController();
  bool _showKeyboardInput = false;
  bool _showSettings = false;
  String _searchQuery = "";

  Timer? _startupMinimizationTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Add listener to monitor state transitions
    _voiceService.addListener(_onVoiceServiceChanged);
    
    // Start background listening/wake-word monitoring
    _voiceService.startVoiceOS();
    
    // Delay minimization slightly on startup to allow native service to bind mic
    _startupMinimizationTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted && _voiceService.state == AssistantState.wakeWordMode) {
        _voiceService.minimizeApp();
      }
    });
  }

  @override
  void dispose() {
    _startupMinimizationTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _voiceService.removeListener(_onVoiceServiceChanged);
    _voiceService.stopVoiceOS();
    _textController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _voiceService.setAppResumed(true);
    }
  }

  void _onVoiceServiceChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  String _getStatusText(AssistantState state) {
    switch (state) {
      case AssistantState.listening:
        return "Listening...";
      case AssistantState.processing:
        return "Thinking...";
      case AssistantState.speaking:
        return "Speaking...";
      case AssistantState.recordingVoicemail:
        return "Recording Voicemail...";
      default:
        return "Assistant";
    }
  }

  Widget _buildSuggestionChip(String label) {
    return Padding(
      padding: const EdgeInsets.only(right: 8.0),
      child: ActionChip(
        label: Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
        backgroundColor: Colors.white12,
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        onPressed: () {
          if (label == "Settings") {
            setState(() {
              _showSettings = true;
            });
          } else {
            _voiceService.processTextCommand(label);
          }
        },
      ),
    );
  }

  Widget _buildAssistantView(AssistantState state) {
    final transcript = _voiceService.lastTranscript;
    final response = _voiceService.assistantResponse;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Title / Status
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _getStatusText(state),
              style: TextStyle(
                color: Colors.white.withOpacity(0.6),
                fontSize: 14,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.settings, color: Colors.white54, size: 20),
              onPressed: () {
                setState(() {
                  _showSettings = true;
                });
              },
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Transcript / Answer section
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 120),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (state == AssistantState.listening && transcript.isEmpty)
                  const Text(
                    "How can I help you?",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w300,
                    ),
                  )
                else if (transcript.isNotEmpty)
                  Text(
                    transcript,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                if (state == AssistantState.speaking && response.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    response,
                    style: TextStyle(
                      color: Colors.blue.shade100,
                      fontSize: 18,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),

        // Wave Visualizer
        SizedBox(
          height: 60,
          child: VoiceWaveVisualizer(
            isActive: state == AssistantState.listening || state == AssistantState.speaking,
            isSpeaking: state == AssistantState.speaking,
          ),
        ),
        const SizedBox(height: 16),

        // Suggestion Chips
        if (!_showKeyboardInput)
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _buildSuggestionChip("Open WhatsApp"),
                _buildSuggestionChip("Call 12345"),
                _buildSuggestionChip("Go Home"),
                _buildSuggestionChip("Settings"),
              ],
            ),
          ),

        // Keyboard text input area
        if (_showKeyboardInput)
          Padding(
            padding: const EdgeInsets.only(top: 8.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    autofocus: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: "Type command...",
                      hintStyle: const TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: Colors.white12,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                    onSubmitted: (val) {
                      if (val.trim().isNotEmpty) {
                        _voiceService.processTextCommand(val);
                        _textController.clear();
                        setState(() {
                          _showKeyboardInput = false;
                        });
                      }
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send, color: Colors.blueAccent),
                  onPressed: () {
                    final val = _textController.text;
                    if (val.trim().isNotEmpty) {
                      _voiceService.processTextCommand(val);
                      _textController.clear();
                      setState(() {
                        _showKeyboardInput = false;
                      });
                    }
                  },
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),

        // Bottom Controls
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton(
              icon: Icon(
                _showKeyboardInput ? Icons.mic : Icons.keyboard,
                color: Colors.white70,
              ),
              onPressed: () {
                setState(() {
                  _showKeyboardInput = !_showKeyboardInput;
                });
              },
            ),
            // Middle button: Microphone trigger / Pause Speech
            GestureDetector(
              onTap: () {
                if (state == AssistantState.speaking) {
                  _voiceService.stopListeningOnly();
                } else {
                  _voiceService.triggerAssistantManual();
                }
              },
              child: CircleAvatar(
                radius: 26,
                backgroundColor: state == AssistantState.speaking ? Colors.redAccent.withOpacity(0.8) : Colors.blueAccent.withOpacity(0.8),
                child: Icon(
                  state == AssistantState.speaking ? Icons.stop : Icons.mic,
                  color: Colors.white,
                  size: 28,
                ),
              ),
            ),
            // Close / Minimize button
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white70),
              onPressed: () {
                _voiceService.minimizeApp();
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSettingsView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () {
                setState(() {
                  _showSettings = false;
                });
              },
            ),
            const Text(
              "Assistant Settings",
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const Divider(color: Colors.white24),
        
        // Voice Feedback Toggle
        SwitchListTile(
          title: const Text("Voice Feedback (TTS)", style: TextStyle(color: Colors.white)),
          subtitle: const Text("Vocalize answers", style: TextStyle(color: Colors.white70, fontSize: 12)),
          value: _voiceService.useVoiceFeedback,
          onChanged: (val) {
            _voiceService.toggleVoiceFeedback(val);
            setState(() {});
          },
          activeColor: Colors.blueAccent,
        ),
        
        // Background Listening Status
        ListTile(
          title: const Text("Service Status", style: TextStyle(color: Colors.white)),
          subtitle: Text(
            "Background Listening Active",
            style: TextStyle(color: Colors.greenAccent.shade400, fontSize: 12),
          ),
          trailing: const Icon(Icons.check_circle, color: Colors.green),
        ),

        const Divider(color: Colors.white24),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
          child: Text(
            "Developer Simulation Tools:",
            style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Wrap(
            spacing: 8.0,
            runSpacing: 8.0,
            children: [
              ActionChip(
                avatar: const Icon(Icons.bolt, size: 16, color: Colors.amber),
                label: const Text("Wake Assistant"),
                onPressed: () {
                  setState(() {
                    _showSettings = false;
                  });
                  _voiceService.simulateWakeWord();
                },
                backgroundColor: Colors.deepPurple.withOpacity(0.3),
                side: BorderSide.none,
              ),
              ActionChip(
                avatar: const Icon(Icons.call, size: 16, color: Colors.greenAccent),
                label: const Text("Simulate In Call"),
                onPressed: () {
                  setState(() {
                    _showSettings = false;
                  });
                  _voiceService.simulateIncomingCall("Jane Smith", "+15559876");
                },
                backgroundColor: Colors.teal.withOpacity(0.3),
                side: BorderSide.none,
              ),
              ActionChip(
                avatar: const Icon(Icons.call_end, size: 16, color: Colors.redAccent),
                label: const Text("Simulate Call End"),
                onPressed: () {
                  _voiceService.simulateCallEnded();
                },
                backgroundColor: Colors.red.withOpacity(0.3),
                side: BorderSide.none,
              ),
            ],
          ),
        ),

        const Divider(color: Colors.white24),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16.0),
          child: Text(
            "Quick Commands Help:",
            style: TextStyle(color: Colors.white60, fontSize: 12, fontWeight: FontWeight.bold),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
          child: Text(
            "- \"open [app name]\"\n- \"call [number]\"\n- \"send message to [number] saying [text]\"\n- \"search for [query]\"\n- \"go home\" to minimize",
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
        const SizedBox(height: 10),
      ],
    );
  }

  // --- STUNNING DASHBOARD VIEW IMPLEMENTATION ---
  Widget _buildDashboardView() {
    final voicemails = _voiceService.recordedVoicemails;
    final filteredVoicemails = voicemails.where((vm) {
      final query = _searchQuery.toLowerCase();
      final name = (vm["callerName"] ?? "").toLowerCase();
      final number = (vm["callerNumber"] ?? "").toLowerCase();
      final msg = (vm["message"] ?? "").toLowerCase();
      return name.contains(query) || number.contains(query) || msg.contains(query);
    }).toList().reversed.toList(); // Newest first

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF0C0C12),
            Color(0xFF12121E),
            Color(0xFF1A1A2A),
          ],
        ),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildDashboardHeader(),
            _buildSearchBar(),
            Expanded(
              child: _showSettings
                  ? SingleChildScrollView(child: _buildSettingsView())
                  : (filteredVoicemails.isEmpty
                      ? _buildEmptyState()
                      : _buildVoicemailList(filteredVoicemails)),
            ),
            if (!_showSettings) _buildDashboardFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildDashboardHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 15.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "VoiceOS Workspace",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  const PulseIndicator(),
                  const SizedBox(width: 8),
                  Text(
                    "Background service active",
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.55),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
          IconButton(
            icon: Icon(
              _showSettings ? Icons.dashboard : Icons.settings,
              color: Colors.white70,
            ),
            onPressed: () {
              setState(() {
                _showSettings = !_showSettings;
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    if (_showSettings) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 8.0),
      child: TextField(
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: "Search transcripts...",
          hintStyle: TextStyle(color: Colors.white.withOpacity(0.35)),
          prefixIcon: const Icon(Icons.search, color: Colors.white38, size: 20),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, color: Colors.white54, size: 18),
                  onPressed: () {
                    setState(() {
                      _searchQuery = "";
                    });
                  },
                )
              : null,
          filled: true,
          fillColor: Colors.white.withOpacity(0.04),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Colors.blueAccent, width: 1.5),
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
        ),
        onChanged: (val) {
          setState(() {
            _searchQuery = val;
          });
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.03),
                border: Border.all(color: Colors.white.withOpacity(0.06)),
              ),
              child: const Icon(
                Icons.voicemail,
                size: 36,
                color: Colors.blueAccent,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              "Call Assistant Active",
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              "When an incoming call is received, VoiceOS will automatically answer, activate the speakerphone, record the caller's message, and transcribe it here.",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVoicemailList(List<Map<String, String>> list) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 10.0),
      itemCount: list.length,
      itemBuilder: (context, index) {
        final item = list[index];
        final mainIndex = _voiceService.recordedVoicemails.indexOf(item);
        return _buildVoicemailCard(item, mainIndex);
      },
    );
  }

  Widget _buildVoicemailCard(Map<String, String> voicemail, int index) {
    final callerName = voicemail["callerName"] ?? "Unknown";
    final callerNumber = voicemail["callerNumber"] ?? "";
    final time = voicemail["time"] ?? "";
    final date = voicemail["date"] ?? "";
    final message = voicemail["message"] ?? "";
    final audioPath = voicemail["audioPath"] ?? "";
    
    String initials = "?";
    if (callerName.isNotEmpty && callerName != "Unknown") {
      final parts = callerName.trim().split(" ");
      if (parts.isNotEmpty) {
        initials = parts.first.substring(0, 1).toUpperCase();
        if (parts.length > 1) {
          initials += parts.last.substring(0, 1).toUpperCase();
        }
      }
    } else if (callerNumber.isNotEmpty) {
      initials = "#";
    }

    final isThisPlaying = _voiceService.playingPath == audioPath;
    final isPlaying = isThisPlaying && _voiceService.isPlaying;
    final suggestions = _voiceService.getSuggestionsForMessage(message);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Avatar
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [
                        const Color(0xFF673AB7).withOpacity(0.85),
                        const Color(0xFF00BCD4).withOpacity(0.85),
                      ],
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    initials,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                
                // Name & Phone
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        callerName == "Unknown" && callerNumber.isNotEmpty
                            ? callerNumber
                            : callerName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (callerName != "Unknown" && callerNumber.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          callerNumber,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.5),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                
                // Timestamp & Delete
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      "$time $date",
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.4),
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 2),
                    GestureDetector(
                      onTap: () => _showDeleteConfirmDialog(index),
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 16),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            
            // Transcription message
            Text(
              message,
              style: TextStyle(
                color: Colors.white.withOpacity(0.85),
                fontSize: 14,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            
            // Inline player
            if (audioPath.isNotEmpty) ...[
              _buildInlineAudioPlayer(audioPath, isThisPlaying, isPlaying),
              const SizedBox(height: 12),
            ],

            // Action suggestion chips
            if (suggestions.isNotEmpty || message.isNotEmpty)
              _buildCardActions(suggestions, message, callerNumber),
          ],
        ),
      ),
    );
  }

  Widget _buildInlineAudioPlayer(String path, bool isThisPlaying, bool isPlaying) {
    final double currentPos = isThisPlaying ? _voiceService.audioPosition.toDouble() : 0.0;
    final double duration = isThisPlaying ? _voiceService.audioDuration.toDouble() : 0.0;
    final double maxDuration = duration > 0 ? duration : 1.0;
    final double slideValue = currentPos.clamp(0.0, maxDuration);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
              color: Colors.blueAccent,
              size: 28,
            ),
            onPressed: () {
              if (isPlaying) {
                _voiceService.pauseVoicemailAudio();
              } else {
                _voiceService.playVoicemailAudio(path);
              }
            },
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2.0,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5.0),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 10.0),
              ),
              child: Slider(
                activeColor: Colors.blueAccent,
                inactiveColor: Colors.white12,
                value: slideValue,
                max: maxDuration,
                onChanged: (val) {
                  if (isThisPlaying) {
                    _voiceService.seekVoicemailAudio(val.toInt());
                  }
                },
              ),
            ),
          ),
          Text(
            "${_formatDuration(currentPos)} / ${_formatDuration(duration)}",
            style: TextStyle(
              color: Colors.white.withOpacity(0.55),
              fontSize: 10,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  String _formatDuration(double ms) {
    final dur = Duration(milliseconds: ms.toInt());
    final minutes = dur.inMinutes.toString().padLeft(2, '0');
    final seconds = (dur.inSeconds % 60).toString().padLeft(2, '0');
    return "$minutes:$seconds";
  }

  Widget _buildCardActions(List<Map<String, String>> suggestions, String message, String fallbackNumber) {
    return Wrap(
      spacing: 8.0,
      runSpacing: 4.0,
      children: [
        ...suggestions.map((sug) {
          final type = sug["type"] ?? "";
          final title = sug["title"] ?? "";
          final value = sug["value"] ?? "";
          
          IconData icon = Icons.bolt;
          if (type == "call") icon = Icons.phone;
          if (type == "call_generic") icon = Icons.dialpad;
          if (type == "reminder") icon = Icons.notifications_active;

          return ActionChip(
            avatar: Icon(icon, size: 12, color: Colors.blueAccent),
            label: Text(title, style: const TextStyle(fontSize: 10, color: Colors.white70)),
            backgroundColor: Colors.white.withOpacity(0.04),
            side: BorderSide(color: Colors.white.withOpacity(0.05)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            onPressed: () {
              if (type == "call" && value.isNotEmpty) {
                _voiceService.dialNumber(value);
              } else if (type == "call_generic") {
                _voiceService.dialNumber(fallbackNumber.isNotEmpty ? fallbackNumber : "");
              } else if (type == "reminder") {
                Clipboard.setData(ClipboardData(text: "Reminder: $value"));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Voicemail task copied to clipboard!")),
                );
              }
            },
          );
        }),
        ActionChip(
          avatar: const Icon(Icons.copy, size: 12, color: Colors.blueAccent),
          label: const Text("Copy Text", style: TextStyle(fontSize: 10, color: Colors.white70)),
          backgroundColor: Colors.white.withOpacity(0.04),
          side: BorderSide(color: Colors.white.withOpacity(0.05)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: message));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Transcript copied!")),
            );
          },
        ),
      ],
    );
  }

  void _showDeleteConfirmDialog(int mainIndex) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2F),
        title: const Text("Delete Voicemail", style: TextStyle(color: Colors.white)),
        content: const Text("Are you sure you want to delete this voicemail?", style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            child: const Text("Cancel", style: TextStyle(color: Colors.white54)),
            onPressed: () => Navigator.of(context).pop(),
          ),
          TextButton(
            child: const Text("Delete", style: TextStyle(color: Colors.redAccent)),
            onPressed: () {
              _voiceService.deleteVoicemail(mainIndex);
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildDashboardFooter() {
    return Container(
      padding: const EdgeInsets.only(bottom: 24, top: 12),
      alignment: Alignment.center,
      child: Column(
        children: [
          GestureDetector(
            onTap: () {
              _voiceService.triggerAssistantManual();
            },
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  colors: [Color(0xFF2196F3), Color(0xFF9C27B0)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF9C27B0).withOpacity(0.45),
                    blurRadius: 16,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Icon(Icons.mic, size: 28, color: Colors.white),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Tap to trigger assistant",
            style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 11),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = _voiceService.state;
    final isOverlayActive = state != AssistantState.inactive && state != AssistantState.wakeWordMode;
    final isDashboardActive = !isOverlayActive && !_voiceService.isMinimized;

    return Scaffold(
      backgroundColor: isOverlayActive ? Colors.transparent : const Color(0xFF0C0C12),
      body: Stack(
        children: [
          // 1. Dashboard UI Mode
          if (isDashboardActive)
            _buildDashboardView(),

          // 2. Overlay UI Mode: Background Dimmer
          if (isOverlayActive)
            GestureDetector(
              onTap: () {
                _voiceService.minimizeApp();
              },
              child: Container(
                color: Colors.black54,
              ),
            ),
            
          // 3. Overlay UI Mode: Pulsing Radial Aurora Glow behind sheet
          if (isOverlayActive)
            Positioned(
              bottom: -80,
              left: MediaQuery.of(context).size.width / 2 - 160,
              child: AuroraGlow(
                color1: state == AssistantState.listening ? const Color(0xFF00F2FE) : const Color(0xFF9C27B0),
                color2: state == AssistantState.speaking ? const Color(0xFF00E676) : const Color(0xFF2196F3),
              ),
            ),

          // 4. Overlay UI Mode: Bottom Sheet
          if (isOverlayActive)
            Align(
              alignment: Alignment.bottomCenter,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 18.0, sigmaY: 18.0),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                    width: double.infinity,
                    padding: const EdgeInsets.only(
                      left: 20,
                      right: 20,
                      top: 4,
                      bottom: 24,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.68),
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.12),
                        width: 1.2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.6),
                          blurRadius: 24,
                          offset: const Offset(0, -5),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const GeminiLightbar(),
                        if (_showSettings)
                          _buildSettingsView()
                        else
                          _buildAssistantView(state),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class GeminiLightbar extends StatefulWidget {
  const GeminiLightbar({super.key});

  @override
  State<GeminiLightbar> createState() => _GeminiLightbarState();
}

class _GeminiLightbarState extends State<GeminiLightbar>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          margin: const EdgeInsets.only(bottom: 20, top: 4),
          height: 5,
          width: 140,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF00BCD4).withOpacity(0.4),
                blurRadius: 8,
                spreadRadius: 1,
              ),
            ],
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: const [
                Color(0xFF9C27B0), // Purple
                Color(0xFF00BCD4), // Cyan
                Color(0xFF2196F3), // Blue
                Color(0xFFFFEB3B), // Yellow
                Color(0xFF9C27B0), // Purple loop
              ],
              stops: [
                0.0,
                (_controller.value - 0.25).clamp(0.0, 1.0),
                (_controller.value).clamp(0.0, 1.0),
                (_controller.value + 0.25).clamp(0.0, 1.0),
                1.0,
              ],
            ),
          ),
        );
      },
    );
  }
}

// --- SLOW PULSING RADIAL GRADIENT AURORA ---
class AuroraGlow extends StatefulWidget {
  final Color color1;
  final Color color2;
  const AuroraGlow({super.key, required this.color1, required this.color2});

  @override
  State<AuroraGlow> createState() => _AuroraGlowState();
}

class _AuroraGlowState extends State<AuroraGlow> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          width: 320,
          height: 320,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                Color.lerp(widget.color1, widget.color2, _controller.value)!.withOpacity(0.18),
                Color.lerp(widget.color2, widget.color1, _controller.value)!.withOpacity(0.0),
              ],
            ),
          ),
        );
      },
    );
  }
}

// --- STANDALONE PULSING ACTIVE INDICATOR ---
class PulseIndicator extends StatefulWidget {
  const PulseIndicator({super.key});

  @override
  State<PulseIndicator> createState() => _PulseIndicatorState();
}

class _PulseIndicatorState extends State<PulseIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.greenAccent,
            boxShadow: [
              BoxShadow(
                color: Colors.greenAccent.withOpacity(0.6),
                blurRadius: 4 + _controller.value * 8,
                spreadRadius: _controller.value * 3,
              ),
            ],
          ),
        );
      },
    );
  }
}
