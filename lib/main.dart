import 'dart:async';
import 'dart:convert';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// ======================= config.dart =======================
class AppConfig {
  // يمكن تغييرها وقت البناء:
  // flutter run --dart-define=TEMPMAIL_KEY=xxxx
  static const gatewayUrl = String.fromEnvironment(
    'TEMPMAIL_GATEWAY',
    defaultValue: 'https://temporary-email3.p.rapidapi.com',
  );
  static const gatewayKey = String.fromEnvironment(
    'TEMPMAIL_KEY',
    defaultValue: '85c0287154msh55bbcae0f065001p12e225jsn7770b94568bb',
  );

  static const randomDomain = 'random.com';
  static const pollInterval = Duration(seconds: 5); // والتطبيق مفتوح
  static const bgInterval = Duration(seconds: 15); // في الخلفية
  static const httpTimeout = Duration(seconds: 45);
  static const userAgent = 'odin-mail/1.0';

  static const domains = <String>[
    'singapore.edu.pl', 'paris.edu.pl', 'france.edu.pl', 'devpoet.com',
    'hastana.com', 'fenfax.com', 'jewby.com', 'bogchi.com', 'devmant.com',
    'appbott.com', 'animoby.com', 'fordemy.com', 'meltcoo.com', 'brajraj.org',
    'comproa.org', 'damphen.org', 'momroad.org', 'bussaco.com',
    'storegmail.net', 'amiced.com', 'gurantan.com', 'sambolias.com',
    'mesetar.com', 'deweyart.com', 'spyboys.com', 'dinwold.net', 'nakeit.com',
    'newszig.com', 'sousor.com', 'bakulab.com', 'amokrun.com', 'tomspal.com',
  ];

  static final codePatterns = <RegExp>[
    RegExp(r'(?:code|otp|verification|confirm|pin|كود|رمز|تحقق)[^\d\n]{0,25}(\d{4,8})',
        caseSensitive: false),
    RegExp(r'(\d{4,8})[^\d\n]{0,25}(?:is your|code|otp)', caseSensitive: false),
    RegExp(r'\b(\d{6})\b'),
    RegExp(r'\b(\d{4,8})\b'),
  ];
}

// ======================= models.dart =======================
class Inbox {
  final String address;
  final int since;
  final int created;
  final List<String> seenMids; // أُرسل لها إشعار
  final List<String> readMids; // فتحها المستخدم
  final List<String> deletedMids; // حذفها المستخدم بنفسه (لا تظهر ثانية)

  Inbox({
    required this.address,
    required this.since,
    int? created,
    List<String>? seenMids,
    List<String>? readMids,
    List<String>? deletedMids,
  })  : created = created ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
        seenMids = seenMids ?? [],
        readMids = readMids ?? [],
        deletedMids = deletedMids ?? [];

  Inbox copyWith({
    int? since,
    List<String>? seenMids,
    List<String>? readMids,
    List<String>? deletedMids,
  }) =>
      Inbox(
        address: address,
        since: since ?? this.since,
        created: created,
        seenMids: seenMids ?? this.seenMids,
        readMids: readMids ?? this.readMids,
        deletedMids: deletedMids ?? this.deletedMids,
      );

  Map<String, dynamic> toJson() => {
        'address': address,
        'since': since,
        'created': created,
        'seen_mids': seenMids,
        'read_mids': readMids,
        'deleted_mids': deletedMids,
      };

  factory Inbox.fromJson(Map<String, dynamic> j) => Inbox(
        address: j['address'] as String,
        since: (j['since'] as num).toInt(),
        created: (j['created'] as num?)?.toInt(),
        seenMids: List<String>.from(j['seen_mids'] ?? const []),
        readMids: List<String>.from(j['read_mids'] ?? const []),
        deletedMids: List<String>.from(j['deleted_mids'] ?? const []),
      );
}

class MailItem {
  final String mid;
  final String from;
  final String to;
  final String subject;
  final String date;

  const MailItem({
    required this.mid,
    required this.from,
    required this.to,
    required this.subject,
    required this.date,
  });

  /// من رد الخادم
  factory MailItem.fromJson(Map<String, dynamic> j) => MailItem(
        mid: '${j['mid'] ?? ''}',
        from: '${j['textFrom'] ?? '?'}',
        to: '${j['textTo'] ?? ''}',
        subject: '${j['textSubject'] ?? ''}'.trim().isEmpty
            ? '(بدون عنوان)'
            : '${j['textSubject']}',
        date: '${j['textDate'] ?? ''}',
      );

  /// من التخزين المحلي
  factory MailItem.fromStored(Map<String, dynamic> j) => MailItem(
        mid: '${j['mid']}',
        from: '${j['from']}',
        to: '${j['to']}',
        subject: '${j['subject']}',
        date: '${j['date']}',
      );

  Map<String, dynamic> toStored() => {
        'mid': mid,
        'from': from,
        'to': to,
        'subject': subject,
        'date': date,
      };
}

class MailDetail {
  final String rawBody;
  final String text;
  final String? code;
  final List<dynamic> attachments;

  const MailDetail({
    required this.rawBody,
    required this.text,
    required this.code,
    required this.attachments,
  });

  Map<String, dynamic> toStored() =>
      {'text': text, 'code': code, 'attachments': attachments};

  factory MailDetail.fromStored(Map<String, dynamic> j) => MailDetail(
        rawBody: '',
        text: '${j['text'] ?? ''}',
        code: j['code'] as String?,
        attachments: List<dynamic>.from(j['attachments'] ?? const []),
      );
}

// ======================= api.dart =======================
class TempMailException implements Exception {
  final String message;
  TempMailException(this.message);
  @override
  String toString() => message;
}

class TempMailApi {
  // ---------------- الشبكة ----------------
  static Future<dynamic> _gateway(String path, Map<String, String> params) async {
    if (AppConfig.gatewayKey.isEmpty) {
      throw TempMailException('مفتاح الخدمة غير مضبوط (TEMPMAIL_KEY)');
    }
    final uri = Uri.parse('${AppConfig.gatewayUrl}$path').replace(
      queryParameters: {...params, 'rapidapi-key': AppConfig.gatewayKey},
    );

    http.Response res;
    try {
      res = await http.get(uri, headers: {
        'User-Agent': AppConfig.userAgent,
        'Accept': 'application/json',
      }).timeout(AppConfig.httpTimeout);
    } on TimeoutException {
      throw TempMailException('انتهت مهلة الاتصال');
    } catch (_) {
      throw TempMailException('لا يوجد اتصال بالإنترنت');
    }

    if (res.statusCode != 200) {
      const hints = {
        401: 'المفتاح غير صالح أو العنوان/الرسالة لم تعد موجودة',
        403: 'ممنوع',
        429: 'طلبات كثيرة، أبطئ التحديث',
      };
      final hint = hints[res.statusCode];
      throw TempMailException(
          'HTTP ${res.statusCode}${hint != null ? ' ($hint)' : ''}');
    }

    final text = utf8.decode(res.bodyBytes, allowMalformed: true);
    dynamic data;
    try {
      data = text.trim().isEmpty ? <String, dynamic>{} : jsonDecode(text);
    } catch (_) {
      throw TempMailException('رد غير مفهوم من الخادم');
    }

    if (data is Map) {
      final code = data['code'];
      if (code != null && code != 200 && '$code' != '200') {
        throw TempMailException('$code: ${data['msg']}');
      }
      return data['items'] ?? <dynamic>[];
    }
    return data;
  }

  // ---------------- العمليات ----------------
  static Future<Inbox> createInbox({
    String domain = AppConfig.randomDomain,
    String username = 'random',
  }) async {
    final items = await _gateway('/get', {'username': username, 'domain': domain});
    if (items is! Map || (items['email'] ?? '').toString().isEmpty) {
      throw TempMailException('الخادم لم يرجع عنواناً');
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return Inbox(
      address: items['email'].toString(),
      since: int.tryParse('${items['timestamp']}') ?? now,
    );
  }

  static Future<List<MailItem>> listMessages(Inbox inbox) async {
    final items = await _gateway(
        '/check', {'email': inbox.address, 'timestamp': '${inbox.since}'});
    if (items is! List) return [];
    return items
        .whereType<Map>()
        .map((m) => MailItem.fromJson(Map<String, dynamic>.from(m)))
        .where((m) => m.mid.isNotEmpty)
        .toList();
  }

  static Future<MailDetail> readMessage(Inbox inbox, String mid) async {
    final payload = await _gateway('/read', {'email': inbox.address, 'mid': mid});
    final body = _findBody(payload);
    var attachments = <dynamic>[];
    if (payload is Map) {
      final a = payload['attachments'] ?? payload['files'];
      if (a is List) attachments = a;
    }
    final text = htmlToText(body);
    return MailDetail(
      rawBody: body,
      text: text,
      code: extractCode([body, text]),
      attachments: attachments,
    );
  }

  // ---------------- أدوات ----------------
  static String _findBody(dynamic node, [int depth = 0]) {
    if (depth > 4) return '';
    if (node is String) return node;
    if (node is Map) {
      for (final k in const ['body', 'html', 'htmlBody', 'content', 'text', 'message']) {
        final v = node[k];
        if (v is String && v.trim().isNotEmpty) return v;
      }
      for (final v in node.values) {
        final f = _findBody(v, depth + 1);
        if (f.isNotEmpty) return f;
      }
    } else if (node is List) {
      for (final v in node) {
        final f = _findBody(v, depth + 1);
        if (f.isNotEmpty) return f;
      }
    }
    return '';
  }

  static String htmlToText(String markup) {
    var t = markup.replaceAll(
        RegExp(r'<(script|style)\b.*?>.*?</\1>', caseSensitive: false, dotAll: true), ' ');
    t = t.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    t = t.replaceAll(
        RegExp(r'</(p|div|tr|li|h[1-6]|table)>', caseSensitive: false), '\n');
    t = t.replaceAll(RegExp(r'<[^>]+>'), ' ');
    const entities = {
      '&nbsp;': ' ', '&amp;': '&', '&lt;': '<',
      '&gt;': '>', '&quot;': '"', '&#39;': "'",
    };
    entities.forEach((k, v) => t = t.replaceAll(k, v));
    t = t.replaceAll(RegExp(r'[ \t]+'), ' ');
    t = t.replaceAll(RegExp(r' ?\n ?'), '\n');
    t = t.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return t.trim();
  }

  static String? extractCode(List<String> sources) {
    final blob = sources.where((s) => s.isNotEmpty).join(' ');
    for (final p in AppConfig.codePatterns) {
      final m = p.firstMatch(blob);
      if (m != null) return m.group(1);
    }
    return null;
  }
}

// ======================= store.dart =======================
/// تخزين محلي. يُستخدم من الواجهة ومن خدمة الخلفية (isolate مختلف)،
/// لذلك نعمل reload() قبل كل قراءة.
///
/// القواعد:
///  - العنوان لا يتغير إلا بطلب المستخدم.
///  - الرسائل تُحفظ محلياً ولا تُحذف إلا بحذف المستخدم (حتى لو حذفها الخادم).
class Store {
  static const _kInbox = 'inbox';
  static const _kHistory = 'history';
  static const _kNotif = 'notif_enabled';
  static const _kBg = 'bg_enabled';
  static const _kDomain = 'domain';

  static Future<SharedPreferences> _p() async {
    final p = await SharedPreferences.getInstance();
    await p.reload();
    return p;
  }

  // ================= العناوين =================
  static Inbox? _decodeInbox(String? raw) {
    if (raw == null) return null;
    try {
      return Inbox.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static List<Inbox> _decodeHistory(SharedPreferences p) {
    final out = <Inbox>[];
    for (final raw in p.getStringList(_kHistory) ?? const <String>[]) {
      final i = _decodeInbox(raw);
      if (i != null) out.add(i);
    }
    return out;
  }

  /// العنوان الحالي. لو تلف الملف نرجع لآخر عنوان محفوظ بدل إنشاء عنوان جديد.
  static Future<Inbox?> loadInbox() async {
    final p = await _p();
    final current = _decodeInbox(p.getString(_kInbox));
    if (current != null) return current;
    final history = _decodeHistory(p);
    return history.isEmpty ? null : history.first;
  }

  static Future<List<Inbox>> loadHistory() async => _decodeHistory(await _p());

  /// يجعل [inbox] هو الحالي ويحدّثه في السجل.
  static Future<void> saveInbox(Inbox inbox) async {
    final p = await _p();
    await p.setString(_kInbox, jsonEncode(inbox.toJson()));
    final history = _decodeHistory(p);
    final idx = history.indexWhere((i) => i.address == inbox.address);
    if (idx >= 0) {
      history[idx] = inbox;
    } else {
      history.insert(0, inbox);
    }
    await p.setStringList(
        _kHistory, history.map((i) => jsonEncode(i.toJson())).toList());
  }

  static Future<Inbox?> markSeen(Iterable<String> mids) async {
    final inbox = await loadInbox();
    if (inbox == null) return null;
    final updated =
        inbox.copyWith(seenMids: {...inbox.seenMids, ...mids}.toList());
    await saveInbox(updated);
    return updated;
  }

  static Future<Inbox?> markRead(Iterable<String> mids) async {
    final inbox = await loadInbox();
    if (inbox == null) return null;
    final updated = inbox.copyWith(
      readMids: {...inbox.readMids, ...mids}.toList(),
      seenMids: {...inbox.seenMids, ...mids}.toList(),
    );
    await saveInbox(updated);
    return updated;
  }

  // ================= الرسائل =================
  static String _mailsKey(String address) => 'mails_$address';
  static String _detailKey(String address, String mid) => 'detail_${address}_$mid';

  static List<MailItem> _decodeMails(String? raw) {
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => MailItem.fromStored(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<List<MailItem>> loadMails(String address) async =>
      _decodeMails((await _p()).getString(_mailsKey(address)));

  /// يضيف الرسائل الجديدة فقط (بدون حذف أي قديم، وبدون ما حذفه المستخدم).
  static Future<List<MailItem>> mergeMails(
      String address, List<MailItem> incoming) async {
    final p = await _p();
    final current = _decodeMails(p.getString(_mailsKey(address)));
    final inbox = await loadInbox();
    final deleted =
        inbox?.address == address ? inbox!.deletedMids.toSet() : <String>{};
    final known = current.map((m) => m.mid).toSet();
    final added = incoming
        .where((m) => !known.contains(m.mid) && !deleted.contains(m.mid))
        .toList();
    if (added.isEmpty) return current;
    final merged = [...added, ...current];
    await p.setString(
        _mailsKey(address), jsonEncode(merged.map((m) => m.toStored()).toList()));
    return merged;
  }

  /// الحذف الوحيد المسموح: بطلب المستخدم.
  static Future<List<MailItem>> deleteMails(
      String address, Iterable<String> mids) async {
    final p = await _p();
    final ids = mids.toSet();
    final remaining = _decodeMails(p.getString(_mailsKey(address)))
        .where((m) => !ids.contains(m.mid))
        .toList();
    await p.setString(_mailsKey(address),
        jsonEncode(remaining.map((m) => m.toStored()).toList()));
    for (final mid in ids) {
      await p.remove(_detailKey(address, mid));
    }
    final inbox = await loadInbox();
    if (inbox != null && inbox.address == address) {
      await saveInbox(
          inbox.copyWith(deletedMids: {...inbox.deletedMids, ...ids}.toList()));
    }
    return remaining;
  }

  // ----- نص الرسالة المحفوظ (يبقى حتى لو حذفها الخادم) -----
  static Future<MailDetail?> loadDetail(String address, String mid) async {
    final raw = (await _p()).getString(_detailKey(address, mid));
    if (raw == null) return null;
    try {
      return MailDetail.fromStored(
          Map<String, dynamic>.from(jsonDecode(raw) as Map));
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveDetail(
      String address, String mid, MailDetail d) async {
    final p = await _p();
    await p.setString(_detailKey(address, mid), jsonEncode(d.toStored()));
  }

  // ================= الإعدادات =================
  static Future<bool> notifEnabled() async =>
      (await _p()).getBool(_kNotif) ?? true;
  static Future<void> setNotif(bool v) async =>
      (await _p()).setBool(_kNotif, v);

  static Future<bool> bgEnabled() async => (await _p()).getBool(_kBg) ?? false;
  static Future<void> setBg(bool v) async => (await _p()).setBool(_kBg, v);

  static Future<String> domain() async =>
      (await _p()).getString(_kDomain) ?? AppConfig.randomDomain;
  static Future<void> setDomain(String v) async =>
      (await _p()).setString(_kDomain, v);
}

// ======================= utils.dart =======================
/// مفتاح لعرض رسائل Snackbar من أي مكان (حتى من معالج الإشعارات).
final GlobalKey<ScaffoldMessengerState> messengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// عند الضغط على إشعار (بدون زر) نضع بياناته هنا فتفتحها الشاشة الرئيسية.
final ValueNotifier<Map<String, dynamic>?> pendingOpen =
    ValueNotifier<Map<String, dynamic>?>(null);

void toast(String text) {
  final m = messengerKey.currentState;
  if (m == null) return;
  m
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(text, textAlign: TextAlign.center),
      duration: const Duration(milliseconds: 1600),
      behavior: SnackBarBehavior.floating,
    ));
}

Future<void> copyText(String text, String message) async {
  if (text.trim().isEmpty) {
    toast('لا يوجد نص للنسخ');
    return;
  }
  await Clipboard.setData(ClipboardData(text: text));
  toast(message);
}

class AppColors {
  static const bg = Color(0xFF0B0D1A);
  static const bg2 = Color(0xFF111426);
  static const card = Color(0xFF161A30);
  static const line = Color(0xFF262B4A);
  static const text = Color(0xFFECEEFB);
  static const muted = Color(0xFF9AA0C3);
  static const accent = Color(0xFF7C5CFF);
  static const gold = Color(0xFFF5B942);
  static const ok = Color(0xFF34D399);
  static const danger = Color(0xFFF87171);
}

// ======================= repository.dart =======================
/// يرجع نص الرسالة من التخزين المحلي، وإن لم يوجد يجلبه ويحفظه.
Future<MailDetail> getDetail(Inbox inbox, String mid) async {
  final cached = await Store.loadDetail(inbox.address, mid);
  if (cached != null) return cached;
  final fresh = await TempMailApi.readMessage(inbox, mid);
  await Store.saveDetail(inbox.address, mid, fresh);
  return fresh;
}

// ======================= notifications.dart =======================
class NotificationService {
  static final FlutterLocalNotificationsPlugin plugin =
      FlutterLocalNotificationsPlugin();

  static const mailChannelId = 'odin_mail_incoming';
  static const serviceChannelId = 'odin_mail_service';

  static const actionCopyCode = 'copy_code';
  static const actionCopyBody = 'copy_body';
  static const actionCopySubject = 'copy_subject';
  static const actionCopyFrom = 'copy_from';

  static Future<void> init({
    DidReceiveNotificationResponseCallback? onResponse,
  }) async {
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await plugin.initialize(settings, onDidReceiveNotificationResponse: onResponse);

    final android = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      mailChannelId,
      'الرسائل الواردة',
      description: 'إشعار عند وصول رسالة أو كود تحقق جديد',
      importance: Importance.high,
    ));
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      serviceChannelId,
      'خدمة المراقبة',
      description: 'تبقي التطبيق يراقب الصندوق في الخلفية',
      importance: Importance.low,
    ));
  }

  /// أندرويد 13+ يحتاج إذن POST_NOTIFICATIONS.
  static Future<bool> requestPermission() async {
    final android = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    return await android?.requestNotificationsPermission() ?? true;
  }

  /// يعرض إشعاراً لرسالة جديدة مع أزرار النسخ.
  static Future<void> showMail({
    required MailItem mail,
    required MailDetail detail,
  }) async {
    final code = detail.code;
    final preview = detail.text.length > 1500
        ? '${detail.text.substring(0, 1500)}…'
        : detail.text;

    final title = code != null ? 'كود التحقق: $code' : mail.subject;
    final summary = code != null
        ? '${mail.subject} — ${mail.from}'
        : (preview.isEmpty ? mail.from : preview.replaceAll('\n', ' '));

    // الأزرار (أندرويد يعرض 3 كحد أقصى)
    final actions = <AndroidNotificationAction>[
      if (code != null)
        const AndroidNotificationAction(actionCopyCode, 'نسخ الكود',
            showsUserInterface: true, cancelNotification: false),
      const AndroidNotificationAction(actionCopyBody, 'نسخ الرسالة',
          showsUserInterface: true, cancelNotification: false),
      if (code == null)
        const AndroidNotificationAction(actionCopySubject, 'نسخ العنوان',
            showsUserInterface: true, cancelNotification: false),
      const AndroidNotificationAction(actionCopyFrom, 'نسخ المرسل',
          showsUserInterface: true, cancelNotification: false),
    ];

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        mailChannelId,
        'الرسائل الواردة',
        channelDescription: 'إشعار عند وصول رسالة أو كود تحقق جديد',
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.message,
        styleInformation: BigTextStyleInformation(
          preview.isEmpty ? mail.subject : preview,
          contentTitle: title,
          summaryText: mail.from,
        ),
        actions: actions,
        autoCancel: true,
      ),
    );

    final payload = jsonEncode({
      'mid': mail.mid,
      'from': mail.from,
      'to': mail.to,
      'subject': mail.subject,
      'date': mail.date,
      'code': code,
      'preview': preview,
    });

    await plugin.show(
      mail.mid.hashCode & 0x7fffffff,
      title,
      summary,
      details,
      payload: payload,
    );
  }

  /// يُنفَّذ عند الضغط على الإشعار أو أحد أزراره.
  static Future<void> handleResponse(NotificationResponse r) async {
    Map<String, dynamic> d = {};
    try {
      d = Map<String, dynamic>.from(jsonDecode(r.payload ?? '{}') as Map);
    } catch (_) {}

    final id = r.actionId;
    if (id == null || id.isEmpty) {
      pendingOpen.value = d; // ضغطة عادية → افتح الرسالة
      return;
    }

    // انتظر لحظة ليصبح التطبيق في المقدمة (أندرويد 10+ يمنع النسخ من الخلفية)
    await Future.delayed(const Duration(milliseconds: 500));

    switch (id) {
      case actionCopyCode:
        await copyText('${d['code'] ?? ''}', 'تم نسخ الكود ✓');
        break;
      case actionCopySubject:
        await copyText('${d['subject'] ?? ''}', 'تم نسخ العنوان ✓');
        break;
      case actionCopyFrom:
        await copyText('${d['from'] ?? ''}', 'تم نسخ المرسل ✓');
        break;
      case actionCopyBody:
        var text = '${d['preview'] ?? ''}';
        try {
          final inbox = await Store.loadInbox();
          final mid = '${d['mid'] ?? ''}';
          if (inbox != null && mid.isNotEmpty) {
            final full = await getDetail(inbox, mid);
            if (full.text.isNotEmpty) text = full.text;
          }
        } catch (_) {/* نكتفي بالمعاينة */}
        await copyText(text, 'تم نسخ الرسالة ✓');
        break;
    }
  }
}

// ======================= poller.dart =======================
/// يجلب الرسائل ويحفظها محلياً (لا يُحذف شيء)، وإن كان [notify] مفعلاً
/// يرسل إشعاراً لكل رسالة جديدة. يرجع كل الرسائل المحفوظة.
Future<List<MailItem>> fetchMessages(Inbox inbox, {required bool notify}) async {
  final remote = await TempMailApi.listMessages(inbox);
  final stored = await Store.mergeMails(inbox.address, remote);

  final latest = await Store.loadInbox() ?? inbox;
  final seen = latest.seenMids.toSet();
  final deleted = latest.deletedMids.toSet();

  for (final mail in remote) {
    if (deleted.contains(mail.mid)) continue;
    try {
      // نحفظ النص محلياً ليبقى حتى لو حذفه الخادم
      final detail = await getDetail(latest, mail.mid);
      if (notify && !seen.contains(mail.mid)) {
        await NotificationService.showMail(mail: mail, detail: detail);
        await Store.markSeen([mail.mid]);
      }
    } on TempMailException {
      continue; // نحاول في الدورة القادمة
    }
  }
  return stored;
}

bool _busy = false;

/// دورة واحدة من الفحص في الخلفية.
Future<void> pollOnce() async {
  if (_busy) return;
  _busy = true;
  try {
    if (!await Store.notifEnabled()) return;
    final inbox = await Store.loadInbox();
    if (inbox == null) return;
    await fetchMessages(inbox, notify: true);
  } catch (_) {
    // لا نوقف الخدمة بسبب خطأ شبكة عابر
  } finally {
    _busy = false;
  }
}

// ======================= background.dart =======================
Future<void> initBackgroundService() async {
  await FlutterBackgroundService().configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: NotificationService.serviceChannelId,
      initialNotificationTitle: 'Odin Mail',
      initialNotificationContent: 'يراقب الرسائل الواردة…',
      foregroundServiceNotificationId: 8888,
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  await NotificationService.init();

  service.on('stopService').listen((_) => service.stopSelf());

  Timer.periodic(AppConfig.bgInterval, (_) => pollOnce());
  pollOnce();
}

// ======================= home_page.dart =======================
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  Inbox? _inbox;
  List<MailItem> _mails = [];
  bool _online = true;
  bool _loading = true;
  bool _notif = true;
  bool _bg = false;
  String _domain = AppConfig.randomDomain;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    pendingOpen.addListener(_onPendingOpen);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    pendingOpen.removeListener(_onPendingOpen);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startTimer();
      _refresh();
    } else if (state == AppLifecycleState.paused) {
      _timer?.cancel();
    }
  }

  // ---------------- التهيئة ----------------
  Future<void> _bootstrap() async {
    _notif = await Store.notifEnabled();
    _bg = await Store.bgEnabled();
    _domain = await Store.domain();
    if (_notif) await NotificationService.requestPermission();

    if (_bg) {
      final svc = FlutterBackgroundService();
      if (!await svc.isRunning()) await svc.startService();
    }

    _inbox = await Store.loadInbox();
    if (_inbox == null) {
      await _newAddress(); // أول تشغيل فقط
    } else {
      _mails = await Store.loadMails(_inbox!.address); // المحفوظ محلياً
      setState(() => _loading = false);
      await _refresh();
    }
    _startTimer();

    // لو فُتح التطبيق من إشعار وهو مغلق
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final launch =
          await NotificationService.plugin.getNotificationAppLaunchDetails();
      final r = launch?.notificationResponse;
      if (launch?.didNotificationLaunchApp == true && r != null) {
        await NotificationService.handleResponse(r);
      }
    });
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(AppConfig.pollInterval, (_) => _refresh());
  }

  // ---------------- الإجراءات ----------------
  Future<void> _newAddress() async {
    setState(() => _loading = true);
    try {
      final inbox = await TempMailApi.createInbox(domain: _domain);
      await Store.saveInbox(inbox);
      _inbox = inbox;
      _mails = await Store.loadMails(inbox.address);
      _online = true;
    } on TempMailException catch (e) {
      _online = false;
      toast('تعذر إنشاء العنوان: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<bool> _confirm(String title, String body, String yes) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(yes,
                  style: const TextStyle(color: AppColors.danger))),
        ],
      ),
    );
    return r == true;
  }

  Future<void> _confirmNewAddress() async {
    final ok = await _confirm(
      'عنوان جديد؟',
      'سيتم إنشاء عنوان آخر. العنوان الحالي ورسائله تبقى محفوظة '
          'ويمكنك الرجوع إليها من الإعدادات ← العناوين السابقة.',
      'إنشاء',
    );
    if (ok) await _newAddress();
  }

  Future<void> _deleteMails(List<String> mids) async {
    final inbox = _inbox;
    if (inbox == null) return;
    final remaining = await Store.deleteMails(inbox.address, mids);
    final fresh = await Store.loadInbox() ?? inbox;
    if (!mounted) return;
    setState(() {
      _mails = remaining;
      _inbox = fresh;
    });
    toast('تم الحذف');
  }

  Future<void> _switchTo(Inbox target) async {
    await Store.saveInbox(target);
    final mails = await Store.loadMails(target.address);
    if (!mounted) return;
    setState(() {
      _inbox = target;
      _mails = mails;
    });
    _refresh();
  }

  Future<void> _showHistory() async {
    final list = await Store.loadHistory();
    if (!mounted) return;
    Navigator.of(context).pop(); // أغلق الإعدادات
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        children: [
          const Text('العناوين السابقة',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          for (final i in list)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Directionality(
                textDirection: TextDirection.ltr,
                child: Text(i.address,
                    style: const TextStyle(color: AppColors.gold)),
              ),
              trailing: i.address == _inbox?.address
                  ? const Icon(Icons.check_circle, color: AppColors.ok)
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                if (i.address != _inbox?.address) _switchTo(i);
              },
            ),
        ],
      ),
    );
  }

  Future<void> _refresh({bool manual = false}) async {
    final inbox = _inbox;
    if (inbox == null) {
      if (!_loading) await _newAddress(); // لم يُنشأ عنوان بعد (أول مرة فقط)
      return;
    }
    try {
      // الإشعار من الواجهة فقط لو خدمة الخلفية متوقفة
      final list = await fetchMessages(inbox, notify: _notif && !_bg);
      final fresh = await Store.loadInbox() ?? inbox;
      if (!mounted) return;
      setState(() {
        _mails = list;
        _inbox = fresh;
        _online = true;
      });
      if (manual) toast(list.isEmpty ? 'لا توجد رسائل جديدة' : 'تم التحديث');
    } on TempMailException catch (e) {
      if (!mounted) return;
      setState(() => _online = false);
      if (manual) toast('$e');
    }
  }

  Future<void> _clearAll() async {
    if (_mails.isEmpty) return;
    final ok = await _confirm(
        'مسح كل الرسائل؟', 'سيتم حذف ${_mails.length} رسالة نهائياً.', 'مسح');
    if (ok) await _deleteMails(_mails.map((m) => m.mid).toList());
  }

  bool _isUnread(MailItem m) => !(_inbox?.readMids.contains(m.mid) ?? false);

  void _openMail(MailItem mail) async {
    final updated = await Store.markRead([mail.mid]);
    if (updated != null && mounted) setState(() => _inbox = updated);
    if (!mounted) return;
    final delete = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _MailSheet(inbox: _inbox!, mail: mail),
    );
    if (delete == true) await _deleteMails([mail.mid]);
  }

  Future<void> _confirmDeleteOne(MailItem mail) async {
    final ok = await _confirm('حذف الرسالة؟', mail.subject, 'حذف');
    if (ok) await _deleteMails([mail.mid]);
  }

  void _onPendingOpen() {
    final d = pendingOpen.value;
    if (d == null || _inbox == null) return;
    pendingOpen.value = null;
    _openMail(MailItem(
      mid: '${d['mid'] ?? ''}',
      from: '${d['from'] ?? '?'}',
      to: '${d['to'] ?? ''}',
      subject: '${d['subject'] ?? ''}',
      date: '${d['date'] ?? ''}',
    ));
  }

  // ---------------- الإعدادات ----------------
  Future<void> _setNotif(bool v) async {
    setState(() => _notif = v);
    await Store.setNotif(v);
    if (v) await NotificationService.requestPermission();
  }

  Future<void> _setBg(bool v) async {
    setState(() => _bg = v);
    await Store.setBg(v);
    final svc = FlutterBackgroundService();
    if (v) {
      await NotificationService.requestPermission();
      if (!await svc.isRunning()) await svc.startService();
    } else {
      svc.invoke('stopService');
    }
  }

  void _openSettings() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('الإعدادات',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('إشعارات الرسائل والأكواد'),
                subtitle: const Text('مع أزرار نسخ الكود والرسالة'),
                value: _notif,
                onChanged: (v) async {
                  await _setNotif(v);
                  setSheet(() {});
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('العمل في الخلفية'),
                subtitle:
                    const Text('استقبال الإشعارات حتى لو التطبيق مغلق'),
                value: _bg,
                onChanged: (v) async {
                  await _setBg(v);
                  setSheet(() {});
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.history_rounded),
                title: const Text('العناوين السابقة'),
                subtitle: const Text('الرجوع لعنوان قديم ورسائله'),
                onTap: _showHistory,
              ),
              const SizedBox(height: 8),
              const Text('نطاق العنوان الجديد',
                  style: TextStyle(color: AppColors.muted, fontSize: 13)),
              const SizedBox(height: 6),
              Directionality(
                textDirection: TextDirection.ltr,
                child: DropdownButtonFormField<String>(
                  value: _domain,
                  isExpanded: true,
                  dropdownColor: AppColors.bg2,
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: AppColors.bg2,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.line),
                    ),
                  ),
                  items: [AppConfig.randomDomain, ...AppConfig.domains]
                      .map((d) => DropdownMenuItem(
                            value: d,
                            child: Text(
                                d == AppConfig.randomDomain ? 'random (عشوائي)' : d),
                          ))
                      .toList(),
                  onChanged: (v) async {
                    if (v == null) return;
                    setState(() => _domain = v);
                    await Store.setDomain(v);
                    setSheet(() {});
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------- الواجهة ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -1),
            radius: 1.1,
            colors: [Color(0x407C5CFF), Colors.transparent],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  children: [
                    _topBar(),
                    Expanded(child: _panel()),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    return SizedBox(
      height: 64,
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.remove_red_eye_outlined,
                color: AppColors.gold, size: 22),
          ),
          const SizedBox(width: 10),
          const Directionality(
            textDirection: TextDirection.ltr,
            child: Text.rich(TextSpan(
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
              children: [
                TextSpan(text: 'Odin '),
                TextSpan(text: 'Mail', style: TextStyle(color: AppColors.gold)),
              ],
            )),
          ),
          const Spacer(),
          _PulseDot(color: _online ? AppColors.ok : AppColors.danger),
          const SizedBox(width: 6),
          Text(_online ? 'مباشر' : 'غير متصل',
              style: const TextStyle(color: AppColors.muted, fontSize: 12)),
          IconButton(
            onPressed: _openSettings,
            icon: const Icon(Icons.tune_rounded, color: AppColors.muted),
          ),
        ],
      ),
    );
  }

  Widget _panel() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.line),
        boxShadow: const [
          BoxShadow(color: Color(0x66000000), blurRadius: 40, offset: Offset(0, 20)),
        ],
      ),
      child: Column(
        children: [
          // العنوان
          Container(
            padding: const EdgeInsetsDirectional.fromSTEB(6, 6, 12, 6),
            decoration: BoxDecoration(
              color: AppColors.bg2,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.line),
            ),
            child: Row(
              children: [
                FilledButton(
                  onPressed: _inbox == null
                      ? null
                      : () => copyText(_inbox!.address, 'تم نسخ العنوان ✓'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(9)),
                  ),
                  child: const Text('نسخ'),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Directionality(
                    textDirection: TextDirection.ltr,
                    child: Text(
                      _inbox?.address ?? '...',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.gold,
                        fontSize: 15,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // الأدوات
          Row(
            children: [
              _tool('🔄 عنوان جديد', _loading ? null : _confirmNewAddress),
              const SizedBox(width: 8),
              _tool('📥 تحديث', () => _refresh(manual: true)),
              const SizedBox(width: 8),
              _tool('🗑 مسح الكل', _clearAll),
            ],
          ),
          const SizedBox(height: 8),
          const Divider(height: 1, color: AppColors.line),
          // الصندوق
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: () => _refresh(manual: true),
                    child: _mails.isEmpty
                        ? ListView(children: const [
                            SizedBox(height: 60),
                            Center(
                              child: Text('📭\nفي انتظار الرسائل...',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: AppColors.muted)),
                            ),
                          ])
                        : ListView.builder(
                            padding: const EdgeInsets.only(top: 8),
                            itemCount: _mails.length,
                            itemBuilder: (_, i) => _mailTile(_mails[i]),
                          ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _tool(String label, VoidCallback? onTap) {
    return Expanded(
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.text,
          backgroundColor: AppColors.bg2,
          side: const BorderSide(color: AppColors.line),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: FittedBox(
            child: Text(label, style: const TextStyle(fontSize: 13))),
      ),
    );
  }

  Widget _mailTile(MailItem m) {
    final unread = _isUnread(m);
    final initial = m.from.replaceAll(RegExp(r'[^\w؀-ۿ]'), '');
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _openMail(m),
      onLongPress: () => _confirmDeleteOne(m),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                    colors: [AppColors.accent, AppColors.gold]),
              ),
              child: Text(
                initial.isEmpty ? '؟' : initial[0].toUpperCase(),
                style: const TextStyle(
                    fontWeight: FontWeight.w800, color: AppColors.bg),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(m.from,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: unread ? FontWeight.w800 : FontWeight.w500)),
                  Text(m.subject,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 13)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 80),
                  child: Text(m.date,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 11)),
                ),
                if (unread)
                  Container(
                    margin: const EdgeInsets.only(top: 6),
                    width: 9,
                    height: 9,
                    decoration: const BoxDecoration(
                        color: AppColors.gold, shape: BoxShape.circle),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ======================= شاشة تفاصيل الرسالة =======================
class _MailSheet extends StatefulWidget {
  final Inbox inbox;
  final MailItem mail;
  const _MailSheet({required this.inbox, required this.mail});

  @override
  State<_MailSheet> createState() => _MailSheetState();
}

class _MailSheetState extends State<_MailSheet> {
  late final Future<MailDetail> _future =
      getDetail(widget.inbox, widget.mail.mid);

  @override
  Widget build(BuildContext context) {
    final mail = widget.mail;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
        children: [
          Text(mail.subject,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('من: ${mail.from} • ${mail.date}',
              style: const TextStyle(color: AppColors.muted, fontSize: 13)),
          const SizedBox(height: 16),
          FutureBuilder<MailDetail>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.all(30),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snap.hasError) {
                return Text('تعذر تحميل الرسالة\n${snap.error}',
                    style: const TextStyle(color: AppColors.danger));
              }
              final d = snap.data!;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (d.code != null) _codeCard(d.code!),
                  SelectableText(
                    d.text.isEmpty ? '(الرسالة فارغة)' : d.text,
                    style: const TextStyle(height: 1.6),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (d.code != null)
                        _copyBtn('نسخ الكود', Icons.pin_outlined, d.code!,
                            'تم نسخ الكود ✓'),
                      _copyBtn('نسخ الرسالة', Icons.copy_all_rounded, d.text,
                          'تم نسخ الرسالة ✓'),
                      _copyBtn('نسخ العنوان', Icons.title_rounded, mail.subject,
                          'تم نسخ العنوان ✓'),
                      _copyBtn('نسخ المرسل', Icons.person_outline, mail.from,
                          'تم نسخ المرسل ✓'),
                    ],
                  ),
                  if (d.attachments.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text('مرفقات: ${d.attachments.length}',
                        style: const TextStyle(color: AppColors.muted)),
                  ],
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  style:
                      FilledButton.styleFrom(backgroundColor: AppColors.accent),
                  child: const Text('إغلاق'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: AppColors.card,
                      title: const Text('حذف الرسالة؟'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('إلغاء')),
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('حذف',
                                style: TextStyle(color: AppColors.danger))),
                      ],
                    ),
                  );
                  if (ok == true && context.mounted) {
                    Navigator.of(context).pop(true);
                  }
                },
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('حذف'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.danger,
                  side: const BorderSide(color: AppColors.danger),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _codeCard(String code) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      decoration: BoxDecoration(
        color: AppColors.bg2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.gold.withOpacity(0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('كود التحقق',
                    style: TextStyle(color: AppColors.muted, fontSize: 12)),
                Directionality(
                  textDirection: TextDirection.ltr,
                  child: Text(code,
                      style: const TextStyle(
                          color: AppColors.gold,
                          fontSize: 28,
                          letterSpacing: 4,
                          fontWeight: FontWeight.w800)),
                ),
              ],
            ),
          ),
          IconButton.filled(
            onPressed: () => copyText(code, 'تم نسخ الكود ✓'),
            icon: const Icon(Icons.copy_rounded),
            style: IconButton.styleFrom(backgroundColor: AppColors.accent),
          ),
        ],
      ),
    );
  }

  Widget _copyBtn(String label, IconData icon, String value, String msg) {
    return OutlinedButton.icon(
      onPressed: () => copyText(value, msg),
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.text,
        side: const BorderSide(color: AppColors.line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}

// ======================= نقطة "مباشر" النابضة =======================
class _PulseDot extends StatefulWidget {
  final Color color;
  const _PulseDot({required this.color});

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1500))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: 0.3).animate(_c),
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}

// ======================= main.dart =======================
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.init(
    onResponse: NotificationService.handleResponse,
  );
  await initBackgroundService();
  runApp(const OdinMailApp());
}

class OdinMailApp extends StatelessWidget {
  const OdinMailApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Odin Mail',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: messengerKey,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.bg,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.accent,
          secondary: AppColors.gold,
          surface: AppColors.card,
        ),
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: AppColors.ok,
          contentTextStyle:
              TextStyle(color: Color(0xFF06231A), fontWeight: FontWeight.w700),
        ),
      ),
      // الواجهة عربية من اليمين لليسار
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const HomePage(),
    );
  }
}
