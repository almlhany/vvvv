import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SmartAlarmApp());
}

class SmartAlarmApp extends StatelessWidget {
  const SmartAlarmApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ساعة التنبيه الذكية',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8),
          secondary: Color(0xFFFBBF24),
          surface: Color(0xFF1E293B),
        ),
      ),
      home: const AlarmHomeScreen(),
    );
  }
}

// ==========================================
// كلاس حساب التاريخ الهجري والميلادي بدقة
// ==========================================
class HijriCalendar {
  static final List<String> hijriMonths = [
    'محرم', 'صفر', 'ربيع الأول', 'ربيع الثاني',
    'جمادى الأولى', 'جمادى الآخرة', 'رجب', 'شعبان',
    'رمضان', 'شوال', 'ذو القعدة', 'ذو الحجة'
  ];

  static final List<String> weekDays = [
    'الإثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة', 'السبت', 'الأحد'
  ];

  static final List<String> gregorianMonths = [
    'يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو',
    'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'
  ];

  // تحويل التاريخ الميلادي إلى هجري بدقة التقويم الإسلامي
  static String getHijriDate(DateTime date, {int adjustment = 0}) {
    final adjustedDate = date.add(Duration(days: adjustment));
    int y = adjustedDate.year;
    int m = adjustedDate.month;
    int d = adjustedDate.day;

    if (m < 3) {
      y -= 1;
      m += 12;
    }

    int a = (y / 100).floor();
    int b = 2 - a + (a / 4).floor();
    int jd = (365.25 * (y + 4716)).floor() + (30.6001 * (m + 1)).floor() + d + b - 1524;

    int l = jd - 1948440 + 10632;
    int n = ((l - 1) / 10631).floor();
    l = l - 10631 * n + 354;
    int j = ((10985 - l) / 5316).floor() * ((50 * l) / 17719).floor() +
        (l / 5670).floor() * ((43 * l) / 15238).floor();
    l = l - ((30 - j) / 15).floor() * ((17719 * j) / 50).floor() -
        (j / 16).floor() * ((15238 * j) / 43).floor() + 29;
    int iMonth = ((24 * l) / 709).floor();
    int iDay = l - ((709 * iMonth) / 24).floor();
    int iYear = 30 * n + j - 30;

    if (iMonth >= 1 && iMonth <= 12) {
      return '$iDay ${hijriMonths[iMonth - 1]} $iYear هـ';
    }
    return '$iDay / $iMonth / $iYear هـ';
  }

  static String getGregorianDate(DateTime date) {
    String dayName = weekDays[date.weekday - 1];
    String monthName = gregorianMonths[date.month - 1];
    return '$dayName، ${date.day} $monthName ${date.year} م';
  }
}

// ==========================================
// الشاشة الرئيسية
// ==========================================
class AlarmHomeScreen extends StatefulWidget {
  const AlarmHomeScreen({super.key});

  @override
  State<AlarmHomeScreen> createState() => _AlarmHomeScreenState();
}

class _AlarmHomeScreenState extends State<AlarmHomeScreen> {
  late Timer _clockTimer;
  DateTime _now = DateTime.now();
  int _hijriAdjustment = 0; // إمكانية تعديل يوم الهلال (+1 أو -1)

  TimeOfDay? _alarmTime;
  bool _isAlarmEnabled = false;
  Timer? _alarmCheckTimer;

  // إعدادات الصوت
  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _customAudioPath;
  String _selectedToneName = 'نغمة ديجيتال مدمجة';
  int _selectedBuiltinTone = 1; // 1: سريع, 2: رنين كلاسيكي

  bool _isRinging = false;

  @override
  void initState() {
    super.initState();
    _setupAudioContext();
    _loadSavedPreferences();

    // تحديث الساعة الحية كل ثانية
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _now = DateTime.now();
        });
        _checkIfAlarmTrigger();
      }
    });
  }

  // ضبط إعدادات الصوت للرنين حتى في وضع السكون وإطفاء الشاشة
  Future<void> _setupAudioContext() async {
    await _audioPlayer.setAudioContext(AudioContext(
      android: const AudioContextAndroid(
        isSpeakerphoneOn: true,
        stayAwake: true,
        contentType: AndroidContentType.sonification,
        usageType: AndroidUsageType.alarm,
        audioFocus: AndroidAudioFocus.gainTransientExclusive,
      ),
    ));
    await _audioPlayer.setReleaseMode(ReleaseMode.loop);
  }

  Future<void> _loadSavedPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _selectedToneName = prefs.getString('tone_name') ?? 'نغمة ديجيتال مدمجة';
      _customAudioPath = prefs.getString('custom_path');
      int? hour = prefs.getInt('alarm_hour');
      int? minute = prefs.getInt('alarm_minute');
      if (hour != null && minute != null) {
        _alarmTime = TimeOfDay(hour: hour, minute: minute);
        _isAlarmEnabled = prefs.getBool('alarm_enabled') ?? false;
      }
    });
  }

  Future<void> _saveAlarmSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (_alarmTime != null) {
      await prefs.setInt('alarm_hour', _alarmTime!.hour);
      await prefs.setInt('alarm_minute', _alarmTime!.minute);
    }
    await prefs.setBool('alarm_enabled', _isAlarmEnabled);
    await prefs.setString('tone_name', _selectedToneName);
    if (_customAudioPath != null) {
      await prefs.setString('custom_path', _customAudioPath!);
    }
  }

  // فحص وقت المنبه
  void _checkIfAlarmTrigger() {
    if (!_isAlarmEnabled || _alarmTime == null || _isRinging) return;

    if (_now.hour == _alarmTime!.hour &&
        _now.minute == _alarmTime!.minute &&
        _now.second == 0) {
      _startAlarmRinging();
    }
  }

  // توليد نغمة تنبيه أصلية بدون الحاجة لتحميل ملفات خارجية
  Uint8List _generateAlarmWav({int freq = 880, int durationMs = 600}) {
    const sampleRate = 8000;
    final numSamples = (sampleRate * (durationMs / 1000.0)).floor();
    final data = BytesBuilder();

    for (int i = 0; i < numSamples; i++) {
      double t = i / sampleRate;
      double sample = sin(2 * pi * freq * t);
      int val = (sample * 32767 * 0.7).floor().clamp(-32768, 32767);
      data.addByte(val & 0xFF);
      data.addByte((val >> 8) & 0xFF);
    }

    final bytes = data.takeBytes();
    final header = BytesBuilder();
    header.add('RIFF'.codeUnits);
    final fileSize = 36 + bytes.length;
    header.add([fileSize & 0xFF, (fileSize >> 8) & 0xFF, (fileSize >> 16) & 0xFF, (fileSize >> 24) & 0xFF]);
    header.add('WAVEfmt '.codeUnits);
    header.add([16, 0, 0, 0, 1, 0, 1, 0]); // PCM, 1 channel
    header.add([sampleRate & 0xFF, (sampleRate >> 8) & 0xFF, 0, 0]);
    final byteRate = sampleRate * 2;
    header.add([byteRate & 0xFF, (byteRate >> 8) & 0xFF, 0, 0]);
    header.add([2, 0, 16, 0]); // align, bits
    header.add('data'.codeUnits);
    header.add([bytes.length & 0xFF, (bytes.length >> 8) & 0xFF, (bytes.length >> 16) & 0xFF, (bytes.length >> 24) & 0xFF]);

    header.add(bytes);
    return header.takeBytes();
  }

  // بدء الرنين وإبقاء الشاشة مضاءة
  Future<void> _startAlarmRinging() async {
    setState(() {
      _isRinging = true;
    });

    // إبقاء الشاشة مضاءة ومنع الهاتف من النوم
    WakelockPlus.enable();

    try {
      if (_customAudioPath != null && File(_customAudioPath!).existsSync()) {
        await _audioPlayer.play(DeviceFileSource(_customAudioPath!));
      } else {
        // تشغيل النغمة المدمجة
        final wavBytes = _generateAlarmWav(
          freq: _selectedBuiltinTone == 1 ? 950 : 650,
          durationMs: 700,
        );
        await _audioPlayer.play(BytesSource(wavBytes));
      }
    } catch (e) {
      debugPrint('Error playing audio: $e');
    }

    // فتح واجهة الرنين
    if (mounted) {
      _showRingingScreen();
    }
  }

  // إيقاف التنبيه
  Future<void> _stopAlarm() async {
    await _audioPlayer.stop();
    WakelockPlus.disable();
    setState(() {
      _isRinging = false;
    });
  }

  // غفوة 5 دقائق
  void _snoozeAlarm() {
    _stopAlarm();
    final snoozeTime = DateTime.now().add(const Duration(minutes: 5));
    setState(() {
      _alarmTime = TimeOfDay(hour: snoozeTime.hour, minute: snoozeTime.minute);
      _isAlarmEnabled = true;
    });
    _saveAlarmSettings();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم تأجيل المنبه 5 دقائق (غفوة) 💤')),
    );
  }

  // اختيار نغمة من ذاكرة الهاتف
  Future<void> _pickAudioFileFromPhone() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
      );

      if (result != null && result.files.single.path != null) {
        setState(() {
          _customAudioPath = result.files.single.path;
          _selectedToneName = result.files.single.name;
        });
        _saveAlarmSettings();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تم اختيار النغمة: $_selectedToneName')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر اختيار الملف الصوتي')),
      );
    }
  }

  // شاشة الرنين الكاملة فوق القفل
  void _showRingingScreen() {
    showGeneralDialog(
      context: context,
      barrierDismissible: false,
      pageBuilder: (context, anim1, anim2) {
        return PopScope(
          canPop: false,
          child: Scaffold(
            backgroundColor: const Color(0xFF090D16),
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.alarm_on, size: 90, color: Color(0xFFF43F5E)),
                      const SizedBox(height: 20),
                      Text(
                        '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}',
                        style: const TextStyle(fontSize: 54, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'حان وقت الاستيقاظ!',
                        style: TextStyle(fontSize: 22, color: Colors.white70),
                      ),
                      const SizedBox(height: 50),
                      // زر إيقاف التنبيه
                      SizedBox(
                        width: double.infinity,
                        height: 60,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFEF4444),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          onPressed: () {
                            _stopAlarm();
                            Navigator.of(context).pop();
                          },
                          icon: const Icon(Icons.stop_circle, color: Colors.white, size: 28),
                          label: const Text('🛑 إيقاف التنبيه', style: TextStyle(fontSize: 20, color: Colors.white)),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // زر الغفوة
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white38),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          onPressed: () {
                            Navigator.of(context).pop();
                            _snoozeAlarm();
                          },
                          icon: const Icon(Icons.snooze),
                          label: const Text('💤 غفوة (5 دقائق)', style: TextStyle(fontSize: 16)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _clockTimer.cancel();
    _alarmCheckTimer?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String timeStr = '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}:${_now.second.toString().padLeft(2, '0')}';
    String hijriDate = HijriCalendar.getHijriDate(_now, adjustment: _hijriAdjustment);
    String gregorianDate = HijriCalendar.getGregorianDate(_now);

    return Scaffold(
      appBar: AppBar(
        title: const Text('ساعة التنبيه الاحترافية', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            // بطاقة الساعة الرقمية والتواريخ
            Card(
              elevation: 8,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              color: const Color(0xFF1E293B),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
                child: Column(
                  children: [
                    Text(
                      timeStr,
                      style: const TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF38BDF8),
                        letterSpacing: 2,
                      ),
                    ),
                    const Divider(color: Colors.white12, height: 28),
                    // التاريخ الهجري
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '🌙 $hijriDate',
                          style: const TextStyle(fontSize: 18, color: Color(0xFFFBBF24), fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // التاريخ الميلادي
                    Text(
                      '📅 $gregorianDate',
                      style: const TextStyle(fontSize: 15, color: Color(0xFF94A3B8)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // كارت ضبط المنبه
            Card(
              elevation: 4,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              color: const Color(0xFF1E293B),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.access_time_filled, color: Color(0xFF38BDF8), size: 36),
                      title: Text(
                        _alarmTime != null
                            ? 'موعد التنبيه: ${_alarmTime!.format(context)}'
                            : 'اضغط لتحديد وقت التنبيه',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        _isAlarmEnabled ? 'المنبه مفعل ✅' : 'المنبه متوقف ❌',
                        style: TextStyle(color: _isAlarmEnabled ? Colors.greenAccent : Colors.redAccent),
                      ),
                      trailing: Switch(
                        value: _isAlarmEnabled,
                        activeColor: const Color(0xFF38BDF8),
                        onChanged: (val) {
                          if (_alarmTime == null && val) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('يرجى تحديد وقت التنبيه أولاً')),
                            );
                            return;
                          }
                          setState(() {
                            _isAlarmEnabled = val;
                          });
                          _saveAlarmSettings();
                        },
                      ),
                      onTap: () async {
                        final picked = await showTimePicker(
                          context: context,
                          initialTime: _alarmTime ?? TimeOfDay.now(),
                        );
                        if (picked != null) {
                          setState(() {
                            _alarmTime = picked;
                            _isAlarmEnabled = true;
                          });
                          _saveAlarmSettings();
                        }
                      },
                    ),
                    const Divider(color: Colors.white12),
                    // معلومات النغمة
                    Row(
                      children: [
                        const Icon(Icons.music_note, color: Color(0xFF34D399), size: 22),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'النغمة: $_selectedToneName',
                            style: const TextStyle(color: Color(0xFF34D399), fontSize: 13),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // أزرار التحكم بالنغمات
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF475569),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: _pickAudioFileFromPhone,
                icon: const Icon(Icons.audio_file, color: Colors.white),
                label: const Text('🎵 إضافة نغمة من الهاتف (MP3 / WAV)', style: TextStyle(fontSize: 15, color: Colors.white)),
              ),
            ),
            const SizedBox(height: 12),

            // زر التجربة السريعة (رنين بعد 10 ثوانٍ)
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFD97706),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: () {
                  final testTime = DateTime.now().add(const Duration(seconds: 10));
                  setState(() {
                    _alarmTime = TimeOfDay(hour: testTime.hour, minute: testTime.minute);
                    _isAlarmEnabled = true;
                  });
                  _saveAlarmSettings();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('سيشتغل التنبيه بعد 10 ثوانٍ.. اقفل شاشة هاتفك