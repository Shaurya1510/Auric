import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

// Feature: AI chat workspace with streaming, sessions, image upload, and voice input.
class AiChatScreen extends StatefulWidget {
  final VoidCallback? onSwitch;

  const AiChatScreen({super.key, this.onSwitch});

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen> {
  // Core dependencies/controllers used across chat features.
  final _api = ApiService();
  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _picker = ImagePicker();
  final _speech = SpeechToText();

  // Chat state.
  List<ChatMessage> _messages = [];
  List<ChatSession> _sessions = [];
  String? _currentSessionId;
  bool _isLoading = false;
  bool _showSidebar = false;
  String _searchQuery = '';
  // Pending image attachments for the next outgoing message.
  final List<String> _imageDataList = [];
  final List<String> _imageMimeTypeList = [];
  String _activeProvider = 'openai'; // shown as indicator badge
  bool _fastResponseMode = true;
  bool _isListening = false;
  bool _speechReady = false;

  // "My Stuff" view
  bool _isStuffView = false;
  List<dynamic> _uploadedImages = [];

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  @override
  void dispose() {
    _speech.stop();
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // Loads sidebar sessions (optionally filtered by search query).
  Future<void> _loadSessions() async {
    try {
      final sessions = await _api.getSessions(
          search: _searchQuery.isEmpty ? null : _searchQuery);
      if (mounted) setState(() => _sessions = sessions);
    } catch (e) {
      debugPrint('Error loading sessions: $e');
    }
  }

  // Loads all messages for one session and switches current session context.
  Future<void> _loadMessages(String sessionId) async {
    try {
      final msgs = await _api.getMessages(sessionId);
      if (mounted) {
        setState(() {
          _messages = msgs;
          _currentSessionId = sessionId;
        });
        _scrollToBottom();
      }
    } catch (e) {
      debugPrint('Error loading messages: $e');
      if (mounted) {
        _showSnackBar('Could not load messages. Check your connection.');
      }
    }
  }

  // Loads "My Stuff" gallery (messages that include image payloads).
  Future<void> _loadImages() async {
    try {
      final res = await _api.getImages();
      if (mounted) setState(() => _uploadedImages = res);
    } catch (e) {
      debugPrint('Error loading images: $e');
    }
  }

  Future<void> _toggleVoiceInput() async {
    // Tap again to stop listening (manual send only).
    if (_isListening) {
      HapticFeedback.selectionClick();
      await _speech.stop();
      if (mounted) setState(() => _isListening = false);
      return;
    }

    // Lazy initialize speech engine once per screen lifecycle.
    if (!_speechReady) {
      final available = await _speech.initialize(
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') {
            if (mounted) setState(() => _isListening = false);
          }
        },
        onError: (_) {
          if (mounted) {
            setState(() => _isListening = false);
            _showSnackBar('Voice input error. Please try again.');
          }
        },
      );
      _speechReady = available;
      if (!available) {
        if (mounted) {
          _showSnackBar('Voice input unavailable on this device.');
        }
        return;
      }
    }

    final voiceSeedText = _textCtrl.text.trim();
    HapticFeedback.lightImpact();
    setState(() => _isListening = true);

    // Start capturing partial/final transcripts and keep TextField in sync.
    await _speech.listen(
      localeId: 'en_US',
      listenFor: const Duration(seconds: 45),
      pauseFor: const Duration(seconds: 3),
      partialResults: true,
      onResult: (result) {
        final spoken = _normalizeVoiceText(result.recognizedWords);
        final merged = voiceSeedText.isEmpty
            ? spoken
            : '$voiceSeedText ${spoken.trim()}'.trim();
        _textCtrl
          ..text = merged
          ..selection = TextSelection.collapsed(offset: merged.length);
      },
    );
  }

  String _normalizeVoiceText(String input) {
    var out = input.trim();
    if (out.isEmpty) return out;

    final replacements = <RegExp, String>{
      RegExp(r'\bplus\b', caseSensitive: false): '+',
      RegExp(r'\bminus\b', caseSensitive: false): '-',
      RegExp(r'\b(times|multiplied by|multiply by|into)\b',
          caseSensitive: false): '×',
      RegExp(r'\b(divided by|divide by|over)\b', caseSensitive: false): '÷',
      RegExp(r'\b(open bracket|open parenthesis)\b', caseSensitive: false): '(',
      RegExp(r'\b(close bracket|close parenthesis)\b', caseSensitive: false):
          ')',
      RegExp(r'\b(to the power of|raised to|power of)\b', caseSensitive: false):
          '^',
      RegExp(r'\bsquared\b', caseSensitive: false): '^2',
      RegExp(r'\bcubed\b', caseSensitive: false): '^3',
      RegExp(r'\b(square root of|root of)\b', caseSensitive: false): 'sqrt ',
      RegExp(r'\bequals\b', caseSensitive: false): '=',
    };

    replacements.forEach((pattern, value) {
      out = out.replaceAll(pattern, value);
    });

    return out.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  void _scrollToBottom({bool animated = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        final target = _scrollCtrl.position.maxScrollExtent;
        if (animated) {
          _scrollCtrl.animateTo(
            target,
            duration: 300.ms,
            curve: Curves.easeOutCubic,
          );
        } else {
          _scrollCtrl.jumpTo(target);
        }
      }
    });
  }

  /// Streams the AI response, updating the message bubble token-by-token.
  Future<void> _sendMessage([String? prefilled]) async {
    // Guard: avoid empty sends and parallel in-flight sends.
    final text = prefilled ?? _textCtrl.text.trim();
    if ((text.isEmpty && _imageDataList.isEmpty) || _isLoading) return;
    HapticFeedback.mediumImpact();

    if (prefilled == null) _textCtrl.clear();

    final imageDataList = List<String>.from(_imageDataList);
    final imageMimeTypeList = List<String>.from(_imageMimeTypeList);
    final imageData = imageDataList.isNotEmpty ? imageDataList.first : null;
    final imageMimeType =
        imageMimeTypeList.isNotEmpty ? imageMimeTypeList.first : null;

    // Keep a UI-friendly data-url copy for optimistic message rendering.
    final dataUrls = <String>[];
    for (int i = 0; i < imageDataList.length; i++) {
      final mime = i < imageMimeTypeList.length
          ? imageMimeTypeList[i]
          : (imageMimeType ?? 'image/jpeg');
      dataUrls.add('data:$mime;base64,${imageDataList[i]}');
    }

    // Add the user message optimistically
    setState(() {
      _imageDataList.clear();
      _imageMimeTypeList.clear();
      _messages.add(ChatMessage(
        role: 'user',
        content: text,
        imageData: dataUrls.isEmpty
            ? null
            : (dataUrls.length == 1 ? dataUrls.first : jsonEncode(dataUrls)),
        timestamp: DateTime.now(),
      ));
      _isLoading = true;
    });
    _scrollToBottom(animated: false);

    // Add a placeholder assistant message that we'll fill in from the stream
    int assistantMsgIndex = _messages.length;
    setState(() {
      _messages.add(ChatMessage(
        role: 'assistant',
        content: '',
        timestamp: DateTime.now(),
      ));
    });
    _scrollToBottom(animated: false);

    // Buffer streamed token chunks and flush at interval to reduce setState churn.
    final streamBuffer = StringBuffer();
    Timer? flushTimer;

    void flushAssistantBuffer() {
      if (streamBuffer.isEmpty || !mounted) return;
      final chunk = streamBuffer.toString();
      streamBuffer.clear();
      setState(() {
        final old = _messages[assistantMsgIndex];
        _messages[assistantMsgIndex] = ChatMessage(
          id: old.id,
          role: 'assistant',
          content: old.content + chunk,
          imageData: old.imageData,
          timestamp: old.timestamp,
        );
      });
      _scrollToBottom(animated: false);
    }

    try {
      // ── MEMORY: build full in-session history ────────────────────────────
      // At this point _messages = [...prev..., user_msg (just added), assistant_placeholder (just added)]
      // We want history = everything BEFORE those last 2, so the AI recalls the full conversation.
      // Using sublist instead of `id != null` because optimistic messages never get IDs assigned
      // locally — filtering by ID would wipe memory after the very first exchange.
      final historyEnd = _messages.length - 2;
      final history = historyEnd > 0
          ? _messages
              .sublist(0, historyEnd)
              .map((m) => {
                    'role': m.role,
                    // Keep all conversational turns, including image-only turns,
                    // without sending raw base64 blobs in history.
                    'content': m.imageData != null
                        ? (m.content.isEmpty
                            ? '[Image attachment included in this message]'
                            : '${m.content}\n[Image attachment included in this message]')
                        : m.content,
                  })
              .where((m) => (m['content'] ?? '').trim().isNotEmpty)
              .toList()
          : <Map<String, String>>[];

      // Start backend SSE stream.
      final stream = _api.streamChatMessage(
        message: text,
        sessionId: _currentSessionId,
        imageData: imageData,
        imageMimeType: imageMimeType,
        imageDataList: imageDataList,
        imageMimeTypeList: imageMimeTypeList,
        responseMode: _fastResponseMode ? 'fast' : 'detailed',
        history: history,
      );

      await for (final event in stream) {
        if (!mounted) break;
        switch (event) {
          // Meta arrives first with provider + session information.
          case ChatStreamMeta(:final sessionId, :final title, :final provider):
            setState(() {
              _activeProvider = provider ?? 'openai';
              if (_currentSessionId == null) {
                _currentSessionId = sessionId;
                // Add session with 'New Chat' immediately — title updates async below
                _sessions.insert(
                    0,
                    ChatSession(
                      id: sessionId,
                      title: title ?? 'New Chat',
                      createdAt: DateTime.now(),
                    ));
              }
            });

          // Title update arrives asynchronously after backend title generation.
          case ChatStreamTitleUpdate(:final title):
            // Smart title arrived async — update it in the session list in place
            setState(() {
              final idx =
                  _sessions.indexWhere((s) => s.id == _currentSessionId);
              if (idx != -1) {
                _sessions[idx] = ChatSession(
                  id: _sessions[idx].id,
                  title: title,
                  createdAt: _sessions[idx].createdAt,
                );
              }
            });

          // Main token stream: append content incrementally.
          case ChatStreamToken(:final content):
            streamBuffer.write(content);
            // 30ms ≈ ~33 redraws/sec — smooth but less setState pressure
            // than 18ms (55/sec), which was causing image repaints
            flushTimer ??=
                Timer.periodic(const Duration(milliseconds: 30), (_) {
              flushAssistantBuffer();
            });

          // Stream completed by backend.
          case ChatStreamDone():
            flushTimer?.cancel();
            flushAssistantBuffer();
            HapticFeedback.selectionClick();
            setState(() {
              final old = _messages[assistantMsgIndex];
              if (old.content.trim().isEmpty) {
                _messages[assistantMsgIndex] = ChatMessage(
                  id: old.id,
                  role: old.role,
                  content:
                      '⚠️ No response text was streamed. Please send again.',
                  imageData: old.imageData,
                  timestamp: old.timestamp,
                );
              }
              _isLoading = false;
            });
            debugPrint('Response complete. Provider: $_activeProvider');
        }
      }
    } catch (e) {
      debugPrint('Stream error: $e');
      if (mounted) {
        setState(() {
          final old = _messages[assistantMsgIndex];
          _messages[assistantMsgIndex] = ChatMessage(
            id: old.id,
            role: 'assistant',
            content: old.content.isEmpty
                ? '⚠️ Could not connect to AI. Please check your connection and try again.'
                : old.content,
            imageData: old.imageData,
            timestamp: old.timestamp,
          );
          _isLoading = false;
        });
        _showSnackBar('Connection error. Please try again.');
      }
    } finally {
      flushTimer?.cancel();
      flushAssistantBuffer();
      if (mounted && _isLoading) {
        setState(() {
          final old = _messages[assistantMsgIndex];
          if (old.content.trim().isEmpty) {
            _messages[assistantMsgIndex] = ChatMessage(
              id: old.id,
              role: old.role,
              content: '⚠️ Response ended unexpectedly. Please try again.',
              imageData: old.imageData,
              timestamp: old.timestamp,
            );
          }
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    // Gallery supports multi-select; camera is single-capture.
    try {
      List<XFile> picked;
      if (source == ImageSource.gallery) {
        picked = await _picker.pickMultiImage(
          imageQuality: 82,
          maxWidth: 1600,
          maxHeight: 1600,
        );
      } else {
        final single = await _picker.pickImage(
          source: source,
          imageQuality: 82,
          maxWidth: 1600,
          maxHeight: 1600,
        );
        picked = single == null ? <XFile>[] : <XFile>[single];
      }

      if (picked.isEmpty) return;

      final dataToAdd = <String>[];
      final mimeToAdd = <String>[];
      for (final file in picked) {
        final bytes = await file.readAsBytes();
        dataToAdd.add(base64Encode(bytes));
        mimeToAdd.add(file.mimeType ?? _guessMimeType(file.path));
      }
      if (dataToAdd.isEmpty) return;

      HapticFeedback.lightImpact();
      setState(() {
        _imageDataList.addAll(dataToAdd);
        _imageMimeTypeList.addAll(mimeToAdd);
      });
    } catch (e) {
      debugPrint('Image pick error: $e');
      if (mounted) _showSnackBar('Could not access the image. Try again.');
    }
  }

  String _guessMimeType(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  Uint8List? _decodeImageBytes(String? imageData) {
    if (imageData == null || imageData.isEmpty) return null;
    try {
      final first = _extractImageEntries(imageData).firstOrNull;
      if (first == null || first.isEmpty) return null;
      final payload = first.contains(',') ? first.split(',')[1] : first;
      return base64Decode(payload);
    } catch (_) {
      return null;
    }
  }

  List<String> _extractImageEntries(String? raw) {
    // Supports both storage formats:
    // - single data URL string
    // - JSON array string of data URLs
    if (raw == null || raw.trim().isEmpty) return const [];
    final trimmed = raw.trim();
    if (trimmed.startsWith('[')) {
      try {
        final parsed = jsonDecode(trimmed);
        if (parsed is List) {
          return parsed
              .whereType<String>()
              .where((e) => e.trim().isNotEmpty)
              .toList();
        }
      } catch (_) {}
    }
    return [trimmed];
  }

  void _openImagePreview(Uint8List bytes) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.92),
      builder: (_) {
        return Dialog.fullscreen(
          backgroundColor: Colors.transparent,
          child: Stack(
            children: [
              Center(
                child: InteractiveViewer(
                  minScale: 0.8,
                  maxScale: 4,
                  child: Image.memory(bytes, fit: BoxFit.contain),
                ),
              ),
              Positioned(
                top: MediaQuery.of(context).padding.top + 8,
                right: 12,
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded,
                      color: Colors.white, size: 28),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _startNewChat() {
    setState(() {
      _currentSessionId = null;
      _messages = [];
      _showSidebar = false;
      _isStuffView = false;
    });
  }

  void _showSnackBar(String message) {
    HapticFeedback.heavyImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Stack(
      children: [
        AnimatedSwitcher(
          duration: 300.ms,
          child: _isStuffView
              ? _StuffView(
                  key: const ValueKey('stuff'),
                  isDark: isDark,
                  images: _uploadedImages,
                  onBack: () => setState(() => _isStuffView = false),
                  onOpenSession: (sessionId) {
                    _loadMessages(sessionId);
                    setState(() => _isStuffView = false);
                  },
                )
              : Column(
                  key: const ValueKey('chat'),
                  children: [
                    SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: Row(
                          children: [
                            GestureDetector(
                              onTap: () {
                                HapticFeedback.selectionClick();
                                setState(() => _showSidebar = true);
                                _loadSessions();
                              },
                              child: AnimatedScale(
                                duration: 220.ms,
                                curve: Curves.easeOutBack,
                                scale: _showSidebar ? 0.9 : 1,
                                child: AnimatedContainer(
                                  duration: 220.ms,
                                  curve: Curves.easeOutCubic,
                                  width: 46,
                                  height: 46,
                                  decoration: BoxDecoration(
                                    color: isDark
                                        ? Colors.white.withOpacity(0.08)
                                        : Colors.black.withOpacity(0.06),
                                    borderRadius: BorderRadius.circular(23),
                                    border: Border.all(
                                      color:
                                          (isDark ? Colors.white : Colors.black)
                                              .withOpacity(0.1),
                                    ),
                                    boxShadow: _showSidebar
                                        ? [
                                            BoxShadow(
                                              color: Colors.black.withOpacity(
                                                  isDark ? 0.35 : 0.16),
                                              blurRadius: 18,
                                              offset: const Offset(0, 8),
                                            ),
                                          ]
                                        : null,
                                  ),
                                  child: Center(
                                    child: AnimatedRotation(
                                      duration: 260.ms,
                                      curve: Curves.easeOutCubic,
                                      turns: _showSidebar ? 0.125 : 0,
                                      child: Icon(Icons.menu_rounded,
                                          size: 22,
                                          color: isDark
                                              ? AuricTheme.darkText
                                              : AuricTheme.lightText),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            GestureDetector(
                              onTap: widget.onSwitch,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 18, vertical: 10),
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? Colors.white.withOpacity(0.08)
                                      : Colors.black.withOpacity(0.06),
                                  borderRadius: BorderRadius.circular(22),
                                  border: Border.all(
                                    color:
                                        (isDark ? Colors.white : Colors.black)
                                            .withOpacity(0.1),
                                  ),
                                ),
                                child: Text(
                                  'Auric',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: isDark
                                        ? AuricTheme.darkText
                                        : AuricTheme.lightText,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // Main content area: empty-state suggestions or chat message list.
                    Expanded(
                      child: _messages.isEmpty && _currentSessionId == null
                          ? _EmptyState(
                              isDark: isDark,
                              topPadding: 24,
                              onSuggestion: _sendMessage,
                              onCamera: () => _pickImage(ImageSource.camera),
                              onGallery: () => _pickImage(ImageSource.gallery),
                            )
                          : ListView.builder(
                              controller: _scrollCtrl,
                              padding:
                                  const EdgeInsets.fromLTRB(14, 12, 14, 16),
                              itemCount: _messages.length,
                              itemBuilder: (ctx, i) {
                                final msg = _messages[i];
                                final isStreamingAssistant = _isLoading &&
                                    i == _messages.length - 1 &&
                                    msg.role == 'assistant';
                                // Use stable key (role + index, no timestamp)
                                // so existing bubbles don't get recreated on
                                // every streaming setState — this is the core
                                // fix for image flicker.
                                final isNewBubble = i == _messages.length - 1;
                                final bubble = _MessageBubble(
                                  key: ValueKey('${msg.role}_$i'),
                                  message: msg,
                                  isDark: isDark,
                                  isStreaming: isStreamingAssistant,
                                  onImageTap: (rawImage) {
                                    final payload = rawImage.contains(',')
                                        ? rawImage.split(',')[1]
                                        : rawImage;
                                    try {
                                      final bytes = base64Decode(payload);
                                      _openImagePreview(bytes);
                                    } catch (_) {}
                                  },
                                );
                                // Only animate newly appended messages.
                                if (isNewBubble && !_isLoading ||
                                    isNewBubble &&
                                        isStreamingAssistant &&
                                        msg.content.isEmpty) {
                                  return bubble
                                      .animate()
                                      .fadeIn(duration: 200.ms)
                                      .slideY(
                                          begin: 0.02,
                                          curve: Curves.easeOutCubic);
                                }
                                return bubble;
                              },
                            ),
                    ),

                    // Bottom composer with text/image/voice/send controls.
                    _InputBar(
                      controller: _textCtrl,
                      isDark: isDark,
                      hasImage: _imageDataList.isNotEmpty,
                      isLoading: _isLoading,
                      isListening: _isListening,
                      isFastMode: _fastResponseMode,
                      attachedImageDataList: _imageDataList,
                      onSend: _sendMessage,
                      onPickImage: () => _showImagePickerSheet(context),
                      onPreviewImage: (index) {
                        if (index < 0 || index >= _imageDataList.length) return;
                        final bytes = _decodeImageBytes(_imageDataList[index]);
                        if (bytes != null) {
                          _openImagePreview(bytes);
                        }
                      },
                      onToggleMode: () => setState(() {
                        HapticFeedback.selectionClick();
                        _fastResponseMode = !_fastResponseMode;
                      }),
                      onMicTap: _toggleVoiceInput,
                      onClearImage: (index) => setState(() {
                        if (index < 0 || index >= _imageDataList.length) return;
                        _imageDataList.removeAt(index);
                        if (index < _imageMimeTypeList.length) {
                          _imageMimeTypeList.removeAt(index);
                        }
                      }),
                    ),
                  ],
                ),
        ),

        // Session sidebar overlay.
        AnimatedSwitcher(
          duration: 300.ms,
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: _showSidebar
              ? _SessionSidebar(
                  key: const ValueKey('session_sidebar_open'),
                  isDark: isDark,
                  sessions: _sessions,
                  currentSessionId: _currentSessionId,
                  searchQuery: _searchQuery,
                  onSearch: (q) {
                    setState(() => _searchQuery = q);
                    _loadSessions();
                  },
                  onSelectSession: (id) {
                    _loadMessages(id);
                    setState(() => _showSidebar = false);
                  },
                  onNewChat: _startNewChat,
                  onMyStuff: () {
                    setState(() {
                      _showSidebar = false;
                      _isStuffView = true;
                    });
                    _loadImages();
                  },
                  onDeleteSession: (id) async {
                    await _api.deleteSession(id);
                    if (_currentSessionId == id) _startNewChat();
                    _loadSessions();
                  },
                  onRenameSession: (id, title) async {
                    await _api.renameSession(id, title);
                    _loadSessions();
                  },
                  onClose: () => setState(() => _showSidebar = false),
                )
              : const SizedBox.shrink(key: ValueKey('session_sidebar_closed')),
        ),
      ],
    );
  }

  void _showImagePickerSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        return Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1A1A1A) : Colors.white,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: isDark ? Colors.white24 : Colors.black12,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ListTile(
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white10 : Colors.black12,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.camera_alt_rounded,
                      color: isDark ? Colors.white : Colors.black87, size: 20),
                ),
                title: Text('Camera',
                    style: TextStyle(
                        color:
                            isDark ? AuricTheme.darkText : AuricTheme.lightText,
                        fontWeight: FontWeight.w500)),
                onTap: () {
                  HapticFeedback.selectionClick();
                  Navigator.pop(ctx);
                  _pickImage(ImageSource.camera);
                },
              ),
              ListTile(
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white10 : Colors.black12,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.photo_library_rounded,
                      color: isDark ? Colors.white : Colors.black87, size: 20),
                ),
                title: Text('Upload Photo',
                    style: TextStyle(
                        color:
                            isDark ? AuricTheme.darkText : AuricTheme.lightText,
                        fontWeight: FontWeight.w500)),
                onTap: () {
                  HapticFeedback.selectionClick();
                  Navigator.pop(ctx);
                  _pickImage(ImageSource.gallery);
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── My Stuff View ─────────────────────────────────────────

class _StuffView extends StatelessWidget {
  final bool isDark;
  final List<dynamic> images;
  final VoidCallback onBack;
  final Function(String) onOpenSession;

  const _StuffView({
    super.key,
    required this.isDark,
    required this.images,
    required this.onBack,
    required this.onOpenSession,
  });

  Uint8List? _decodeImageBytes(String imageData) {
    if (imageData.isEmpty) return null;
    try {
      String first = imageData;
      final trimmed = imageData.trim();
      if (trimmed.startsWith('[')) {
        final parsed = jsonDecode(trimmed);
        if (parsed is List && parsed.isNotEmpty && parsed.first is String) {
          first = parsed.first as String;
        }
      }
      final payload = first.contains(',') ? first.split(',')[1] : first;
      return base64Decode(payload);
    } catch (_) {
      return null;
    }
  }

  void _showImagePreview(BuildContext context, Uint8List bytes) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.92),
      builder: (_) {
        return Dialog.fullscreen(
          backgroundColor: Colors.transparent,
          child: Stack(
            children: [
              Center(
                child: InteractiveViewer(
                  minScale: 0.8,
                  maxScale: 4,
                  child: Image.memory(bytes, fit: BoxFit.contain),
                ),
              ),
              Positioned(
                top: MediaQuery.of(context).padding.top + 8,
                right: 12,
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded,
                      color: Colors.white, size: 28),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 80, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('My Stuff',
                        style:
                            Theme.of(context).textTheme.headlineLarge?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.5,
                                )),
                    const SizedBox(height: 4),
                    Text('A gallery of your visual explorations.',
                        style: TextStyle(
                            fontSize: 13,
                            color: isDark
                                ? AuricTheme.darkSubtext
                                : AuricTheme.lightSubtext)),
                  ],
                ),
                GestureDetector(
                  onTap: onBack,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withOpacity(0.06)
                          : Colors.black.withOpacity(0.06),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: (isDark ? Colors.white : Colors.black)
                              .withOpacity(0.08)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.chat_bubble_outline_rounded,
                            size: 16,
                            color: isDark
                                ? AuricTheme.darkSubtext
                                : AuricTheme.lightSubtext),
                        const SizedBox(width: 6),
                        Text('Back to chat',
                            style: TextStyle(
                                fontSize: 13,
                                color: isDark
                                    ? AuricTheme.darkSubtext
                                    : AuricTheme.lightSubtext)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Expanded(
              child: images.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.image_outlined,
                              size: 64,
                              color: (isDark ? Colors.white : Colors.black)
                                  .withOpacity(0.1)),
                          const SizedBox(height: 16),
                          Text('Your gallery is currently empty.',
                              style: TextStyle(
                                  color: isDark
                                      ? AuricTheme.darkSubtext
                                      : AuricTheme.lightSubtext,
                                  fontWeight: FontWeight.w500)),
                          const SizedBox(height: 8),
                          GestureDetector(
                            onTap: onBack,
                            child: Text('Start a conversation to add items',
                                style: TextStyle(
                                    color: isDark
                                        ? Colors.white70
                                        : Colors.black54,
                                    fontSize: 13)),
                          ),
                        ],
                      ),
                    )
                  : GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                      ),
                      itemCount: images.length,
                      itemBuilder: (ctx, i) {
                        final img = images[i];
                        final imageDataStr = img['imageData'] as String? ?? '';
                        final sessionId = img['sessionId'] as String? ?? '';
                        final content =
                            img['content'] as String? ?? 'Visual analysis';
                        final imageBytes = _decodeImageBytes(imageDataStr);
                        return GestureDetector(
                          onTap: () => onOpenSession(sessionId),
                          onLongPress: imageBytes == null
                              ? null
                              : () => _showImagePreview(context, imageBytes),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                imageBytes != null
                                    ? Image.memory(
                                        imageBytes,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) => Container(
                                          color: isDark
                                              ? Colors.white12
                                              : Colors.black12,
                                          child: const Icon(
                                              Icons.broken_image_outlined),
                                        ),
                                      )
                                    : Container(
                                        color: isDark
                                            ? Colors.white12
                                            : Colors.black12,
                                        child: const Icon(Icons.image_outlined),
                                      ),
                                Container(
                                  decoration: const BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Colors.transparent,
                                        Colors.black87
                                      ],
                                    ),
                                  ),
                                ),
                                Positioned(
                                  bottom: 10,
                                  left: 10,
                                  right: 10,
                                  child: Text(
                                    content,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                            .animate()
                            .fadeIn(delay: (i * 50).ms)
                            .scale(begin: const Offset(0.95, 0.95));
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Empty State ───────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final bool isDark;
  final double topPadding;
  final Function(String) onSuggestion;
  final VoidCallback onCamera;
  final VoidCallback onGallery;

  const _EmptyState({
    required this.isDark,
    required this.topPadding,
    required this.onSuggestion,
    required this.onCamera,
    required this.onGallery,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(24, topPadding, 24, 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withOpacity(0.15)
                  : Colors.black.withOpacity(0.18),
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.25),
                  blurRadius: 30,
                  offset: const Offset(0, 8),
                )
              ],
            ),
          )
              .animate()
              .fadeIn(delay: 100.ms)
              .scale(begin: const Offset(0.8, 0.8)),
          const SizedBox(height: 16),
          Text('How can I help you today?',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  )).animate().fadeIn(delay: 200.ms),
          const SizedBox(height: 6),
          Text(
            'Auric is your intelligent companion for\nmath, science, and creative exploration.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ).animate().fadeIn(delay: 300.ms),
          const SizedBox(height: 32),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.4,
            children: [
              _QuickActionCard(
                icon: Icons.camera_alt_outlined,
                title: 'Solve from Photo',
                desc: 'Snap homework, graph, or notes',
                isDark: isDark,
                onTap: onCamera,
                delay: 400,
                accent: const Color(0xFF1E8E5A),
              ),
              _QuickActionCard(
                icon: Icons.image_outlined,
                title: 'Read This Image',
                desc: 'Extract values and explain',
                isDark: isDark,
                onTap: onGallery,
                delay: 460,
                accent: const Color(0xFFDB7A17),
              ),
              _QuickActionCard(
                icon: Icons.school_outlined,
                title: 'Explain Simply',
                desc: 'Kid-friendly clear learning',
                isDark: isDark,
                onTap: () => onSuggestion(
                    'Explain this in a very simple way like I am a beginner student.'),
                delay: 520,
                accent: const Color(0xFF5A6EDF),
              ),
              _QuickActionCard(
                icon: Icons.auto_awesome_outlined,
                title: 'Brainstorm',
                desc: 'Explore ideas together',
                isDark: isDark,
                onTap: () =>
                    onSuggestion("Let's brainstorm some new project ideas."),
                delay: 580,
                accent: const Color(0xFFB146B5),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _QuickActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String desc;
  final bool isDark;
  final VoidCallback onTap;
  final int delay;
  final Color accent;

  const _QuickActionCard({
    required this.icon,
    required this.title,
    required this.desc,
    required this.isDark,
    required this.onTap,
    required this.delay,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return _PressableCard(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withOpacity(0.045)
              : Colors.white.withOpacity(0.82),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: (isDark ? Colors.white : Colors.black).withOpacity(0.06),
          ),
          boxShadow: [
            BoxShadow(
              color: (isDark ? Colors.black : Colors.black).withOpacity(0.08),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: accent.withOpacity(isDark ? 0.22 : 0.14),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, color: accent, size: 19),
            ),
            const SizedBox(height: 10),
            Text(
              title,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: isDark ? AuricTheme.darkText : AuricTheme.lightText,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              desc,
              style: TextStyle(
                fontSize: 11,
                color: isDark ? AuricTheme.darkMuted : AuricTheme.lightSubtext,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    ).animate().fadeIn(delay: delay.ms).slideY(begin: 0.1);
  }
}

class _PressableCard extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;

  const _PressableCard({required this.child, required this.onTap});

  @override
  State<_PressableCard> createState() => _PressableCardState();
}

class _PressableCardState extends State<_PressableCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) {
        HapticFeedback.selectionClick();
        setState(() => _pressed = true);
      },
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        scale: _pressed ? 1.03 : 0.98,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: _pressed ? 1 : 0.97,
          child: widget.child,
        ),
      ),
    );
  }
}

// ─── Message Bubble ────────────────────────────────────────

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isDark;
  final bool isStreaming;
  final ValueChanged<String>? onImageTap;

  const _MessageBubble({
    super.key,
    required this.message,
    required this.isDark,
    this.isStreaming = false,
    this.onImageTap,
  });

  String _latexToReadable(String expr) {
    var s = expr.trim();
    s = s.replaceAllMapped(RegExp(r'\\text\{([^}]*)\}'), (m) => m.group(1)!);
    s = s.replaceAllMapped(RegExp(r'\\frac\{([^{}]+)\}\{([^{}]+)\}'),
        (m) => '(${m.group(1)})/(${m.group(2)})');
    s = s.replaceAllMapped(
        RegExp(r'\\sqrt\{([^{}]+)\}'), (m) => 'sqrt(${m.group(1)})');
    s = s.replaceAllMapped(
        RegExp(r'_\{([^{}]+)\}'), (m) => _toSubscript(m.group(1)!));
    s = s.replaceAllMapped(
        RegExp(r'_([A-Za-z0-9()+\-=])'), (m) => _toSubscript(m.group(1)!));
    s = s.replaceAllMapped(
        RegExp(r'\^\{([^{}]+)\}'), (m) => _toSuperscript(m.group(1)!));
    s = s.replaceAllMapped(
        RegExp(r'\^([A-Za-z0-9()+\-=])'), (m) => _toSuperscript(m.group(1)!));
    s = s.replaceAll(r'\cdot', '·');
    s = s.replaceAll(r'\times', '×');
    s = s.replaceAll(r'\Omega', 'Ω');
    s = s.replaceAll(r'\omega', 'ω');
    s = s.replaceAll(r'\gamma', 'γ');
    s = s.replaceAll(r'\alpha', 'α');
    s = s.replaceAll(r'\beta', 'β');
    s = s.replaceAll(r'\theta', 'θ');
    s = s.replaceAll(r'\mu', 'µ');
    s = s.replaceAll('{', '');
    s = s.replaceAll('}', '');
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _toSubscript(String input) {
    const map = {
      '0': '₀',
      '1': '₁',
      '2': '₂',
      '3': '₃',
      '4': '₄',
      '5': '₅',
      '6': '₆',
      '7': '₇',
      '8': '₈',
      '9': '₉',
      '+': '₊',
      '-': '₋',
      '=': '₌',
      '(': '₍',
      ')': '₎',
      'a': 'ₐ',
      'e': 'ₑ',
      'h': 'ₕ',
      'i': 'ᵢ',
      'j': 'ⱼ',
      'k': 'ₖ',
      'l': 'ₗ',
      'm': 'ₘ',
      'n': 'ₙ',
      'o': 'ₒ',
      'p': 'ₚ',
      'r': 'ᵣ',
      's': 'ₛ',
      't': 'ₜ',
      'u': 'ᵤ',
      'v': 'ᵥ',
      'x': 'ₓ',
    };
    final out = StringBuffer();
    for (final rune in input.runes) {
      final ch = String.fromCharCode(rune);
      final key = ch.toLowerCase();
      out.write(map[key] ?? ch);
    }
    return out.toString();
  }

  String _toSuperscript(String input) {
    const map = {
      '0': '⁰',
      '1': '¹',
      '2': '²',
      '3': '³',
      '4': '⁴',
      '5': '⁵',
      '6': '⁶',
      '7': '⁷',
      '8': '⁸',
      '9': '⁹',
      '+': '⁺',
      '-': '⁻',
      '=': '⁼',
      '(': '⁽',
      ')': '⁾',
      'a': 'ᵃ',
      'b': 'ᵇ',
      'c': 'ᶜ',
      'd': 'ᵈ',
      'e': 'ᵉ',
      'f': 'ᶠ',
      'g': 'ᵍ',
      'h': 'ʰ',
      'i': 'ⁱ',
      'j': 'ʲ',
      'k': 'ᵏ',
      'l': 'ˡ',
      'm': 'ᵐ',
      'n': 'ⁿ',
      'o': 'ᵒ',
      'p': 'ᵖ',
      'r': 'ʳ',
      's': 'ˢ',
      't': 'ᵗ',
      'u': 'ᵘ',
      'v': 'ᵛ',
      'w': 'ʷ',
      'x': 'ˣ',
      'y': 'ʸ',
      'z': 'ᶻ',
    };
    final out = StringBuffer();
    for (final rune in input.runes) {
      final ch = String.fromCharCode(rune);
      final key = ch.toLowerCase();
      out.write(map[key] ?? ch);
    }
    return out.toString();
  }

  String _formatForCopy(String input) {
    var out = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    out = out
        .replaceAll('\\[', r'$$')
        .replaceAll('\\]', r'$$')
        .replaceAll('\\(', r'$')
        .replaceAll('\\)', r'$');

    out = out.replaceAllMapped(RegExp(r'\$\$([\s\S]*?)\$\$'),
        (m) => '\n${_latexToReadable(m.group(1) ?? '')}\n');
    out = out.replaceAllMapped(
        RegExp(r'\$([^\n$]+)\$'), (m) => _latexToReadable(m.group(1) ?? ''));

    out = out.replaceAll(RegExp(r'^\s{0,3}#{1,6}\s+', multiLine: true), '');
    out = out.replaceAll('**', '');
    out = out.replaceAll('__', '');
    out = out.replaceAll('`', '');
    out = out
        .replaceAll(r'\_', '_')
        .replaceAll(r'\*', '*')
        .replaceAll(r'\#', '#')
        .replaceAll(r'\[', '[')
        .replaceAll(r'\]', ']')
        .replaceAll(r'\(', '(')
        .replaceAll(r'\)', ')');

    return out.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  Future<void> _copyMessage(BuildContext context) async {
    final text = _formatForCopy(message.content);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Message copied')),
      );
    }
  }

  List<String> _extractImageEntries(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    final trimmed = raw.trim();
    if (trimmed.startsWith('[')) {
      try {
        final parsed = jsonDecode(trimmed);
        if (parsed is List) {
          return parsed
              .whereType<String>()
              .where((e) => e.trim().isNotEmpty)
              .toList();
        }
      } catch (_) {}
    }
    return [trimmed];
  }

  Widget _buildImageTile(String imageRaw) {
    final payload = imageRaw.contains(',') ? imageRaw.split(',')[1] : imageRaw;
    Uint8List? bytes;
    try {
      bytes = base64Decode(payload);
    } catch (_) {
      bytes = null;
    }
    // RepaintBoundary ensures this image widget is isolated on its own
    // compositing layer — streaming setState calls above it won't repaint it.
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: bytes != null
            ? Image.memory(
                bytes,
                width: 92,
                height: 92,
                fit: BoxFit.cover,
                gaplessPlayback: true, // prevents flicker on rebuild
                errorBuilder: (_, __, ___) => Container(
                  width: 92,
                  height: 92,
                  color: isDark ? Colors.white10 : Colors.black12,
                  child: const Icon(Icons.broken_image_outlined),
                ),
              )
            : Container(
                width: 92,
                height: 92,
                color: isDark ? Colors.white10 : Colors.black12,
                child: const Icon(Icons.broken_image_outlined),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    final textColor = isDark ? AuricTheme.darkText : AuricTheme.lightText;
    final imageEntries = _extractImageEntries(message.imageData);

    if (isUser) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Align(
          alignment: Alignment.centerRight,
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.74),
            child: GestureDetector(
              onLongPress: message.content.trim().isEmpty
                  ? null
                  : () => _copyMessage(context),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.black.withOpacity(0.35)
                      : Colors.black.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: (isDark ? Colors.white : Colors.black)
                        .withOpacity(0.08),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (imageEntries.isNotEmpty) ...[
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: imageEntries.indexed.map((entry) {
                          final (_, img) = entry;
                          return GestureDetector(
                            onTap: onImageTap == null
                                ? null
                                : () => onImageTap!(img),
                            child: Stack(
                              children: [
                                _buildImageTile(img),
                                // Subtle tap-to-view overlay hint
                                Positioned(
                                  bottom: 4,
                                  right: 4,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 5, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withOpacity(0.45),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Icon(Icons.zoom_in_rounded,
                                        size: 12, color: Colors.white),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                      if (message.content.trim().isNotEmpty)
                        const SizedBox(height: 8),
                    ],
                    if (message.content.trim().isNotEmpty)
                      SelectableText(
                        message.content,
                        style: TextStyle(
                            color: textColor, fontSize: 16, height: 1.45),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.9),
          child: GestureDetector(
            onLongPress: message.content.trim().isEmpty
                ? null
                : () => _copyMessage(context),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(2, 2, 2, 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (imageEntries.isNotEmpty) ...[
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: imageEntries.indexed.map((entry) {
                        final (_, img) = entry;
                        return GestureDetector(
                          onTap: onImageTap == null
                              ? null
                              : () => onImageTap!(img),
                          child: Stack(
                            children: [
                              _buildImageTile(img),
                              Positioned(
                                bottom: 4,
                                right: 4,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 5, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(0.45),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Icon(Icons.zoom_in_rounded,
                                      size: 12, color: Colors.white),
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (message.content.isEmpty && isStreaming)
                    _StreamingCursor(isDark: isDark)
                  else if (message.content.isNotEmpty)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        isStreaming
                            ? _StreamingRichText(
                                text: message.content,
                                isDark: isDark,
                              )
                            : _MathMarkdownRenderer(
                                text: message.content,
                                isDark: isDark,
                              ),
                        if (isStreaming)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: _StreamingCursor(isDark: isDark),
                          ),
                        if (!isStreaming) ...[
                          const SizedBox(height: 2),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: () => _copyMessage(context),
                              icon: Icon(Icons.copy_rounded,
                                  size: 16,
                                  color: isDark
                                      ? AuricTheme.darkSubtext
                                      : AuricTheme.lightSubtext),
                              label: Text(
                                'Copy',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: isDark
                                      ? AuricTheme.darkSubtext
                                      : AuricTheme.lightSubtext,
                                ),
                              ),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Streaming Cursor ──────────────────────────────────────

class _StreamingCursor extends StatefulWidget {
  final bool isDark;
  const _StreamingCursor({required this.isDark});

  @override
  State<_StreamingCursor> createState() => _StreamingCursorState();
}

class _StreamingCursorState extends State<_StreamingCursor>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: 600.ms)
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Container(
        width: 2,
        height: 16,
        decoration: BoxDecoration(
          color: (widget.isDark ? Colors.white : Colors.black)
              .withOpacity(0.45 + _ctrl.value * 0.45),
          borderRadius: BorderRadius.circular(1),
        ),
      ),
    );
  }
}

// ─── Streaming Rich Text (lightweight, token-friendly) ─────

class _StreamingRichText extends StatelessWidget {
  final String text;
  final bool isDark;

  const _StreamingRichText({required this.text, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? AuricTheme.darkText : AuricTheme.lightText;
    final highlightColor = textColor;

    return SelectableText.rich(
      TextSpan(
        style: TextStyle(fontSize: 15, height: 1.5, color: textColor),
        children: _buildHighlightedSpans(
          text,
          baseColor: textColor,
          highlightColor: highlightColor,
        ),
      ),
    );
  }

  List<InlineSpan> _buildHighlightedSpans(
    String input, {
    required Color baseColor,
    required Color highlightColor,
  }) {
    final spans = <InlineSpan>[];
    final regex = RegExp(r'\*\*(.+?)\*\*', dotAll: true);
    int lastEnd = 0;

    for (final m in regex.allMatches(input)) {
      if (m.start > lastEnd) {
        spans.add(TextSpan(text: input.substring(lastEnd, m.start)));
      }
      final highlighted = m.group(1) ?? '';
      spans.add(TextSpan(
        text: highlighted,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          color: highlightColor,
        ),
      ));
      lastEnd = m.end;
    }

    if (lastEnd < input.length) {
      spans.add(TextSpan(text: input.substring(lastEnd)));
    }

    if (spans.isEmpty) {
      spans.add(TextSpan(text: input, style: TextStyle(color: baseColor)));
    }

    return spans;
  }
}

// ─── Math + Markdown Renderer ──────────────────────────────
//
// Parses the AI text and renders:
//   $$...$$ → display/block math (boxed, centred)
//   $...$   → inline math (rendered inline with text)
//   rest    → normal Markdown via MarkdownBody

class _MathMarkdownRenderer extends StatelessWidget {
  final String text;
  final bool isDark;

  const _MathMarkdownRenderer({
    required this.text,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final normalized = _normalizeMathDelimiters(text);
    final segments = _parse(normalized);
    final textColor = isDark ? AuricTheme.darkText : AuricTheme.lightText;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: segments.map((seg) {
        switch (seg.type) {
          // ── Display / block math: $$...$$  ────────────────
          case _SegType.blockMath:
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Math.tex(
                  seg.content,
                  textStyle: TextStyle(fontSize: 24, color: textColor),
                  onErrorFallback: (_) => SelectableText(
                    seg.content,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 15,
                      color: textColor,
                    ),
                  ),
                ),
              ),
            );

          // ── Inline math: $...$  ───────────────────────────
          case _SegType.inlineMath:
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Math.tex(
                seg.content,
                textStyle: TextStyle(fontSize: 18, color: textColor),
                onErrorFallback: (_) => Text(
                  '\$${seg.content}\$',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 15,
                    color: textColor,
                  ),
                ),
              ),
            );

          // ── Plain Markdown  ───────────────────────────────
          case _SegType.markdown:
            if (seg.content.trim().isEmpty) return const SizedBox.shrink();
            final cleanedMarkdown = _cleanupMarkdownNoise(seg.content);
            return MarkdownBody(
              selectable: true,
              data: cleanedMarkdown,
              softLineBreak: true,
              styleSheet: MarkdownStyleSheet(
                p: TextStyle(fontSize: 16, height: 1.68, color: textColor),
                h1: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                    color: textColor),
                h2: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                    color: textColor),
                h3: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                    color: textColor),
                h1Padding: const EdgeInsets.only(top: 12, bottom: 8),
                h2Padding: const EdgeInsets.only(top: 10, bottom: 7),
                h3Padding: const EdgeInsets.only(top: 8, bottom: 6),
                strong: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: textColor,
                ),
                em: TextStyle(fontStyle: FontStyle.italic, color: textColor),
                code: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  backgroundColor: isDark
                      ? Colors.white.withOpacity(0.08)
                      : Colors.black.withOpacity(0.06),
                  color: textColor,
                ),
                codeblockDecoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withOpacity(0.05)
                      : Colors.black.withOpacity(0.04),
                  borderRadius: BorderRadius.circular(10),
                ),
                codeblockPadding: const EdgeInsets.all(10),
                listBullet: TextStyle(color: textColor),
                listIndent: 22,
                blockSpacing: 10,
                blockquoteDecoration: BoxDecoration(
                  color:
                      (isDark ? Colors.white : Colors.black).withOpacity(0.05),
                  borderRadius: BorderRadius.circular(4),
                  border: Border(
                    left: BorderSide(
                      color: (isDark ? Colors.white : Colors.black)
                          .withOpacity(0.35),
                      width: 3,
                    ),
                  ),
                ),
                tableHead: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
                tableBody: TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: textColor,
                ),
                tableBorder: TableBorder.all(
                  color:
                      (isDark ? Colors.white : Colors.black).withOpacity(0.14),
                  width: 0.8,
                ),
                tableCellsPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
            );
        }
      }).toList(),
    );
  }

  String _normalizeMathDelimiters(String input) {
    return input
        .replaceAll('\\[', r'$$')
        .replaceAll('\\]', r'$$')
        .replaceAll('\\(', r'$')
        .replaceAll('\\)', r'$');
  }

  String _cleanupMarkdownNoise(String input) {
    return input
        .replaceAll(r'\_', '_')
        .replaceAll(r'\*', '*')
        .replaceAll(r'\#', '#')
        .replaceAll(r'\[', '[')
        .replaceAll(r'\]', ']')
        .replaceAll(r'\(', '(')
        .replaceAll(r'\)', ')');
  }

  // ignore: unused_element
  String _latexInlineToReadable(String expr) {
    var s = expr.trim();
    s = s.replaceAllMapped(RegExp(r'\\text\{([^}]*)\}'), (m) => m.group(1)!);
    s = s.replaceAllMapped(RegExp(r'\\frac\{([^{}]+)\}\{([^{}]+)\}'),
        (m) => '(${m.group(1)})/(${m.group(2)})');
    s = s.replaceAllMapped(
        RegExp(r'\\sqrt\{([^{}]+)\}'), (m) => 'sqrt(${m.group(1)})');
    s = s.replaceAllMapped(
        RegExp(r'_\{([^{}]+)\}'), (m) => _toSubscript(m.group(1)!));
    s = s.replaceAllMapped(
        RegExp(r'_([A-Za-z0-9()+\-=])'), (m) => _toSubscript(m.group(1)!));
    s = s.replaceAllMapped(
        RegExp(r'\^\{([^{}]+)\}'), (m) => _toSuperscript(m.group(1)!));
    s = s.replaceAllMapped(
        RegExp(r'\^([A-Za-z0-9()+\-=])'), (m) => _toSuperscript(m.group(1)!));
    s = s.replaceAll(r'\cdot', '·');
    s = s.replaceAll(r'\times', '×');
    s = s.replaceAll(r'\Omega', 'Ω');
    s = s.replaceAll(r'\omega', 'ω');
    s = s.replaceAll(r'\gamma', 'γ');
    s = s.replaceAll(r'\alpha', 'α');
    s = s.replaceAll(r'\beta', 'β');
    s = s.replaceAll(r'\theta', 'θ');
    s = s.replaceAll(r'\mu', 'µ');
    s = s.replaceAll('{', '');
    s = s.replaceAll('}', '');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  String _toSubscript(String input) {
    const map = {
      '0': '₀',
      '1': '₁',
      '2': '₂',
      '3': '₃',
      '4': '₄',
      '5': '₅',
      '6': '₆',
      '7': '₇',
      '8': '₈',
      '9': '₉',
      '+': '₊',
      '-': '₋',
      '=': '₌',
      '(': '₍',
      ')': '₎',
      'a': 'ₐ',
      'e': 'ₑ',
      'h': 'ₕ',
      'i': 'ᵢ',
      'j': 'ⱼ',
      'k': 'ₖ',
      'l': 'ₗ',
      'm': 'ₘ',
      'n': 'ₙ',
      'o': 'ₒ',
      'p': 'ₚ',
      'r': 'ᵣ',
      's': 'ₛ',
      't': 'ₜ',
      'u': 'ᵤ',
      'v': 'ᵥ',
      'x': 'ₓ',
    };
    final out = StringBuffer();
    for (final rune in input.runes) {
      final ch = String.fromCharCode(rune);
      final key = ch.toLowerCase();
      out.write(map[key] ?? ch);
    }
    return out.toString();
  }

  String _toSuperscript(String input) {
    const map = {
      '0': '⁰',
      '1': '¹',
      '2': '²',
      '3': '³',
      '4': '⁴',
      '5': '⁵',
      '6': '⁶',
      '7': '⁷',
      '8': '⁸',
      '9': '⁹',
      '+': '⁺',
      '-': '⁻',
      '=': '⁼',
      '(': '⁽',
      ')': '⁾',
      'a': 'ᵃ',
      'b': 'ᵇ',
      'c': 'ᶜ',
      'd': 'ᵈ',
      'e': 'ᵉ',
      'f': 'ᶠ',
      'g': 'ᵍ',
      'h': 'ʰ',
      'i': 'ⁱ',
      'j': 'ʲ',
      'k': 'ᵏ',
      'l': 'ˡ',
      'm': 'ᵐ',
      'n': 'ⁿ',
      'o': 'ᵒ',
      'p': 'ᵖ',
      'r': 'ʳ',
      's': 'ˢ',
      't': 'ᵗ',
      'u': 'ᵘ',
      'v': 'ᵛ',
      'w': 'ʷ',
      'x': 'ˣ',
      'y': 'ʸ',
      'z': 'ᶻ',
    };
    final out = StringBuffer();
    for (final rune in input.runes) {
      final ch = String.fromCharCode(rune);
      final key = ch.toLowerCase();
      out.write(map[key] ?? ch);
    }
    return out.toString();
  }

  /// Splits [input] into typed segments: blockMath ($$), inlineMath ($), markdown.
  ///
  /// Rules (in priority order):
  ///  1. \$\$ ... \$\$  → blockMath   (display equation, rendered in a box)
  ///  2. \$ ... \$     → inlineMath  (inline equation, rendered inline)
  ///  3. everything else → markdown
  ///
  /// Unclosed delimiters fall back to plain markdown text.
  List<_Segment> _parse(String input) {
    final segments = <_Segment>[];
    final buf = StringBuffer();
    int i = 0;

    void flushBuf() {
      if (buf.isNotEmpty) {
        segments.add(_Segment(_SegType.markdown, buf.toString()));
        buf.clear();
      }
    }

    while (i < input.length) {
      final c = input[i];

      // ── Block math: $$ ... $$ ──────────────────────────────
      if (c == r'$' && i + 1 < input.length && input[i + 1] == r'$') {
        final closeIdx = input.indexOf('\$\$', i + 2);
        if (closeIdx == -1) {
          // No closing $$ — treat as plain text
          buf.write(input.substring(i));
          i = input.length;
        } else {
          flushBuf();
          final expr = input.substring(i + 2, closeIdx).trim();
          if (expr.isNotEmpty) segments.add(_Segment(_SegType.blockMath, expr));
          i = closeIdx + 2;
        }
      }

      // ── Inline math: $ ... $ ───────────────────────────────
      else if (c == r'$') {
        final closeIdx = input.indexOf(r'$', i + 1);
        // closeIdx == -1 → no closing $, treat as text
        // closeIdx == i + 1 → $$ which means block math was already handled; lone $ here
        if (closeIdx <= i + 1) {
          buf.write(c);
          i++;
        } else {
          final expr = input.substring(i + 1, closeIdx);
          if (expr.contains('\n') || expr.trim().isEmpty) {
            buf.write('\$$expr\$');
          } else {
            flushBuf();
            segments.add(_Segment(_SegType.inlineMath, expr.trim()));
          }
          i = closeIdx + 1;
        }
      }

      // ── Regular character ──────────────────────────────────
      else {
        buf.write(c);
        i++;
      }
    }

    flushBuf();
    return segments;
  }
}

enum _SegType { blockMath, inlineMath, markdown }

class _Segment {
  final _SegType type;
  final String content;
  const _Segment(this.type, this.content);
}

class _ListeningWaves extends StatefulWidget {
  final Color color;
  const _ListeningWaves({required this.color});

  @override
  State<_ListeningWaves> createState() => _ListeningWavesState();
}

class _ListeningWavesState extends State<_ListeningWaves>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 22,
      height: 22,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (_, __) {
          final t = _controller.value * 2 * math.pi;
          double h(double phase) => 6 + (8 * (math.sin(t + phase)).abs());
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _waveBar(h(0), widget.color),
              _waveBar(h(1.6), widget.color),
              _waveBar(h(3.2), widget.color),
            ],
          );
        },
      ),
    );
  }

  Widget _waveBar(double height, Color color) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 90),
      width: 3,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}

// ─── Input Bar ─────────────────────────────────────────────

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final bool isDark;
  final bool hasImage;
  final bool isLoading;
  final bool isListening;
  final bool isFastMode;
  final List<String> attachedImageDataList;
  final VoidCallback onSend;
  final VoidCallback onPickImage;
  final ValueChanged<int> onPreviewImage;
  final VoidCallback onMicTap;
  final VoidCallback onToggleMode;
  final ValueChanged<int> onClearImage;

  const _InputBar({
    required this.controller,
    required this.isDark,
    required this.hasImage,
    required this.isLoading,
    required this.isListening,
    required this.isFastMode,
    required this.attachedImageDataList,
    required this.onSend,
    required this.onPickImage,
    required this.onPreviewImage,
    required this.onMicTap,
    required this.onToggleMode,
    required this.onClearImage,
  });

  Uint8List? _tryDecodeImage(String? data) {
    if (data == null || data.isEmpty) return null;
    try {
      return base64Decode(data.contains(',') ? data.split(',')[1] : data);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      color: Colors.transparent,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            if (hasImage)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SizedBox(
                  height: 50,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: attachedImageDataList.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, i) {
                      final previewBytes =
                          _tryDecodeImage(attachedImageDataList[i]);
                      return GestureDetector(
                        onTap: () => onPreviewImage(i),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 6),
                          decoration: BoxDecoration(
                            color: isDark
                                ? Colors.white.withOpacity(0.08)
                                : Colors.black.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: previewBytes == null
                                    ? Container(
                                        width: 30,
                                        height: 30,
                                        color: AuricTheme.brandBlue
                                            .withOpacity(0.08),
                                        child: const Icon(Icons.image_rounded,
                                            size: 14, color: Colors.white70),
                                      )
                                    : Image.memory(
                                        previewBytes,
                                        width: 30,
                                        height: 30,
                                        fit: BoxFit.cover,
                                      ),
                              ),
                              const SizedBox(width: 8),
                              Text('Image ${i + 1}',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: isDark
                                          ? Colors.white
                                          : Colors.black87,
                                      fontWeight: FontWeight.w700)),
                              const SizedBox(width: 6),
                              GestureDetector(
                                onTap: () => onClearImage(i),
                                child: Icon(Icons.close_rounded,
                                    size: 14,
                                    color: isDark
                                        ? Colors.white70
                                        : Colors.black54),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: keyboardOpen
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          GestureDetector(
                            onTap: onToggleMode,
                            child: AnimatedContainer(
                              duration: 180.ms,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? Colors.white
                                        .withOpacity(isFastMode ? 0.12 : 0.07)
                                    : Colors.black
                                        .withOpacity(isFastMode ? 0.10 : 0.06),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: (isDark ? Colors.white : Colors.black)
                                      .withOpacity(isFastMode ? 0.24 : 0.12),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    isFastMode
                                        ? Icons.flash_on_rounded
                                        : Icons.menu_book_rounded,
                                    size: 14,
                                    color:
                                        isDark ? Colors.white : Colors.black87,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    isFastMode ? 'Fast mode' : 'Detailed mode',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: isDark
                                          ? Colors.white
                                          : Colors.black87,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: AnimatedScale(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    scale: keyboardOpen ? 1.015 : 1.0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withOpacity(0.07)
                            : Colors.black.withOpacity(0.045),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: (isDark ? Colors.white : Colors.black)
                              .withOpacity(keyboardOpen ? 0.18 : 0.08),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          GestureDetector(
                            onTap: onPickImage,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                              child: Icon(
                                Icons.add_circle_outline_rounded,
                                size: 22,
                                color: hasImage
                                    ? (isDark ? Colors.white : Colors.black87)
                                    : (isDark
                                        ? AuricTheme.darkSubtext
                                        : AuricTheme.lightSubtext),
                              ),
                            ),
                          ),
                          Expanded(
                            child: TextField(
                              controller: controller,
                              maxLines: 5,
                              minLines: 1,
                              textCapitalization: TextCapitalization.sentences,
                              style: TextStyle(
                                color: isDark
                                    ? AuricTheme.darkText
                                    : AuricTheme.lightText,
                                fontSize: 15,
                              ),
                              decoration: InputDecoration(
                                hintText: 'Ask Auric anything...',
                                hintStyle: TextStyle(
                                  color: isDark
                                      ? AuricTheme.darkMuted
                                      : AuricTheme.lightSubtext,
                                  fontSize: 15,
                                ),
                                border: InputBorder.none,
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 4, vertical: 10),
                              ),
                              onSubmitted: (_) => onSend(),
                            ),
                          ),
                          GestureDetector(
                            onTap: isLoading ? null : onMicTap,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(4, 10, 8, 10),
                              child: isListening
                                  ? const _ListeningWaves(color: Colors.white)
                                  : Icon(
                                      Icons.mic_none_rounded,
                                      size: 22,
                                      color: isDark
                                          ? AuricTheme.darkMuted
                                          : AuricTheme.lightSubtext,
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),

                // Send button
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller,
                  builder: (_, value, __) {
                    final hasText = value.text.trim().isNotEmpty;
                    final canSend = !isLoading && (hasText || hasImage);
                    return GestureDetector(
                      onTap: canSend ? onSend : null,
                      child: AnimatedScale(
                        duration: 180.ms,
                        curve: Curves.easeOutCubic,
                        scale: canSend ? 1 : 0.96,
                        child: AnimatedContainer(
                          duration: 200.ms,
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: canSend
                                ? (isDark ? Colors.white : Colors.black87)
                                : (isDark ? Colors.white12 : Colors.black12),
                            borderRadius: BorderRadius.circular(14),
                            boxShadow: !canSend
                                ? []
                                : [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.2),
                                      blurRadius: 12,
                                      offset: const Offset(0, 4),
                                    )
                                  ],
                          ),
                          child: isLoading
                              ? const Center(
                                  child: SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white),
                                  ),
                                )
                              : Icon(Icons.arrow_upward_rounded,
                                  color: canSend
                                      ? (isDark ? Colors.black : Colors.white)
                                      : (isDark
                                          ? AuricTheme.darkMuted
                                          : AuricTheme.lightSubtext),
                                  size: 22),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Session Sidebar ───────────────────────────────────────

class _SessionSidebar extends StatelessWidget {
  final bool isDark;
  final List<ChatSession> sessions;
  final String? currentSessionId;
  final String searchQuery;
  final Function(String) onSearch;
  final Function(String) onSelectSession;
  final VoidCallback onNewChat;
  final VoidCallback onMyStuff;
  final Function(String) onDeleteSession;
  final Function(String, String) onRenameSession;
  final VoidCallback onClose;

  const _SessionSidebar({
    super.key,
    required this.isDark,
    required this.sessions,
    required this.currentSessionId,
    required this.searchQuery,
    required this.onSearch,
    required this.onSelectSession,
    required this.onNewChat,
    required this.onMyStuff,
    required this.onDeleteSession,
    required this.onRenameSession,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        GestureDetector(
          onTap: onClose,
          child: Container(color: Colors.black.withOpacity(0.5))
              .animate()
              .fadeIn(duration: 220.ms, curve: Curves.easeOutCubic),
        ),
        Container(
          width: MediaQuery.of(context).size.width * 0.82,
          height: double.infinity,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF111111) : const Color(0xFFF9FAFB),
            border: Border(
              right: BorderSide(
                color: (isDark ? Colors.white : Colors.black).withOpacity(0.08),
              ),
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                // Header
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: isDark
                              ? Colors.white.withOpacity(0.14)
                              : Colors.black.withOpacity(0.18),
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text('Auric',
                          style: Theme.of(context)
                              .textTheme
                              .headlineMedium
                              ?.copyWith(fontSize: 20)),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: onClose,
                        color: isDark
                            ? AuricTheme.darkSubtext
                            : AuricTheme.lightSubtext,
                        iconSize: 22,
                      ),
                    ],
                  ),
                ).animate().fadeIn(duration: 220.ms).slideX(begin: -0.04),

                // Search
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: TextField(
                    onChanged: onSearch,
                    style: TextStyle(
                        fontSize: 14,
                        color: isDark
                            ? AuricTheme.darkText
                            : AuricTheme.lightText),
                    decoration: InputDecoration(
                      hintText: 'Search for chats',
                      hintStyle: TextStyle(
                          fontSize: 14,
                          color: isDark
                              ? AuricTheme.darkMuted
                              : AuricTheme.lightSubtext),
                      prefixIcon: Icon(Icons.search_rounded,
                          size: 18,
                          color: isDark
                              ? AuricTheme.darkMuted
                              : AuricTheme.lightSubtext),
                      filled: true,
                      fillColor: isDark
                          ? Colors.white.withOpacity(0.05)
                          : Colors.black.withOpacity(0.05),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                )
                    .animate(delay: 70.ms)
                    .fadeIn(duration: 220.ms)
                    .slideX(begin: -0.05),

                // New Chat
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: GestureDetector(
                    onTap: onNewChat,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withOpacity(0.08)
                            : Colors.black.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: (isDark ? Colors.white : Colors.black)
                                .withOpacity(0.12)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.add_rounded,
                              color: isDark ? Colors.white : Colors.black87,
                              size: 20),
                          const SizedBox(width: 8),
                          Text('New chat',
                              style: TextStyle(
                                  color: isDark ? Colors.white : Colors.black87,
                                  fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ),
                )
                    .animate(delay: 110.ms)
                    .fadeIn(duration: 220.ms)
                    .slideX(begin: -0.05),

                // My Stuff button
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: GestureDetector(
                    onTap: onMyStuff,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withOpacity(0.05)
                            : Colors.black.withOpacity(0.04),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: (isDark ? Colors.white : Colors.black)
                                .withOpacity(0.06)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.image_outlined,
                              color: isDark
                                  ? AuricTheme.darkSubtext
                                  : AuricTheme.lightSubtext,
                              size: 20),
                          const SizedBox(width: 8),
                          Text('My stuff',
                              style: TextStyle(
                                  color: isDark
                                      ? AuricTheme.darkSubtext
                                      : AuricTheme.lightSubtext,
                                  fontWeight: FontWeight.w500)),
                          const Spacer(),
                          Icon(Icons.arrow_forward_ios_rounded,
                              size: 12,
                              color: isDark
                                  ? AuricTheme.darkMuted
                                  : AuricTheme.lightSubtext),
                        ],
                      ),
                    ),
                  ),
                )
                    .animate(delay: 140.ms)
                    .fadeIn(duration: 220.ms)
                    .slideX(begin: -0.05),

                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
                  child: Row(
                    children: [
                      Text(
                        'RECENT HISTORY',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.2,
                            color: isDark
                                ? AuricTheme.darkMuted
                                : AuricTheme.lightSubtext),
                      ),
                    ],
                  ),
                ).animate(delay: 170.ms).fadeIn(duration: 200.ms),

                // Sessions list
                Expanded(
                  child: sessions.isEmpty
                      ? Center(
                          child: Text('No chats yet',
                              style: TextStyle(
                                  color: isDark
                                      ? AuricTheme.darkMuted
                                      : AuricTheme.lightSubtext,
                                  fontSize: 13)))
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 4),
                          itemCount: sessions.length,
                          itemBuilder: (ctx, i) {
                            final s = sessions[i];
                            final isSelected = s.id == currentSessionId;
                            return ListTile(
                              selected: isSelected,
                              selectedTileColor:
                                  (isDark ? Colors.white : Colors.black)
                                      .withOpacity(0.09),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                              leading: Icon(
                                Icons.chat_bubble_outline_rounded,
                                size: 18,
                                color: isSelected
                                    ? (isDark ? Colors.white : Colors.black87)
                                    : (isDark
                                        ? AuricTheme.darkSubtext
                                        : AuricTheme.lightSubtext),
                              ),
                              title: Text(
                                s.title,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: isSelected
                                      ? FontWeight.w700
                                      : FontWeight.w400,
                                  color: isSelected
                                      ? (isDark ? Colors.white : Colors.black87)
                                      : (isDark
                                          ? AuricTheme.darkText
                                          : AuricTheme.lightText),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                DateFormat('MMM d').format(s.createdAt),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: isDark
                                      ? AuricTheme.darkMuted
                                      : AuricTheme.lightSubtext,
                                ),
                              ),
                              trailing: PopupMenuButton(
                                icon: Icon(Icons.more_vert_rounded,
                                    size: 16,
                                    color: isDark
                                        ? AuricTheme.darkMuted
                                        : AuricTheme.lightSubtext),
                                itemBuilder: (_) => [
                                  const PopupMenuItem(
                                      value: 'rename',
                                      child: Row(children: [
                                        Icon(Icons.edit_rounded, size: 16),
                                        SizedBox(width: 8),
                                        Text('Rename')
                                      ])),
                                  const PopupMenuItem(
                                      value: 'delete',
                                      child: Row(children: [
                                        Icon(Icons.delete_outline_rounded,
                                            size: 16, color: Colors.red),
                                        SizedBox(width: 8),
                                        Text('Delete',
                                            style: TextStyle(color: Colors.red))
                                      ])),
                                ],
                                onSelected: (v) async {
                                  if (v == 'delete') {
                                    onDeleteSession(s.id);
                                  } else if (v == 'rename') {
                                    final ctrl =
                                        TextEditingController(text: s.title);
                                    final newTitle = await showDialog<String>(
                                      context: ctx,
                                      builder: (_) => AlertDialog(
                                        title: const Text('Rename chat'),
                                        content: TextField(controller: ctrl),
                                        actions: [
                                          TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(ctx),
                                              child: const Text('Cancel')),
                                          TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(ctx, ctrl.text),
                                              child: const Text('Save')),
                                        ],
                                      ),
                                    );
                                    if (newTitle != null &&
                                        newTitle.trim().isNotEmpty) {
                                      onRenameSession(s.id, newTitle.trim());
                                    }
                                  }
                                },
                              ),
                              onTap: () => onSelectSession(s.id),
                            )
                                .animate(
                                    delay: Duration(milliseconds: 180 + i * 24))
                                .fadeIn(duration: 220.ms)
                                .slideX(
                                    begin: -0.06, curve: Curves.easeOutCubic);
                          },
                        ),
                ),
              ],
            ),
          ),
        )
            .animate()
            .slideX(
              begin: -0.22,
              end: 0,
              duration: 300.ms,
              curve: Curves.easeOutCubic,
            )
            .fadeIn(duration: 220.ms),
      ],
    );
  }
}
