import '../domain/bank_screenshot_models.dart';
import 'bank_screenshot_parser.dart';
import 'generic_bank_screenshot_parser.dart';
import 'sber_bank_screenshot_parser.dart';

class BankScreenshotImportService {
  const BankScreenshotImportService({
    this.sberParser = const SberBankScreenshotParser(),
    this.genericParser = const GenericBankScreenshotParser(),
  });

  final SberBankScreenshotParser sberParser;
  final GenericBankScreenshotParser genericParser;

  BankScreenshotParseResult parseAll(
    Iterable<ExtractedBankScreenshot> documents,
  ) {
    final candidates = <String, BankScreenshotCandidate>{};
    final warnings = <String>[];
    for (final document in documents) {
      final parsers = <BankScreenshotParser>[sberParser, genericParser]
        ..sort(
          (left, right) => right
              .confidenceFor(document)
              .compareTo(left.confidenceFor(document)),
        );
      final selected = sberParser.confidenceFor(document) >= 0.5
          ? sberParser
          : parsers.first;
      final result = selected.parse(document);
      warnings.addAll(result.warnings);
      for (final candidate in result.candidates) {
        candidates.putIfAbsent(candidate.id, () => candidate);
      }
    }
    return BankScreenshotParseResult(
      candidates: candidates.values.toList(growable: false),
      warnings: warnings.toSet().toList(growable: false),
    );
  }
}
