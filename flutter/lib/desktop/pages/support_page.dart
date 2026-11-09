import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/sd_model.dart';

/// Раздел «Поддержка» клиента EvmDesk: обращения, заявки и чат с оператором.
class SupportPage extends StatefulWidget {
  const SupportPage({Key? key}) : super(key: key);

  @override
  State<SupportPage> createState() => _SupportPageState();
}

class _SupportPageState extends State<SupportPage> {
  List<SdTicket> _tickets = [];
  SdTicket? _current;
  List<SdMessage> _messages = [];
  int _lastMessageId = 0;
  bool _loading = true;
  bool _sending = false;
  String? _error;
  Timer? _poll;
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadTickets();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _pollCurrent());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadTickets() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await SdApi.tickets();
      if (!mounted) return;
      setState(() {
        _tickets = list;
        _loading = false;
      });
      if (_current == null && list.isNotEmpty) {
        await _open(list.first);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _open(SdTicket t) async {
    setState(() {
      _current = t;
      _messages = [];
      _lastMessageId = 0;
      _error = null;
    });
    await _refreshCurrent(full: true);
  }

  Future<void> _refreshCurrent({bool full = false}) async {
    final t = _current;
    if (t == null) return;
    try {
      final (ticket, msgs) = await SdApi.ticket(t.id, after: full ? 0 : _lastMessageId);
      if (!mounted) return;
      setState(() {
        _current = ticket;
        if (full) {
          _messages = msgs;
        } else if (msgs.isNotEmpty) {
          _messages = [..._messages, ...msgs];
        }
        if (_messages.isNotEmpty) {
          _lastMessageId = _messages.last.id;
        }
        final i = _tickets.indexWhere((x) => x.id == ticket.id);
        if (i >= 0) _tickets[i] = ticket;
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _pollCurrent() async {
    if (_current == null || !mounted) return;
    await _refreshCurrent();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _send() async {
    final t = _current;
    final text = _inputCtrl.text.trim();
    if (t == null || text.isEmpty || _sending || t.isClosed) return;
    setState(() => _sending = true);
    try {
      await SdApi.send(t.id, text);
      _inputCtrl.clear();
      await _refreshCurrent();
      await _loadTickets();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _closeTicket() async {
    final t = _current;
    if (t == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Закрыть обращение?'),
        content: Text('${t.number} — ${t.subject}\n\n'
            'Если проблема вернётся, создайте новое обращение.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Закрыть')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await SdApi.close(t.id);
      await _refreshCurrent(full: true);
      await _loadTickets();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _createTicket() async {
    final subject = TextEditingController();
    final text = TextEditingController();
    String category = 'incident';
    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('Новое обращение'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: subject,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Тема'),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: category,
                  decoration: const InputDecoration(labelText: 'Тип'),
                  items: const [
                    DropdownMenuItem(value: 'incident', child: Text('Обращение — что-то не работает')),
                    DropdownMenuItem(value: 'request', child: Text('Заявка — нужна работа')),
                    DropdownMenuItem(value: 'question', child: Text('Вопрос')),
                  ],
                  onChanged: (v) => setDlg(() => category = v ?? 'incident'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: text,
                  minLines: 3,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: 'Описание',
                    alignLabelWithHint: true,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Создать')),
          ],
        ),
      ),
    );
    if (created != true) return;
    if (subject.text.trim().isEmpty && text.text.trim().isEmpty) return;
    try {
      final t = await SdApi.create(
        subject: subject.text.trim(),
        text: text.text.trim(),
        category: category,
        peerId: await bind.mainGetMyId(),
      );
      await _loadTickets();
      await _open(t);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Поддержка'),
        actions: [
          IconButton(
            tooltip: 'Обновить',
            onPressed: _loadTickets,
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 4),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: _createTicket,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Новое обращение'),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Row(
              children: [
                SizedBox(width: 320, child: _buildList()),
                const VerticalDivider(width: 1),
                Expanded(child: _buildDetail()),
              ],
            ),
    );
  }

  Widget _buildList() {
    if (_tickets.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Обращений пока нет', textAlign: TextAlign.center),
        ),
      );
    }
    return ListView.separated(
      itemCount: _tickets.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final t = _tickets[i];
        final selected = _current?.id == t.id;
        return ListTile(
          selected: selected,
          title: Text(t.subject, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${t.number} · ${t.statusTitle}',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: t.isClosed
              ? const Icon(Icons.check_circle_outline, size: 18)
              : null,
          onTap: () => _open(t),
        );
      },
    );
  }

  Widget _buildDetail() {
    final t = _current;
    if (t == null) {
      return const Center(child: Text('Выберите обращение или создайте новое'));
    }
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${t.number} · ${t.categoryTitle}',
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 2),
                    Text(t.subject,
                        style: Theme.of(context).textTheme.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              Chip(label: Text(t.statusTitle), visualDensity: VisualDensity.compact),
              if (!t.isClosed)
                TextButton(onPressed: _closeTicket, child: const Text('Закрыть')),
            ],
          ),
        ),
        const Divider(height: 1),
        if (_error != null)
          Container(
            width: double.infinity,
            color: Colors.red.withOpacity(0.08),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
        Expanded(
          child: _messages.isEmpty
              ? const Center(child: Text('Сообщений пока нет'))
              : ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.all(16),
                  itemCount: _messages.length,
                  itemBuilder: (_, i) => _bubble(_messages[i]),
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _inputCtrl,
                  enabled: !t.isClosed,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: t.isClosed
                        ? 'Обращение закрыто'
                        : 'Напишите сообщение…',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: t.isClosed || _sending ? null : _send,
                child: _sending
                    ? const SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Отправить'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _bubble(SdMessage m) {
    if (m.isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: Text(m.text,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center),
        ),
      );
    }
    final mine = m.isClient;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 560),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: mine
              ? Theme.of(context).colorScheme.primary.withOpacity(0.12)
              : Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(m.authorName.isEmpty ? (mine ? 'Вы' : 'Оператор') : m.authorName,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 3),
            SelectableText(m.text),
          ],
        ),
      ),
    );
  }
}
