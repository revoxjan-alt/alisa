import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() => runApp(const AlisaApp());

class AlisaApp extends StatelessWidget {
  const AlisaApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Alisa',
        theme: ThemeData(
          colorSchemeSeed: Colors.deepPurple,
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        home: const HomePage(),
      );
}

class BytesSource extends StreamAudioSource {
  final Uint8List bytes;
  BytesSource(this.bytes);
  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    start ??= 0;
    end ??= bytes.length;
    return StreamAudioResponse(
      sourceLength: bytes.length,
      contentLength: end - start,
      offset: start,
      stream: Stream.value(bytes.sublist(start, end)),
      contentType: 'audio/wav',
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _sys =
      'Sening isming Alisa. Sen o\'zbek tilida suhbatlashadigan aqlli, samimiy ovozli yordamchisan. '
      'Javoblaring ovozda o\'qiladi, shuning uchun qisqa (1-3 gap), tabiiy so\'zlashuv uslubida yoz. '
      'Emoji, ro\'yxat, yulduzcha va markdown ishlatma. Foydalanuvchi qaysi tilda gapirsa, o\'sha tilda javob ber, '
      'odatda o\'zbekcha.';

  final _stt = SpeechToText();
  final _music = AudioPlayer();
  final _voice = AudioPlayer();
  final _yt = YoutubeExplode();
  final List<Map<String, dynamic>> _history = [];
  final List<String> _log = [];
  final _scroll = ScrollController();

  String _apiKey = '';
  String? _locale;
  bool _on = false, _busy = false, _awaiting = false, _sttReady = false;
  DateTime _awaitUntil = DateTime(2000);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final p = await SharedPreferences.getInstance();
    _apiKey = p.getString('gemini_key') ?? '';
    _sttReady = await _stt.initialize(
      onStatus: (s) {
        if (s == 'done' || s == 'notListening') _restart();
      },
      onError: (_) => _restart(),
    );
    final locs = await _stt.locales();
    for (final l in locs) {
      if (l.localeId.toLowerCase().startsWith('uz')) {
        _locale = l.localeId;
        break;
      }
    }
    if (!_sttReady) _addLog('Mikrofon ruxsati yoki ovoz tanish xizmati yo\'q.');
    if (_apiKey.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _settings());
    }
    setState(() {});
  }

  void _addLog(String s) {
    if (!mounted) return;
    setState(() => _log.add(s));
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  void _toggle() {
    if (_apiKey.isEmpty) {
      _settings();
      return;
    }
    setState(() => _on = !_on);
    if (_on) {
      _listen();
    } else {
      _stt.stop();
      _music.stop();
    }
  }

  void _restart() {
    if (_on && !_busy) Future.delayed(const Duration(milliseconds: 400), _listen);
  }

  Future<void> _listen() async {
    if (!_on || _busy || !_sttReady || _stt.isListening) return;
    try {
      await _stt.listen(
        onResult: (r) {
          if (!r.finalResult) return;
          final t = r.recognizedWords.trim();
          if (t.isNotEmpty) _handle(t);
        },
        localeId: _locale,
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 3),
        listenOptions: SpeechListenOptions(partialResults: false, cancelOnError: false),
      );
    } catch (_) {}
  }

  Future<void> _handle(String raw) async {
    if (_busy) return;
    final m = RegExp(r'^\s*(alisa|alissa|alis|elisa|alice|алиса)[\s,.!?]*',
            caseSensitive: false)
        .firstMatch(raw);
    String cmd;
    if (m != null) {
      cmd = raw.substring(m.end).trim();
    } else if (_awaiting && DateTime.now().isBefore(_awaitUntil)) {
      cmd = raw;
    } else {
      return;
    }
    _busy = true;
    await _stt.stop();
    try {
      if (cmd.isEmpty) {
        _awaiting = true;
        _awaitUntil = DateTime.now().add(const Duration(seconds: 15));
        await _say('Ha, eshitaman.');
        return;
      }
      _awaiting = false;
      _addLog('Siz: $cmd');
      await _process(cmd);
    } catch (e) {
      _addLog('Xato: $e');
    } finally {
      _busy = false;
      _restart();
    }
  }

  String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp("[’‘ʻ'`´]"), '');

  Future<void> _process(String cmd) async {
    final n = _norm(cmd);
    if (RegExp(r'(toxtat|stop|jim bo)').hasMatch(n) ||
        n.contains('тўхтат') ||
        n.contains('тухтат')) {
      await _music.stop();
      await _say('Xo\'p, to\'xtatdim.');
      return;
    }
    if (RegExp(r'qoy').hasMatch(n) || n.contains('қўй')) {
      final q = cmd
          .replaceAll(
              RegExp("(qo['’‘ʻ`]?y(ib)?|musiqani|musiqa|qo['’‘ʻ`]?shiqni|qo['’‘ʻ`]?shiq|iltimos|menga)",
                  caseSensitive: false),
              '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (q.isEmpty) {
        await _say('Qaysi musiqani qo\'yay?');
        _awaiting = true;
        _awaitUntil = DateTime.now().add(const Duration(seconds: 15));
        return;
      }
      await _playMusic(q);
      return;
    }
    final ans = await _chat(cmd);
    await _say(ans);
  }

  Future<void> _playMusic(String q) async {
    await _say('Hozir qo\'yaman.');
    try {
      final res = await _yt.search.search(q);
      if (res.isEmpty) {
        await _say('Topa olmadim.');
        return;
      }
      final v = res.first;
      final man = await _yt.videos.streamsClient.getManifest(v.id);
      final a = man.audioOnly.withHighestBitrate();
      await _music.setUrl(a.url.toString());
      _music.play();
      _addLog('♪ ${v.title}');
    } catch (e) {
      _addLog('Musiqa xatosi: $e');
      await _say('Musiqani yuklab bo\'lmadi.');
    }
  }

  Future<String> _chat(String text) async {
    _history.add({
      'role': 'user',
      'parts': [
        {'text': text}
      ]
    });
    if (_history.length > 20) _history.removeRange(0, _history.length - 20);
    try {
      final r = await http.post(
        Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$_apiKey'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'systemInstruction': {
            'parts': [
              {'text': _sys}
            ]
          },
          'contents': _history,
        }),
      );
      if (r.statusCode != 200) throw Exception('Gemini ${r.statusCode}');
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final ans = (j['candidates'][0]['content']['parts'] as List)
          .map((p) => p['text'] ?? '')
          .join()
          .trim();
      _history.add({
        'role': 'model',
        'parts': [
          {'text': ans}
        ]
      });
      return ans;
    } catch (e) {
      _history.removeLast();
      rethrow;
    }
  }

  Future<void> _say(String text) async {
    _addLog('Alisa: $text');
    await _music.setVolume(0.2);
    try {
      final bytes = await _tts(text);
      await _voice.setAudioSource(BytesSource(bytes));
      await _voice.play();
    } catch (e) {
      _addLog('Ovoz xatosi: $e');
    }
    await _music.setVolume(1.0);
  }

  Future<Uint8List> _tts(String text) async {
    final r = await http.post(
      Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-tts:generateContent?key=$_apiKey'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'contents': [
          {
            'parts': [
              {'text': text}
            ]
          }
        ],
        'generationConfig': {
          'responseModalities': ['AUDIO'],
          'speechConfig': {
            'voiceConfig': {
              'prebuiltVoiceConfig': {'voiceName': 'Kore'}
            }
          }
        },
      }),
    );
    if (r.statusCode != 200) throw Exception('TTS ${r.statusCode}');
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    final b64 = j['candidates'][0]['content']['parts'][0]['inlineData']['data'];
    return _wav(base64Decode(b64));
  }

  Uint8List _wav(Uint8List pcm) {
    final h = ByteData(44);
    void s(int o, String t) {
      for (var i = 0; i < 4; i++) {
        h.setUint8(o + i, t.codeUnitAt(i));
      }
    }

    s(0, 'RIFF');
    h.setUint32(4, 36 + pcm.length, Endian.little);
    s(8, 'WAVE');
    s(12, 'fmt ');
    h.setUint32(16, 16, Endian.little);
    h.setUint16(20, 1, Endian.little);
    h.setUint16(22, 1, Endian.little);
    h.setUint32(24, 24000, Endian.little);
    h.setUint32(28, 48000, Endian.little);
    h.setUint16(32, 2, Endian.little);
    h.setUint16(34, 16, Endian.little);
    s(36, 'data');
    h.setUint32(40, pcm.length, Endian.little);
    return Uint8List.fromList([...h.buffer.asUint8List(), ...pcm]);
  }

  Future<void> _settings() async {
    final c = TextEditingController(text: _apiKey);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sozlamalar'),
        content: TextField(
          controller: c,
          decoration: const InputDecoration(labelText: 'Gemini API key'),
          obscureText: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Bekor')),
          FilledButton(
            onPressed: () async {
              final p = await SharedPreferences.getInstance();
              _apiKey = c.text.trim();
              await p.setString('gemini_key', _apiKey);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Saqlash'),
          ),
        ],
      ),
    );
    setState(() {});
  }

  @override
  void dispose() {
    _stt.cancel();
    _music.dispose();
    _voice.dispose();
    _yt.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alisa'),
        actions: [
          IconButton(icon: const Icon(Icons.settings), onPressed: _settings),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(16),
              itemCount: _log.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(_log[i], style: const TextStyle(fontSize: 16)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Text(_on ? '"Alisa ..." deb gapiring' : 'Boshlash uchun bosing'),
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: _toggle,
                  child: CircleAvatar(
                    radius: 40,
                    backgroundColor: _on ? Colors.redAccent : Colors.deepPurple,
                    child: Icon(_on ? Icons.stop : Icons.mic, size: 40),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
