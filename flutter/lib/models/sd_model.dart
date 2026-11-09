import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:flutter_hbb/models/platform_model.dart';

/// Service Desk в клиенте EvmDesk (ветка sctg-servicedesk).
/// Ходит в тот же apimain, что и остальной клиент: Bearer access_token.

class SdTicket {
  final int id;
  final String number;
  final String subject;
  final String category;
  final String kind;
  final int priority;
  final String status;
  final int assigneeId;
  final String clientName;
  final String inn;
  final int lastMessageAt;
  final int closedAt;

  const SdTicket({
    required this.id,
    required this.number,
    required this.subject,
    required this.category,
    required this.kind,
    required this.priority,
    required this.status,
    required this.assigneeId,
    required this.clientName,
    required this.inn,
    required this.lastMessageAt,
    required this.closedAt,
  });

  factory SdTicket.fromJson(Map<String, dynamic> j) => SdTicket(
        id: (j['id'] ?? 0) as int,
        number: (j['number'] ?? '') as String,
        subject: (j['subject'] ?? '') as String,
        category: (j['category'] ?? 'incident') as String,
        kind: (j['kind'] ?? '') as String,
        priority: (j['priority'] ?? 2) as int,
        status: (j['status'] ?? 'new') as String,
        assigneeId: (j['assignee_id'] ?? 0) as int,
        clientName: (j['client_name'] ?? '') as String,
        inn: (j['inn'] ?? '') as String,
        lastMessageAt: (j['last_message_at'] ?? 0) as int,
        closedAt: (j['closed_at'] ?? 0) as int,
      );

  String get statusTitle {
    switch (status) {
      case 'new':
        return 'Новое';
      case 'open':
        return 'В работе';
      case 'waiting':
        return 'Ждём вашего ответа';
      case 'resolved':
        return 'Решено';
      case 'closed':
        return 'Закрыто';
    }
    return status;
  }

  String get categoryTitle {
    switch (category) {
      case 'request':
        return 'Заявка';
      case 'question':
        return 'Вопрос';
    }
    return 'Обращение';
  }

  bool get isClosed => status == 'closed';
}

class SdMessage {
  final int id;
  final int ticketId;
  final int authorId;
  final String authorRole;
  final String authorName;
  final String text;
  final String eventType;
  final int createdAt;

  const SdMessage({
    required this.id,
    required this.ticketId,
    required this.authorId,
    required this.authorRole,
    required this.authorName,
    required this.text,
    required this.eventType,
    required this.createdAt,
  });

  factory SdMessage.fromJson(Map<String, dynamic> j) => SdMessage(
        id: (j['id'] ?? 0) as int,
        ticketId: (j['ticket_id'] ?? 0) as int,
        authorId: (j['author_id'] ?? 0) as int,
        authorRole: (j['author_role'] ?? '') as String,
        authorName: (j['author_name'] ?? '') as String,
        text: (j['text'] ?? '') as String,
        eventType: (j['event_type'] ?? 'text') as String,
        createdAt: _ts(j['created_at']),
      );

  bool get isSystem => eventType == 'system' || authorRole == 'system';
  bool get isClient => authorRole == 'client';
}

int _ts(dynamic v) {
  if (v is int) return v;
  if (v is String) return DateTime.tryParse(v)?.millisecondsSinceEpoch ?? 0;
  return 0;
}

class SdApiException implements Exception {
  final String message;
  SdApiException(this.message);
  @override
  String toString() => message;
}

class SdApi {
  static String get _token =>
      bind.mainGetLocalOption(key: 'access_token') ?? '';

  static bool get isLoggedIn => _token.isNotEmpty;

  static Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      };

  static Future<dynamic> _request(
      String method, String path, [Map<String, dynamic>? body]) async {
    if (_token.isEmpty) {
      throw SdApiException('Войдите в аккаунт EvmDesk, чтобы обращаться в поддержку');
    }
    final base = await bind.mainGetApiServer();
    final uri = Uri.parse('$base/api/support$path');
    http.Response resp;
    try {
      if (method == 'POST') {
        resp = await http
            .post(uri, headers: _headers, body: json.encode(body ?? {}))
            .timeout(const Duration(seconds: 20));
      } else {
        resp = await http
            .get(uri, headers: _headers)
            .timeout(const Duration(seconds: 20));
      }
    } catch (e) {
      throw SdApiException('Нет связи с сервером: $e');
    }
    dynamic data;
    try {
      data = json.decode(utf8.decode(resp.bodyBytes));
    } catch (_) {
      throw SdApiException('Некорректный ответ сервера (${resp.statusCode})');
    }
    if (resp.statusCode != 200) {
      final err = (data is Map && data['error'] != null)
          ? data['error'].toString()
          : 'Ошибка ${resp.statusCode}';
      throw SdApiException(err);
    }
    if (data is Map && data['code'] != null && data['code'] != 0) {
      throw SdApiException((data['message'] ?? 'Ошибка').toString());
    }
    return (data is Map) ? data['data'] : data;
  }

  static Future<List<SdTicket>> tickets({String status = ''}) async {
    final q = status.isEmpty ? '' : '?status=$status';
    final data = await _request('GET', '/tickets$q');
    final list = (data is Map && data['list'] is List) ? data['list'] as List : [];
    return list
        .map((e) => SdTicket.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<SdTicket> create({
    required String subject,
    required String text,
    String category = 'incident',
    String kind = '',
    int priority = 2,
    String peerId = '',
    String inn = '',
  }) async {
    final data = await _request('POST', '/tickets', {
      'subject': subject,
      'text': text,
      'category': category,
      'kind': kind,
      'priority': priority,
      'peer_id': peerId,
      'inn': inn,
    });
    return SdTicket.fromJson(data as Map<String, dynamic>);
  }

  static Future<(SdTicket, List<SdMessage>)> ticket(int id,
      {int after = 0}) async {
    final data = await _request('GET', '/tickets/$id?after=$after');
    final map = data as Map<String, dynamic>;
    final ticket = SdTicket.fromJson(map['ticket'] as Map<String, dynamic>);
    final list = (map['messages'] is List) ? map['messages'] as List : [];
    return (
      ticket,
      list.map((e) => SdMessage.fromJson(e as Map<String, dynamic>)).toList()
    );
  }

  static Future<SdMessage> send(int id, String text) async {
    final data = await _request('POST', '/tickets/$id/messages', {'text': text});
    return SdMessage.fromJson(data as Map<String, dynamic>);
  }

  static Future<void> close(int id) async {
    await _request('POST', '/tickets/$id/close', {});
  }
}
