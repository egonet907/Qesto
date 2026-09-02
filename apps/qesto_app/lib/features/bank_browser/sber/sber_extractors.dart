import 'dart:convert';

import '../../../data/models/qesto_models.dart';
import '../runtime/browser_controller.dart';
import 'sber_connector_models.dart';

class SberExtractors {
  const SberExtractors();

  Future<List<SberAccountFact>> accounts(BrowserController browser) async {
    final raw = await browser.evaluateConnectorJavascript(_accountsScript);
    if (raw is! String) return const [];
    return normalizeAccountRows(_decodeRows(raw));
  }

  List<SberAccountFact> normalizeAccountRows(
    Iterable<Map<String, dynamic>> rows,
  ) {
    final normalized = rows
        .map(_accountFromRow)
        .whereType<SberAccountFact>()
        .toList(growable: false);
    final result = <SberAccountFact>[];
    for (final incoming in normalized) {
      final index = result.indexWhere(
        (existing) =>
            existing.id == incoming.id ||
            _accountsAreDirectlyLinked(existing, incoming),
      );
      if (index < 0) {
        result.add(incoming);
      } else {
        result[index] = _mergeAccountFacts(result[index], incoming);
      }
    }
    return result;
  }

  Future<void> hydratePage(
    BrowserController browser, {
    int maxSteps = 24,
  }) async {
    var stationary = 0;
    for (var step = 0; step < maxSteps; step++) {
      final moved = await browser.evaluateConnectorJavascript(
        _hydrationScrollScript,
      );
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      if (moved == '1') {
        stationary = 0;
      } else {
        stationary += 1;
        if (stationary >= 2) break;
      }
    }
    await browser.evaluateConnectorJavascript(_scrollToTopScript);
    await Future<void>.delayed(const Duration(milliseconds: 350));
  }

  Future<SberTransactionExtraction> transactions(
    BrowserController browser, {
    required SberSyncRange range,
    int maxScrolls = 160,
  }) async {
    final byFingerprint = <String, SberTransactionFact>{};
    final rawFingerprints = <String>{};
    final rejectedFingerprints = <String>{};
    final rewardFingerprints = <String>{};
    final serviceFingerprints = <String>{};
    final loyaltyFingerprints = <String>{};
    var previousRawCount = -1;
    var stagnantLoadMoreAttempts = 0;
    var scrollSteps = 0;
    var loadMoreClicks = 0;
    var reachedRangeStart = false;
    var stationaryEndAttempts = 0;
    for (var index = 0; index < maxScrolls; index++) {
      final raw = await browser.evaluateConnectorJavascript(
        _transactionsScript,
      );
      if (raw is String) {
        for (final row in _decodeRows(raw)) {
          final rawFingerprint = _rawRowFingerprint(row);
          rawFingerprints.add(rawFingerprint);
          final observedDate = _rowDate(row);
          if (observedDate != null && observedDate.isBefore(range.from)) {
            reachedRangeStart = true;
          }
          if (row['loyaltyAmount'] is num || row['nonCashKind'] == 'reward') {
            loyaltyFingerprints.add(rawFingerprint);
          }
          final transaction = _transactionFromRow(row, range);
          if (transaction != null) {
            byFingerprint[transaction.fingerprint] = transaction;
          } else if (row['nonCashKind'] == 'reward') {
            rewardFingerprints.add(rawFingerprint);
          } else if (row['nonCashKind'] == 'service') {
            serviceFingerprints.add(rawFingerprint);
          } else {
            rejectedFingerprints.add(rawFingerprint);
          }
        }
      }
      final grew = rawFingerprints.length > previousRawCount;
      if (grew) {
        stationaryEndAttempts = 0;
        stagnantLoadMoreAttempts = 0;
      }
      previousRawCount = rawFingerprints.length;
      if (reachedRangeStart) break;

      // Walk the rendered history in small, overlapping steps. Sber
      // virtualizes this list: jumping straight to the last row or to an
      // off-screen "Показать ещё" button unmounts intermediate operations
      // before the extractor can observe them.
      final moved = await browser.evaluateConnectorJavascript(_scrollScript);
      if (moved is String && moved == '1') {
        scrollSteps += 1;
        stationaryEndAttempts = 0;
        // Sber lazy-renders the next portion of the operation history. A short
        // delay races that render and used to make the connector stop after
        // the first few rows.
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        continue;
      }

      // Pagination is safe only after the incremental walk reaches the end
      // of the currently rendered page. The JS side clicks only a rendered,
      // enabled read-only history control and never a financial action.
      if (stagnantLoadMoreAttempts < 3) {
        final loadedMore = await browser
            .evaluateConnectorJavascript(_loadMoreTransactionsScript)
            .timeout(const Duration(seconds: 5), onTimeout: () => null);
        if (loadedMore == '1') {
          loadMoreClicks += 1;
          stationaryEndAttempts = 0;
          final advanced = await _waitForHistoryAdvance(
            browser,
            knownRawFingerprints: rawFingerprints,
          );
          if (advanced) {
            stagnantLoadMoreAttempts = 0;
            continue;
          }
          stagnantLoadMoreAttempts += 1;
        }
      }
      if (stagnantLoadMoreAttempts >= 3) break;

      // A virtualized list can report the same scroll position while a new
      // page is still being mounted. Require several stable observations
      // before declaring the selected period exhausted.
      stationaryEndAttempts += 1;
      if (stationaryEndAttempts >= 3) break;
      await Future<void>.delayed(const Duration(milliseconds: 1200));
    }
    final result = byFingerprint.values.toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    final hasMore = await browser
        .evaluateConnectorJavascript(_hasMoreTransactionsScript)
        .timeout(const Duration(seconds: 5), onTimeout: () => null);
    return SberTransactionExtraction(
      transactions: result,
      rawRowsSeen: rawFingerprints.length,
      rejectedRows: rejectedFingerprints.length,
      scrollSteps: scrollSteps,
      loadMoreClicks: loadMoreClicks,
      rewardRows: rewardFingerprints.length,
      serviceRows: serviceFingerprints.length,
      loyaltyRewards: loyaltyFingerprints.length,
      rangeBoundaryReached: reachedRangeStart,
      hasMoreRows: hasMore == '1',
    );
  }

  Future<bool> _waitForHistoryAdvance(
    BrowserController browser, {
    required Set<String> knownRawFingerprints,
  }) async {
    for (var attempt = 0; attempt < 10; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final raw = await browser
          .evaluateConnectorJavascript(_transactionsScript)
          .timeout(const Duration(seconds: 5), onTimeout: () => null);
      if (raw is! String) continue;
      for (final row in _decodeRows(raw)) {
        final fingerprint = _rawRowFingerprint(row);
        if (!knownRawFingerprints.contains(fingerprint)) return true;
      }
    }
    return false;
  }

  Future<List<SberTransactionFact>> visibleTransactions(
    BrowserController browser, {
    required SberSyncRange range,
  }) async {
    final raw = await browser.evaluateConnectorJavascript(_transactionsScript);
    if (raw is! String) return const [];
    return normalizeTransactionRows(_decodeRows(raw), range: range);
  }

  List<SberTransactionFact> normalizeTransactionRows(
    Iterable<Map<String, dynamic>> rows, {
    required SberSyncRange range,
  }) {
    final byFingerprint = <String, SberTransactionFact>{};
    for (final row in rows) {
      final transaction = _transactionFromRow(row, range);
      if (transaction != null) {
        byFingerprint[transaction.fingerprint] = transaction;
      }
    }
    final result = byFingerprint.values.toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    return result;
  }

  static List<Map<String, dynamic>> _decodeRows(String raw) {
    try {
      final value = jsonDecode(raw);
      return (value as List? ?? const [])
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
    } on Object {
      return const [];
    }
  }

  static String _rawRowFingerprint(Map<String, dynamic> row) {
    final sourceId = _clean(row['id'] as String?);
    if (sourceId.isNotEmpty) return 'id:$sourceId';
    final observationKey = _clean(row['observationKey'] as String?);
    if (observationKey.isNotEmpty) return 'observation:$observationKey';
    // Ordinals are deliberately excluded. They change whenever Sber recycles
    // virtual-list nodes and previously made the same operation look new.
    return 'fact:${row['dateIso'] ?? row['date']}|${row['amountValue'] ?? row['amount']}|${row['text']}|${row['account']}';
  }

  SberAccountFact? _accountFromRow(Map<String, dynamic> row) {
    final text = _clean(row['text'] as String?);
    final balance = _money(row['balance'] as String? ?? text);
    if (balance == null || text.isEmpty) return null;
    final lower = '${row['kind'] ?? ''} $text'.toLowerCase();
    final type = lower.contains('вклад') || lower.contains('депозит')
        ? AccountType.deposit
        : lower.contains('накоп')
        ? AccountType.savings
        : lower.contains('кредит')
        ? AccountType.liability
        : lower.contains('инвест') || lower.contains('брокер')
        ? AccountType.investment
        : lower.contains('карт')
        ? AccountType.bankCard
        : AccountType.cash;
    final maskedLastFour =
        RegExp(
          r'(?:\*{2,}|X{2,}|•{2,})\s*(\d{4})',
        ).firstMatch(text)?.group(1) ??
        RegExp(
          r'\b(?:сч[её]т|карта)\D{0,24}(\d{4})\b',
          caseSensitive: false,
        ).firstMatch(text)?.group(1);
    final linkedCards =
        (row['cards'] as List? ?? const [])
            .map((value) => _clean(value?.toString()))
            .where((value) => RegExp(r'^\d{4}$').hasMatch(value))
            .toSet()
            .toList(growable: false)
          ..sort();
    final rawName = _clean(row['name'] as String?);
    final name = rawName.isEmpty ? _title(text) : rawName;
    final currency = _currency(text);
    final rawId = _clean(row['id'] as String?);
    final stableIdentity = rawId.isNotEmpty
        ? 'external:$rawId'
        : maskedLastFour != null
        ? 'suffix:$maskedLastFour'
        : linkedCards.isNotEmpty
        ? 'linked:${linkedCards.join(',')}'
        : 'name:${_accountIdentityName(name)}|${type.name}|$currency';
    final id = _stableId('account', stableIdentity);
    return SberAccountFact(
      id: id,
      name: name,
      type: type,
      currency: currency,
      balance: balance,
      availableBalance: _money(row['available'] as String? ?? ''),
      lastFour: maskedLastFour,
      linkedCardLastFours: linkedCards,
      isLiability: type == AccountType.liability,
    );
  }

  static bool _accountsAreDirectlyLinked(
    SberAccountFact left,
    SberAccountFact right,
  ) {
    if (left.currency != right.currency) return false;
    final leftSuffixes = <String>{
      if (left.lastFour != null) left.lastFour!,
      ...left.linkedCardLastFours,
    };
    final rightSuffixes = <String>{
      if (right.lastFour != null) right.lastFour!,
      ...right.linkedCardLastFours,
    };
    if (leftSuffixes.intersection(rightSuffixes).isEmpty) return false;
    return left.linkedCardLastFours.isNotEmpty ||
        right.linkedCardLastFours.isNotEmpty ||
        left.id == right.id;
  }

  static SberAccountFact _mergeAccountFacts(
    SberAccountFact primary,
    SberAccountFact incoming,
  ) {
    final cards = <String>{
      ...primary.linkedCardLastFours,
      ...incoming.linkedCardLastFours,
      if (primary.lastFour != null) primary.lastFour!,
      if (incoming.lastFour != null) incoming.lastFour!,
    }.toList(growable: false)..sort();
    final preferIncoming = incoming.name.length > primary.name.length;
    return SberAccountFact(
      id: primary.id,
      name: preferIncoming ? incoming.name : primary.name,
      type: primary.type == AccountType.cash ? incoming.type : primary.type,
      currency: primary.currency,
      balance: incoming.balance,
      availableBalance: incoming.availableBalance ?? primary.availableBalance,
      lastFour: primary.lastFour ?? incoming.lastFour,
      linkedCardLastFours: cards,
      isLiability: primary.isLiability || incoming.isLiability,
    );
  }

  SberTransactionFact? _transactionFromRow(
    Map<String, dynamic> row,
    SberSyncRange range,
  ) {
    final text = _clean(row['text'] as String?);
    final date = _rowDate(row);
    final normalizedAmount = switch (row['amountValue']) {
      final int value => value,
      final num value => value.round(),
      final String value => int.tryParse(value),
      _ => null,
    };
    final amount = normalizedAmount ?? _money(row['amount'] as String? ?? text);
    if (text.isEmpty ||
        date == null ||
        amount == null ||
        !range.contains(date)) {
      return null;
    }
    final amountText = row['amount'] as String? ?? '';
    final operationType = _clean(row['operationType'] as String?);
    final classificationText = '$text $operationType'.toLowerCase();
    final refund =
        classificationText.contains('возврат') ||
        classificationText.contains('отмена операции');
    final income =
        refund ||
        amountText.trimLeft().startsWith('+') ||
        classificationText.contains('зачислен') ||
        classificationText.contains('зарплат') ||
        classificationText.contains('перевод от') ||
        classificationText.contains('поступлен') ||
        classificationText.contains('входящ') ||
        classificationText.contains('получен');
    final transfer =
        classificationText.contains('перевод') ||
        classificationText.contains('между своими') ||
        classificationText.contains('пополнение') ||
        classificationText.contains('зачислен') ||
        classificationText.contains('сбп');
    final internalTransfer =
        transfer &&
        RegExp(
          r'между\s+(?:своими|собственными)|на\s+сво[юий]\s+(?:карт|сч[её]т)|со\s+своего\s+(?:сч[её]та|карт)',
          caseSensitive: false,
        ).hasMatch(classificationText);
    final status = classificationText.contains('отклон')
        ? 'CANCELLED'
        : classificationText.contains('обработ') ||
              classificationText.contains('ожида')
        ? 'PENDING'
        : refund
        ? 'REFUND'
        : 'POSTED';
    final sourceId = _clean(row['id'] as String?);
    final observationKey = _clean(row['observationKey'] as String?);
    final fingerprint = _stableId(
      'transaction',
      '$sourceId|$date|$amount|$text|${sourceId.isEmpty ? observationKey : ''}',
    );
    final rawMerchant = _clean(row['merchant'] as String?);
    final merchant = _merchantCandidate(rawMerchant);
    final structuredDescription = _clean(row['description'] as String?);
    final rejectedMerchant = rawMerchant.isNotEmpty && merchant == null;
    final description = rejectedMerchant && operationType.isNotEmpty
        ? operationType
        : structuredDescription.isNotEmpty
        ? structuredDescription
        : [
            merchant,
            operationType,
          ].whereType<String>().where((value) => value.isNotEmpty).join(' · ');
    final loyaltyAmount = switch (row['loyaltyAmount']) {
      final num value => value.toDouble(),
      final String value => double.tryParse(value.replaceAll(',', '.')),
      _ => null,
    };
    return SberTransactionFact(
      sourceId: sourceId.isEmpty ? fingerprint : sourceId,
      accountId: _accountId(row['account'] as String?),
      date: date,
      amount: amount.abs(),
      currency: _currency(text),
      description: description.isEmpty ? text : description,
      merchant: merchant,
      category: _clean(row['category'] as String?).isEmpty
          ? null
          : _clean(row['category'] as String?),
      status: status,
      fingerprint: fingerprint,
      isTransfer: transfer,
      isIncome: income,
      isInternalTransfer: internalTransfer,
      operationType: operationType.isEmpty ? null : operationType,
      loyaltyReward: loyaltyAmount == null
          ? null
          : SberLoyaltyReward(amount: loyaltyAmount),
    );
  }

  DateTime? _rowDate(Map<String, dynamic> row) {
    final normalized = DateTime.tryParse(_clean(row['dateIso'] as String?));
    return normalized ??
        _date(row['date'] as String? ?? _clean(row['text'] as String?));
  }

  static String? _merchantCandidate(String? source) {
    final value = _clean(source);
    if (value.isEmpty) return null;
    final normalized = value.toLowerCase().replaceAll('ё', 'е');
    final rewardOnly = RegExp(
      r'^[+\-−]?\s*\d+(?:[,.]\d+)?\s*(?:балл(?:а|ов|ы)?|бонус(?:а|ов|ы)?|спасибо)?$',
    ).hasMatch(normalized);
    final operationLabel = RegExp(
      r'^(?:оплата|входящий перевод|исходящий перевод|перевод по|возврат|отмена операции|списание бонусов|начисление бонусов)',
    ).hasMatch(normalized);
    final rewardLabel = RegExp(
      r'(?:сбер)?спасибо|бонус|балл',
    ).hasMatch(normalized);
    return rewardOnly || operationLabel || rewardLabel ? null : value;
  }

  static String _clean(String? value) =>
      (value ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _accountIdentityName(String value) => _clean(
    value
        .toLowerCase()
        .replaceAll(RegExp(r'(?:\*{2,}|x{2,}|•{2,})\s*\d{4}'), ' ')
        .replaceAll(RegExp(r'\b(?:баланс|остаток|доступно)\b.*'), ' ')
        .replaceAll(RegExp(r'[^a-zа-яё0-9]+'), ' '),
  );

  static String _accountId(String? value) {
    final source = _clean(value);
    return source.isEmpty ? '' : _stableId('account', source);
  }

  static String _title(String text) {
    final parts = text.split(RegExp(r'\s{2,}|\n'))
      ..removeWhere((part) => _money(part) != null);
    return (parts.isEmpty ? text : parts.first).trim();
  }

  static int? _money(String text) {
    final match =
        RegExp(
          r'([+-]?\d[\d\s]*)(?:[,\.](\d{1,2}))?\s*(?:₽|руб\.?|RUB|\$|USD|€|EUR|CNY|¥)',
          caseSensitive: false,
        ).firstMatch(text) ??
        RegExp(
          r'^\s*([+-]?\d[\d\s]*)(?:[,\.](\d{1,2}))?\s*$',
          caseSensitive: false,
        ).firstMatch(text);
    if (match == null) return null;
    final rawWhole = match.group(1)!.replaceAll(RegExp(r'\s'), '');
    final whole = int.tryParse(rawWhole);
    if (whole == null) return null;
    final fraction = int.tryParse((match.group(2) ?? '').padRight(2, '0')) ?? 0;
    // Qesto's legacy financial view stores whole currency units. Preserve the
    // sign and round kopecks only when they materially change the displayed
    // unit (e.g. 1 999,90 ₽ -> 2 000 ₽).
    final rounded = whole.abs() + (fraction >= 50 ? 1 : 0);
    return whole.isNegative ? -rounded : rounded;
  }

  static String _currency(String text) {
    final upper = text.toUpperCase();
    if (upper.contains('USD') || text.contains(r'$')) return 'USD';
    if (upper.contains('EUR') || text.contains('€')) return 'EUR';
    if (upper.contains('CNY') || text.contains('¥')) return 'CNY';
    return 'RUB';
  }

  static DateTime? _date(String text) {
    final now = DateTime.now();
    final lower = text.toLowerCase();
    final relativeDay = lower.contains('позавчера')
        ? 2
        : lower.contains('вчера')
        ? 1
        : lower.contains('сегодня')
        ? 0
        : null;
    if (relativeDay != null) {
      final date = now.subtract(Duration(days: relativeDay));
      return _withTime(date, text);
    }
    final numeric = RegExp(
      r'(\d{1,2})[.\-/](\d{1,2})(?:[.\-/](\d{2,4}))?',
    ).firstMatch(text);
    if (numeric != null) {
      var year = int.tryParse(numeric.group(3) ?? '') ?? now.year;
      if (year < 100) year += 2000;
      if (numeric.group(3) == null) {
        year =
            DateTime(
              now.year,
              int.parse(numeric.group(2)!),
              int.parse(numeric.group(1)!),
            ).isAfter(now)
            ? now.year - 1
            : now.year;
      }
      return _withTime(
        DateTime(
          year,
          int.parse(numeric.group(2)!),
          int.parse(numeric.group(1)!),
        ),
        text,
      );
    }
    const months = {
      'янв': 1,
      'фев': 2,
      'мар': 3,
      'апр': 4,
      'май': 5,
      'июн': 6,
      'июл': 7,
      'авг': 8,
      'сен': 9,
      'окт': 10,
      'ноя': 11,
      'дек': 12,
    };
    final named = RegExp(
      r'(\d{1,2})\s+([а-яё]{3,})\s*(\d{4})?',
      caseSensitive: false,
    ).firstMatch(text.toLowerCase());
    if (named == null) return null;
    final month = months.entries
        .firstWhere(
          (entry) => named.group(2)!.startsWith(entry.key),
          orElse: () => const MapEntry('', 0),
        )
        .value;
    if (month == 0) return null;
    final explicitYear = int.tryParse(named.group(3) ?? '');
    final day = int.parse(named.group(1)!);
    final year =
        explicitYear ??
        (DateTime(now.year, month, day).isAfter(now) ? now.year - 1 : now.year);
    return _withTime(DateTime(year, month, day), text);
  }

  static DateTime _withTime(DateTime date, String text) {
    final time = RegExp(r'\b(\d{1,2}):(\d{2})\b').firstMatch(text);
    return time == null
        ? date
        : DateTime(
            date.year,
            date.month,
            date.day,
            int.parse(time.group(1)!),
            int.parse(time.group(2)!),
          );
  }

  static String _stableId(String prefix, String value) {
    var hash = 2166136261;
    for (final byte in utf8.encode(value.toLowerCase())) {
      hash ^= byte;
      hash = (hash * 16777619) & 0x7fffffff;
    }
    return 'sber-$prefix-${hash.toRadixString(16)}';
  }
}

const _accountsScript = r'''(() => {
  /* QESTO_SBER_READ_V1: structured visible product facts only. */
  const clean = (value) => String(value || '').replace(/\s+/g, ' ').trim();
  const visible = (node) => {
    const s = getComputedStyle(node);
    const rect = node.getBoundingClientRect();
    return s.display !== 'none' && s.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
  };
  const money = /[+\u2212-]?\d[\d\s]*(?:[,\.]\d{1,2})?\s*(?:₽|руб\.?|RUB|\$|USD|€|EUR|CNY|¥)/i;
  const hrefOf = (node) => (node.getAttribute('href') || node.href || '').split('?')[0];
  const routeId = (href) => (href.match(/\/cta\/details\/([^/]+)/i) || [])[1] || '';
  const values = [];
  // A card shown under an account is not another source of capital. Treat
  // the account route as authoritative and keep card suffixes as relations.
  const anchors = Array.from(document.querySelectorAll('a[href*="/app/cta/details/"]')).filter(visible);
  for (const node of anchors) {
    const href = hrefOf(node);
    const aria = clean(node.getAttribute('aria-label'));
    let context = aria || clean(node.innerText);
    let parent = node.parentElement;
    for (let depth = 0; depth < 4 && parent; depth++, parent = parent.parentElement) {
      const candidate = clean(parent.innerText);
      if (candidate && candidate.length <= 700 && money.test(candidate)) context = candidate;
    }
    const balanceHint = (aria.match(/(?:баланс|остаток|доступно)[^0-9+-]*([+-]?\d[\d\s]*(?:[,\.]\d{1,2})?\s*(?:₽|руб\.?|RUB|\$|USD|€|EUR|CNY|¥))/i) || [])[1] || '';
    const balance = balanceHint || (context.match(money) || [])[0] || '';
    if (!balance) continue;
    const kind = 'account';
    const name = (aria.match(/^(.+?)(?:\.?\s+Баланс|\.?\s+Привязана|$)/i) || [])[1] || aria;
    let relationRoot = node.parentElement;
    for (let depth = 0; depth < 4 && relationRoot; depth++) {
      if (relationRoot.querySelectorAll('a[href*="/app/cta/details/"]').length === 1) break;
      relationRoot = relationRoot.parentElement;
    }
    const linkedNodes = relationRoot
      ? Array.from(relationRoot.querySelectorAll('a[href*="/app/cards/details/"],button[aria-label*="карт" i],[role="button"][aria-label*="карт" i]'))
      : [];
    const cards = Array.from(new Set(linkedNodes.flatMap((linked) => {
      const cardText = clean((linked.getAttribute('aria-label') || '') + ' ' + (linked.innerText || ''));
      return Array.from(cardText.matchAll(/(?:\D|^)(\d{4})(?=\D|$)/g)).map((match) => match[1]);
    })));
    values.push({
      id: routeId(href) || node.getAttribute('data-id') || node.getAttribute('data-testid') || '',
      kind,
      name: clean(name),
      text: context.slice(0, 700),
      balance,
      available: (context.match(/(?:доступно|available)[^0-9+-]*([+-]?\d[\d\s]*(?:[,\.]\d{1,2})?\s*(?:₽|руб\.?|RUB|\$|USD|€|EUR|CNY|¥))/i) || [])[1] || '',
      cards,
    });
  }
  return JSON.stringify(values.filter((row, i, all) => all.findIndex((item) => item.id === row.id && item.kind === row.kind) === i).slice(0, 200));
})()''';

const _transactionsScript = r'''(() => {
  /* QESTO_SBER_READ_V1: visible transaction facts, never page internals. */
  const clean = (value) => String(value || '').replace(/\s+/g, ' ').trim();
  const visible = (node) => {
    const s = getComputedStyle(node);
    const rect = node.getBoundingClientRect();
    return s.display !== 'none' && s.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
  };
  const money = /[+-]?\d[\d\s]*(?:[,\.]\d{1,2})?\s*(?:₽|руб\.?|RUB|\$|USD|€|EUR|CNY|¥)/i;
  const rewardMarker = /(?:сбер)?спасибо|бонус(?:а|ов|ы)?|балл(?:а|ов|ы)?/i;
  const signedNumber = /[+\u2212-]\s*\d[\d\s]*(?:[,\.]\d{1,2})?/;
  const labelledReward = /\d[\d\s]*(?:[,\.]\d{1,2})?\s*(?:спасибо|бонус(?:а|ов|ы)?|балл(?:а|ов|ы)?)/i;
  const service = /(?:получить|сформировать|заказать|скачать)?\s*(?:выписк|справк|документ)/i;
  // Restrict textual dates to real Russian month names. The previous generic
  // `number + word` branch treated a loyalty reward such as
  // "+12,45 Московский транспорт" as the impossible date "45 Московский"
  // and discarded the otherwise valid monetary operation.
  const datePattern = /(?:0?[1-9]|[12]\d|3[01])[.\-/](?:0?[1-9]|1[0-2])(?:[.\-/]\d{2,4})?|(?:0?[1-9]|[12]\d|3[01])\s+(?:январ[ья]|феврал[ья]|марта?|апрел[ья]|ма[йя]|июн[ья]|июл[ья]|августа?|сентябр[ья]|октябр[ья]|ноябр[ья]|декабр[ья])(?:\s+\d{4})?|сегодня|вчера|позавчера/i;
  const amountValue = (raw) => {
    const normalized = clean(raw).replace(/[\u00a0\u202f]/g, ' ').replace(/\u2212/g, '-');
    const match = normalized.match(/([+-]?\d[\d ]*)(?:[,\.]([0-9]{1,2}))?/);
    if (!match) return null;
    const whole = Number(match[1].replace(/\s/g, ''));
    if (!Number.isFinite(whole)) return null;
    const fraction = Number(String(match[2] || '').padEnd(2, '0')) || 0;
    return Math.abs(whole) + (fraction >= 50 ? 1 : 0);
  };
  const dateIso = (raw, context) => {
    const source = clean(raw).toLowerCase();
    const now = new Date();
    let date = null;
    if (source.includes('позавчера')) date = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 2);
    else if (source.includes('вчера')) date = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1);
    else if (source.includes('сегодня')) date = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const numeric = source.match(/(\d{1,2})[.\-/](\d{1,2})(?:[.\-/](\d{2,4}))?/);
    if (!date && numeric) {
      let year = numeric[3] ? Number(numeric[3]) : now.getFullYear();
      if (year < 100) year += 2000;
      date = new Date(year, Number(numeric[2]) - 1, Number(numeric[1]));
      if (!numeric[3] && date > now) date.setFullYear(date.getFullYear() - 1);
    }
    const months = {янв:0,фев:1,мар:2,апр:3,май:4,июн:5,июл:6,авг:7,сен:8,окт:9,ноя:10,дек:11};
    const named = source.match(/(\d{1,2})\s+([а-яё]{3,})\s*(\d{4})?/i);
    if (!date && named) {
      const key = Object.keys(months).find((value) => named[2].startsWith(value));
      if (key) {
        date = new Date(Number(named[3] || now.getFullYear()), months[key], Number(named[1]));
        if (!named[3] && date > now) date.setFullYear(date.getFullYear() - 1);
      }
    }
    if (!date || Number.isNaN(date.getTime())) return '';
    const time = clean(context).match(/\b(\d{1,2}):(\d{2})\b/);
    if (time) date.setHours(Number(time[1]), Number(time[2]), 0, 0);
    const two = (value) => String(value).padStart(2, '0');
    return `${date.getFullYear()}-${two(date.getMonth() + 1)}-${two(date.getDate())}T${two(date.getHours())}:${two(date.getMinutes())}:00`;
  };
  const groupedDate = (node) => {
    // The aria label of the enclosing day group is authoritative. Inspect it
    // before row text because rows can start with a signed loyalty amount.
    const labelledGroup = node.closest('ul[aria-label],ol[aria-label]');
    const labelledDate = clean(labelledGroup?.getAttribute('aria-label') || '').match(datePattern)?.[0] || '';
    if (labelledDate) return labelledDate;
    const section = node.closest('section');
    if (section) {
      for (const child of Array.from(section.children)) {
        if (child.contains(node)) continue;
        const value = clean(child.innerText).match(datePattern)?.[0] || '';
        if (value) return value;
      }
    }
    const own = clean(node.innerText).match(datePattern)?.[0] || '';
    if (own) return own;
    let branch = node;
    for (let depth = 0; branch && depth < 5; depth++, branch = branch.parentElement) {
      let sibling = branch.previousElementSibling;
      while (sibling) {
        const value = clean(sibling.innerText).match(datePattern)?.[0] || '';
        if (value) return value;
        sibling = sibling.previousElementSibling;
      }
    }
    return '';
  };
  const directText = (node) => clean(Array.from(node.childNodes || [])
    .filter((child) => child.nodeType === 3)
    .map((child) => child.textContent || '')
    .join(' '));
  const semanticLeaves = (node) => Array.from(node.querySelectorAll(
    'p,span,[aria-label],[data-testid],[data-test]'
  )).map((element) => ({
    element,
    text: directText(element) || clean(element.getAttribute('aria-label') || ''),
  })).filter((entry) => entry.text);
  const rewardNumber = /^[+\u2212-]\s*\d[\d\s]*(?:[,\.]\d{1,2})?$/;
  const genericOperation = /^(?:оплата(?:\s+товаров)?|входящий\s+перевод|исходящий\s+перевод|перевод\s+(?:по|между|на|со)|пополнение|зачисление|возврат|отмена\s+операци|списание\s+бонусов|начисление\s+бонусов|в\s+обработке|исполнено|отменено)/i;
  const validMerchant = (value) => {
    const candidate = clean(value);
    if (!candidate || candidate.length > 180) return false;
    if (money.test(candidate) || datePattern.test(candidate) || rewardNumber.test(candidate)) return false;
    if (rewardMarker.test(candidate) || genericOperation.test(candidate)) return false;
    return /[a-zа-яё]/i.test(candidate);
  };
  const rewardContext = (entry, rowText) => {
    if (rewardMarker.test(rowText)) return true;
    let branch = entry.element.parentElement;
    for (let depth = 0; branch && depth < 3; depth++, branch = branch.parentElement) {
      if (branch.querySelector('svg,[aria-label*="спасибо" i],[data-testid*="bonus" i],[data-test*="bonus" i]')) return true;
    }
    return false;
  };
  const decimalValue = (raw) => {
    const normalized = clean(raw).replace(/[\s\u00a0\u202f]/g, '').replace(/\u2212/g, '-').replace(',', '.');
    const value = Number(normalized);
    return Number.isFinite(value) ? value : null;
  };
  const fallbackSelectors = 'tr,[role="row"],[data-testid*="transaction" i],[data-testid*="operation" i],[data-test*="transaction" i],[data-test*="operation" i],[class*="transaction" i],[class*="operation" i],#HISTORY a[href]';
  const rows = [];
  const operationGroupLink = (node) => {
    const group = node.closest('ul[aria-label],ol[aria-label]');
    return /операци/i.test(clean(group?.getAttribute('aria-label') || ''));
  };
  // CSS attribute-selector flag `i` is ASCII-only in Chromium. It did not
  // match Sber's capitalized Cyrillic aria-label "Операции ...", so links on
  // alternative routes (notably /app/payments/sbp) disappeared completely.
  const operationLinks = Array.from(new Set(document.querySelectorAll(
    'section ul[aria-label] li > a[href],section ol[aria-label] li > a[href],a[href*="/app/operations/details"],a[href*="/app/transfers/sberhub"],a[href*="/app/payments/sbp"]'
  ))).filter((node) => operationGroupLink(node) || /\/app\/(?:operations\/details|transfers\/sberhub|payments\/sbp)/i.test(node.getAttribute('href') || '')).filter(visible);
  const candidates = operationLinks.length > 0
    ? operationLinks
    : Array.from(document.querySelectorAll(fallbackSelectors)).filter(visible);
  candidates.forEach((original, ordinal) => {
    let node = original;
    if (original.matches('a')) {
      node = original.closest('tr,[role="row"],li') || original.parentElement || original;
    }
    if (!node || !visible(node)) return;
    const rawText = String(node.innerText || original.innerText || '');
    const text = clean(rawText);
    const date = groupedDate(node);
    const leaves = semanticLeaves(node);
    const amountLeaf = leaves.find((entry) => money.test(entry.text));
    const amount = amountLeaf?.text.match(money)?.[0] || text.match(money)?.[0] || '';
    let amountRow = amountLeaf?.element.parentElement || null;
    let merchantEntry = null;
    for (let depth = 0; amountRow && depth < 5; depth++, amountRow = amountRow.parentElement) {
      const local = leaves.filter((entry) => amountRow.contains(entry.element));
      merchantEntry = local.find((entry) => entry !== amountLeaf && validMerchant(entry.text)) || null;
      if (merchantEntry) break;
    }
    if (!merchantEntry) merchantEntry = leaves.find((entry) => validMerchant(entry.text)) || null;
    const rewardEntry = leaves.find((entry) =>
      entry !== amountLeaf && rewardNumber.test(entry.text) &&
      (!amountRow || !amountRow.contains(entry.element)) && rewardContext(entry, text)
    ) || null;
    const markerReward = rewardMarker.test(text)
      ? text.match(signedNumber)?.[0] || text.match(labelledReward)?.[0] || ''
      : '';
    const rewardAmount = rewardEntry?.text || markerReward;
    const operationEntry = leaves.find((entry) =>
      entry !== merchantEntry && entry !== amountLeaf && entry !== rewardEntry &&
      genericOperation.test(entry.text)
    ) || null;
    const operationType = operationEntry?.text || '';
    const merchant = merchantEntry?.text || '';
    const description = [merchant, operationType].filter(Boolean).join(' · ');
    const serviceRow = service.test(operationType || text);
    if (!text || !date || (!amount && !rewardAmount && !serviceRow)) return;
    const attrs = (name) => node.getAttribute(name) || original.getAttribute(name) || '';
    const detail = original.getAttribute('href') || '';
    let detailUrl = null;
    try { detailUrl = new URL(detail, window.location.href); } catch (_) {}
    const detailPathId = ((detailUrl?.pathname || detail.split('?')[0]).match(/\/details\/([^/]+)$/i) || [])[1] || '';
    const detailId = detailUrl?.searchParams.get('uohId') ||
      detailUrl?.searchParams.get('srcDocumentId') ||
      detailUrl?.searchParams.get('documentId') ||
      detailUrl?.searchParams.get('operationId') ||
      detailUrl?.searchParams.get('transactionId') || detailPathId;
    let account = attrs('data-account-id') || attrs('data-account') || '';
    const accountLink = node.querySelector('a[href*="/app/cta/details/"]');
    if (!account && accountLink) account = (accountLink.getAttribute('href') || '').split('/').pop() || '';
    rows.push({
      id: attrs('data-operation-id') || attrs('data-transaction-id') || attrs('data-document-id') || attrs('data-uoh-id') || attrs('data-id') || detailId,
      account,
      merchant: attrs('data-merchant') || attrs('data-merchant-name') || merchant,
      category: attrs('data-category') || attrs('data-category-name') || '',
      description,
      operationType,
      text: text.slice(0, 900),
      amount,
      date,
      amountValue: amountValue(amount),
      dateIso: dateIso(date, text),
      observationKey: detail || [date, amount, merchant, operationType, account].join('|'),
      ordinal,
      nonCashKind: !amount && rewardAmount ? 'reward' : !amount && serviceRow ? 'service' : '',
      reward: rewardAmount,
      loyaltyAmount: rewardAmount ? decimalValue(rewardAmount) : null,
    });
  });
  return JSON.stringify(rows.filter((row, index, all) =>
    !row.id || all.findIndex((item) => item.id === row.id) === index
  ).slice(0, 500));
})()''';

const _scrollScript = r'''(() => {
  /* QESTO_SBER_READ_V1: advance a visible read-only history list. */
  const amount = Math.max(Math.min(window.innerHeight * 0.32, 340), 220);
  const rowSelector = 'section ul[aria-label] li > a[href],section ol[aria-label] li > a[href],a[href*="/app/operations/details"],a[href*="/app/transfers/sberhub"],a[href*="/app/payments/sbp"]';
  const rows = Array.from(document.querySelectorAll(rowSelector)).filter((node) => {
    const group = node.closest('ul[aria-label],ol[aria-label]');
    return /операци/i.test(String(group?.getAttribute('aria-label') || '')) ||
      /\/app\/(?:operations\/details|transfers\/sberhub|payments\/sbp)/i.test(node.getAttribute('href') || '');
  });
  const last = rows.length > 0 ? rows[rows.length - 1] : null;
  const targets = [];
  const addScrollableAncestors = (start) => {
    let parent = start?.parentElement || null;
    while (parent) {
      const style = getComputedStyle(parent);
      if (parent.scrollHeight > parent.clientHeight + 24 &&
          /(auto|scroll|overlay)/i.test(style.overflowY)) {
        targets.push(parent);
      }
      parent = parent.parentElement;
    }
  };
  addScrollableAncestors(last);
  const loadMore = Array.from(document.querySelectorAll('button,[role="button"]'))
    .find((node) => /^(?:(?:показать|загрузить|открыть)\s+(?:ещ[её]|больше)|ещ[её]\s+операци)[^\n]{0,40}$/i
      .test(String(node.innerText || node.getAttribute('aria-label') || '').replace(/\s+/g, ' ').trim()));
  addScrollableAncestors(loadMore);
  if (document.scrollingElement) targets.push(document.scrollingElement);
  const uniqueTargets = Array.from(new Set(targets));
  const target = uniqueTargets.find((candidate) => {
    const style = getComputedStyle(candidate);
    const maximum = Math.max(0, candidate.scrollHeight - candidate.clientHeight);
    return maximum > candidate.scrollTop + 1 &&
      (candidate === document.scrollingElement || /(auto|scroll|overlay)/i.test(style.overflowY));
  });
  if (!target) return '0';
  const before = target.scrollTop;
  const maximum = Math.max(0, target.scrollHeight - target.clientHeight);
  target.scrollTop = Math.min(before + amount, maximum);
  target.dispatchEvent(new Event('scroll', {bubbles: true}));
  return String(target.scrollTop > before ? 1 : 0);
})()''';

const _loadMoreTransactionsScript = r'''(() => {
  /* QESTO_SBER_READ_V1: expand only the read-only operation history. */
  const clean = (value) => String(value || '').replace(/\s+/g, ' ').trim();
  const visible = (node) => {
    const style = getComputedStyle(node);
    const rect = node.getBoundingClientRect();
    return style.display !== 'none' && style.visibility !== 'hidden' &&
      rect.width > 0 && rect.height > 0 && !node.disabled;
  };
  const matches = Array.from(document.querySelectorAll('button,[role="button"]'))
    .filter(visible)
    .filter((node) => /^(?:(?:показать|загрузить|открыть)\s+(?:ещ[её]|больше)|ещ[её]\s+операци)[^\n]{0,40}$/i.test(clean(node.innerText || node.getAttribute('aria-label'))));
  if (matches.length === 0) return '0';
  const operationRows = Array.from(document.querySelectorAll(
    'section ul[aria-label] li > a[href],section ol[aria-label] li > a[href],a[href*="/app/operations/details"],a[href*="/app/transfers/sberhub"],a[href*="/app/payments/sbp"]'
  )).filter((node) => {
    const group = node.closest('ul[aria-label],ol[aria-label]');
    return /операци/i.test(String(group?.getAttribute('aria-label') || '')) ||
      /\/app\/(?:operations\/details|transfers\/sberhub|payments\/sbp)/i.test(node.getAttribute('href') || '');
  });
  const lastRow = operationRows.length > 0 ? operationRows[operationRows.length - 1] : null;
  if (lastRow) {
    const rowBottom = lastRow.getBoundingClientRect().bottom;
    matches.sort((left, right) =>
      Math.abs(left.getBoundingClientRect().top - rowBottom) -
      Math.abs(right.getBoundingClientRect().top - rowBottom));
  }
  const button = matches[0];
  button.click();
  return '1';
})()''';

const _hasMoreTransactionsScript = r'''(() => {
  /* QESTO_SBER_READ_V1: detect remaining read-only history pagination. */
  const clean = (value) => String(value || '').replace(/\s+/g, ' ').trim();
  const matches = Array.from(document.querySelectorAll('button,[role="button"]'))
    .filter((node) => !node.disabled)
    .some((node) => /^(?:(?:показать|загрузить|открыть)\s+(?:ещ[её]|больше)|ещ[её]\s+операци)[^\n]{0,40}$/i
      .test(clean(node.innerText || node.getAttribute('aria-label'))));
  return String(matches ? 1 : 0);
})()''';

const _hydrationScrollScript = r'''(() => {
  /* QESTO_SBER_READ_V1: slowly expose lazy dashboard sections. */
  const candidates = [document.scrollingElement, ...Array.from(document.querySelectorAll('*'))]
    .filter((node) => node && node.scrollHeight > node.clientHeight + 24 && getComputedStyle(node).overflowY !== 'hidden')
    .sort((left, right) => (right.scrollHeight - right.clientHeight) - (left.scrollHeight - left.clientHeight));
  const target = candidates[0] || document.scrollingElement;
  if (!target) return '0';
  const before = target.scrollTop;
  const amount = Math.max(240, Math.min(360, window.innerHeight * 0.32));
  target.scrollTop = Math.min(target.scrollTop + amount, target.scrollHeight);
  return String(target.scrollTop > before ? 1 : 0);
})()''';

const _scrollToTopScript = r'''(() => {
  /* QESTO_SBER_READ_V1: leave the bank page in a predictable position. */
  const candidates = [document.scrollingElement, ...Array.from(document.querySelectorAll('*'))]
    .filter((node) => node && node.scrollHeight > node.clientHeight + 24 && getComputedStyle(node).overflowY !== 'hidden')
    .sort((left, right) => (right.scrollHeight - right.clientHeight) - (left.scrollHeight - left.clientHeight));
  const target = candidates[0] || document.scrollingElement;
  if (!target) return '0';
  target.scrollTop = 0;
  return '1';
})()''';
