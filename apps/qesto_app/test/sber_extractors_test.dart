import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:qesto/features/bank_browser/config/bank_connector_registry.dart';
import 'package:qesto/features/bank_browser/data/browser_profile_manager.dart';
import 'package:qesto/features/bank_browser/domain/bank_browser_models.dart';
import 'package:qesto/features/bank_browser/runtime/browser_controller.dart';
import 'package:qesto/features/bank_browser/sber/sber_connector_models.dart';
import 'package:qesto/features/bank_browser/sber/sber_extractors.dart';

void main() {
  const extractors = SberExtractors();
  final range = SberSyncRange(
    from: DateTime(2026, 8),
    toExclusive: DateTime(2026, 9),
    label: 'Август',
  );

  Map<String, dynamic> row({
    required String id,
    required String date,
    required int? amount,
    required String amountText,
    required String text,
    required String merchant,
    required String operationType,
    double? loyaltyAmount,
    String nonCashKind = '',
  }) => {
    'id': id,
    'dateIso': date,
    'date': date,
    'amountValue': amount,
    'amount': amountText,
    'text': text,
    'merchant': merchant,
    'description': merchant.isEmpty
        ? operationType
        : '$merchant · $operationType',
    'operationType': operationType,
    'loyaltyAmount': loyaltyAmount,
    'nonCashKind': nonCashKind,
    'ordinal': 0,
  };

  test('normalizes merchant, reward metadata and financial direction', () {
    final transactions = extractors.normalizeTransactionRows([
      row(
        id: 'purchase',
        date: '2026-08-10T12:00:00',
        amount: 500,
        amountText: '500 ₽',
        text: 'Самокаты +6 500 ₽ Оплата товаров и услуг',
        merchant: 'Самокаты',
        operationType: 'Оплата товаров и услуг',
        loyaltyAmount: 6,
      ),
      row(
        id: 'incoming',
        date: '2026-08-11T12:00:00',
        amount: 10000,
        amountText: '+10 000 ₽',
        text: 'Перевод от другого человека +10 000 ₽ Входящий перевод',
        merchant: 'Перевод от другого человека',
        operationType: 'Входящий перевод',
      ),
      row(
        id: 'outgoing',
        date: '2026-08-12T12:00:00',
        amount: 4000,
        amountText: '4 000 ₽',
        text: 'Получатель 4 000 ₽ Перевод по СБП',
        merchant: 'Получатель',
        operationType: 'Перевод по СБП',
      ),
      row(
        id: 'internal',
        date: '2026-08-13T12:00:00',
        amount: 20000,
        amountText: '20 000 ₽',
        text: 'Перевод между своими счетами 20 000 ₽',
        merchant: 'Между счетами',
        operationType: 'Перевод между своими счетами',
      ),
      row(
        id: 'refund',
        date: '2026-08-14T12:00:00',
        amount: 700,
        amountText: '700 ₽',
        text: 'Магазин 700 ₽ Возврат, отмена операций',
        merchant: 'Магазин',
        operationType: 'Возврат, отмена операций',
      ),
      row(
        id: 'reward-only',
        date: '2026-08-15T12:00:00',
        amount: null,
        amountText: '',
        text: 'Магазин +5 Начисление бонусов',
        merchant: 'Магазин',
        operationType: 'Начисление бонусов',
        loyaltyAmount: 5,
        nonCashKind: 'reward',
      ),
    ], range: range);

    expect(transactions, hasLength(5));
    final purchase = transactions.firstWhere(
      (item) => item.sourceId == 'purchase',
    );
    expect(purchase.merchant, 'Самокаты');
    expect(purchase.description, 'Самокаты · Оплата товаров и услуг');
    expect(purchase.loyaltyReward?.amount, 6);
    expect(purchase.description, isNot(contains('+6')));
    expect(purchase.direction, SberTransactionDirection.outflow);

    final incoming = transactions.firstWhere(
      (item) => item.sourceId == 'incoming',
    );
    expect(incoming.direction, SberTransactionDirection.inflow);
    expect(incoming.isTransfer, isTrue);
    expect(incoming.isInternalTransfer, isFalse);

    final outgoing = transactions.firstWhere(
      (item) => item.sourceId == 'outgoing',
    );
    expect(outgoing.direction, SberTransactionDirection.outflow);
    expect(outgoing.isTransfer, isTrue);
    expect(outgoing.isInternalTransfer, isFalse);

    final internal = transactions.firstWhere(
      (item) => item.sourceId == 'internal',
    );
    expect(internal.isInternalTransfer, isTrue);

    final refund = transactions.firstWhere((item) => item.sourceId == 'refund');
    expect(refund.status, 'REFUND');
    expect(refund.direction, SberTransactionDirection.inflow);
  });

  test('rejects reward-looking merchant and respects selected period', () {
    final transactions = extractors.normalizeTransactionRows([
      row(
        id: 'bad-merchant',
        date: '2026-08-20T12:00:00',
        amount: 83,
        amountText: '83 ₽',
        text: '+0,6 Самокаты 83 ₽ Оплата товаров и услуг',
        merchant: '+0,6',
        operationType: 'Оплата товаров и услуг',
      ),
      row(
        id: 'outside',
        date: '2026-07-31T12:00:00',
        amount: 100,
        amountText: '100 ₽',
        text: 'Магазин 100 ₽ Оплата товаров и услуг',
        merchant: 'Магазин',
        operationType: 'Оплата товаров и услуг',
      ),
    ], range: range);

    expect(transactions, hasLength(1));
    expect(transactions.single.merchant, isNull);
    expect(transactions.single.description, 'Оплата товаров и услуг');
  });

  test(
    'history scrolling stops as soon as an older date is observed',
    () async {
      final browser = _HistoryBoundaryBrowser(
        jsonEncode([
          row(
            id: 'inside',
            date: '2026-08-10T12:00:00',
            amount: 500,
            amountText: '500 ₽',
            text: 'Магазин 500 ₽ Оплата товаров и услуг',
            merchant: 'Магазин',
            operationType: 'Оплата товаров и услуг',
          ),
          row(
            id: 'older',
            date: '2026-07-31T12:00:00',
            amount: 200,
            amountText: '200 ₽',
            text: 'Магазин 200 ₽ Оплата товаров и услуг',
            merchant: 'Магазин',
            operationType: 'Оплата товаров и услуг',
          ),
        ]),
      );

      final result = await extractors.transactions(
        browser,
        range: range,
        maxScrolls: 10,
      );

      expect(result.transactions, hasLength(1));
      expect(browser.historyReads, 1);
      expect(browser.scrollAttempts, 0);
    },
  );
}

class _HistoryBoundaryBrowser extends BrowserController {
  _HistoryBoundaryBrowser(this.payload)
    : super(
        profile: BankProfile(
          id: 'sber-test-profile',
          bankId: 'sber',
          displayName: 'Сбер',
          createdAt: DateTime(2026),
          lastOpenedAt: DateTime(2026),
          lastKnownUrl: Uri.parse('https://online.sberbank.ru/app/operations'),
        ),
        bank: BankConnectorRegistry.sber,
        profileManager: BrowserProfileManager(),
        onNotice: (_) {},
      );

  final String payload;
  var historyReads = 0;
  var scrollAttempts = 0;

  @override
  Future<dynamic> evaluateConnectorJavascript(
    String script, {
    BrowserMode mode = BrowserMode.read,
  }) async {
    if (script.contains('visible transaction facts')) {
      historyReads += 1;
      return payload;
    }
    if (script.contains('advance a visible read-only history list')) {
      scrollAttempts += 1;
      return '1';
    }
    return '0';
  }
}
