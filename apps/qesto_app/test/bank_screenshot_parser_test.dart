import 'package:flutter_test/flutter_test.dart';
import 'package:qesto/features/bank_screenshot_import/domain/bank_screenshot_models.dart';
import 'package:qesto/features/bank_screenshot_import/services/bank_screenshot_import_service.dart';

void main() {
  const parser = BankScreenshotImportService();

  BankScreenshotTextLine line(String text, double top, [double left = 120]) =>
      BankScreenshotTextLine(text: text, top: top, left: left);

  test('парсит экран Сбера, восстанавливает 700 и игнорирует промо', () {
    final result = parser.parseAll([
      ExtractedBankScreenshot(
        imageHash: 'fixture-image-a',
        capturedAt: DateTime(2026, 8, 31, 13, 38),
        lines: [
          line('BPA 629 KHIMKI RUS', 228),
          line('Оплата товаров и услуг', 264),
          line('Платёжный счёт: 2 265,30 ₽', 304),
          line('Дмитрий Аркадьевич Л.', 387),
          line('1 349 ₽', 388, 456),
          line('Перевод по запросу СБП', 424),
          line('Платёжный счёт: 2 965,30 ₽', 465),
          line('+32 ₽', 549, 479),
          line('YANDEX*7999*SCOOTERS MOSCOW RUS', 582),
          line('Возврат, отмена операций', 616),
          line('Платёжный счёт: 4 314,30 ₽', 659),
          line('200 ₽', 742, 478),
          line('YANDEX*7999*SCOOTERS MOSCOW RUS', 776),
          line('Оплата товаров и услуг', 812),
          line('Платёжный счёт: 4 282,30 ₽', 852),
          line('Ваши привилегии могут измениться', 937),
          line('Перейти в раздел', 1076),
          line('Пятёрочка', 1152),
          line('Оплата товаров и услуг', 1189),
          line('Платёжный счёт: 4 482,30 ₽', 1230),
        ],
      ),
    ]);

    expect(result.candidates, hasLength(4));
    expect(result.candidates[0].amountMinor, 70000);
    expect(result.candidates[0].confidence, lessThan(0.9));
    expect(result.candidates[1].kind, BankScreenshotTransactionKind.transfer);
    expect(result.candidates[1].amountMinor, 134900);
    expect(result.candidates[2].kind, BankScreenshotTransactionKind.refund);
    expect(result.candidates[2].amountMinor, 3200);
    expect(result.candidates[3].categoryId, 'transport');
    expect(
      result.candidates.where((item) => item.merchant.contains('привилег')),
      isEmpty,
    );
  });

  test('перекрывающиеся скриншоты не создают дубль в пакете', () {
    final lines = [
      line('YANDEX SCOOTERS', 10),
      line('Оплата товаров и усуг', 20),
      line('200 ₽', 10, 500),
      line('Платёжный счёт: 4 282,30 ₽', 30),
    ];
    final documents = [
      for (final hash in ['a', 'b'])
        ExtractedBankScreenshot(
          imageHash: hash,
          capturedAt: DateTime(2026, 8, 31),
          lines: lines,
        ),
    ];
    expect(parser.parseAll(documents).candidates, hasLength(1));
  });

  test('generic parser reads date separators, time and signed amounts', () {
    final result = parser.parseAll([
      ExtractedBankScreenshot(
        imageHash: 'unknown-bank',
        capturedAt: DateTime(2026, 8, 31),
        lines: [
          line('29 августа', 10),
          line('ВкусВилл', 30),
          line('−1 430 ₽ 12:43', 30, 450),
          line('Перевод от Анны', 60),
          line('+5 000 ₽ 11:10', 60, 450),
        ],
      ),
    ]);

    expect(result.candidates, hasLength(2));
    expect(result.candidates.first.parserId, 'generic-bank-history-v1');
    expect(result.candidates.first.date, DateTime(2026, 8, 29, 12, 43));
    expect(result.candidates.first.categoryId, 'groceries');
    expect(result.candidates.last.kind, BankScreenshotTransactionKind.income);
  });
}
