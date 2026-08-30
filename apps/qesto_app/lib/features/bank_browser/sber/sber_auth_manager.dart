import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/bank_browser_models.dart';
import '../runtime/browser_controller.dart';
import 'sber_connector_models.dart';
import 'sber_page_detector.dart';

class SberPinVault {
  const SberPinVault({this._storage = const FlutterSecureStorage()});

  static const key = 'qesto.sber.quick-pin.v1';
  final FlutterSecureStorage _storage;

  Future<String?> read() => _storage.read(key: key);

  Future<void> write(String pin) async {
    final normalized = pin.trim();
    if (!RegExp(r'^\d{4,8}$').hasMatch(normalized)) {
      throw const FormatException('PIN должен содержать от 4 до 8 цифр');
    }
    await _storage.write(key: key, value: normalized);
  }

  Future<void> delete() => _storage.delete(key: key);
}

class SberAuthManager {
  const SberAuthManager({this.pinVault = const SberPinVault()});

  final SberPinVault pinVault;

  Future<SberSyncReport> ensureAuthenticated(
    BrowserController browser,
    SberPageDetector detector,
  ) async {
    var page = await detector.inspect(browser);
    if (page == null) {
      return const SberSyncReport(
        state: SberConnectorState.error,
        message: 'Не удалось определить страницу Сбера.',
      );
    }
    var type = detector.detect(page);
    // An expired Sber SPA session can remain forever on an empty /app/*
    // loading shell. Give an active render a short chance to finish, then
    // return through the bank's official start route so the saved quick PIN
    // flow can resume instead of asking for a full manual login.
    if (type == SberPageType.unknown && page.url.path.startsWith('/app/')) {
      await Future<void>.delayed(const Duration(milliseconds: 2000));
      page = await detector.inspect(browser);
      type = page == null ? SberPageType.unknown : detector.detect(page);
      if (type == SberPageType.unknown) {
        await browser.navigate(browser.bank.startUrl);
        try {
          await browser
              .waitForLoadState(BankBrowserLoadState.finished)
              .timeout(const Duration(seconds: 12));
        } on Object {
          // The next bounded inspection remains authoritative for SPA loads.
        }
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        page = await detector.inspect(browser);
        type = page == null ? SberPageType.unknown : detector.detect(page);
      }
    }
    if (type == SberPageType.dashboard ||
        type == SberPageType.accounts ||
        type == SberPageType.transactions ||
        type == SberPageType.savings ||
        type == SberPageType.deposit ||
        type == SberPageType.investments) {
      return const SberSyncReport(state: SberConnectorState.authenticated);
    }
    if (type != SberPageType.pinLogin ||
        page == null ||
        page.pinConfidence < 0.8) {
      return SberSyncReport(
        state: SberConnectorState.fullLoginRequired,
        message: type == SberPageType.login
            ? 'Сбер требует обычный вход. Введите логин, пароль или код самостоятельно.'
            : 'Страница авторизации Сбера не распознана. Войдите вручную.',
      );
    }
    final pin = await pinVault.read();
    if (pin == null || pin.isEmpty) {
      return const SberSyncReport(
        state: SberConnectorState.pinRequired,
        message:
            'Введите PIN быстрого входа Сбера вручную или сохраните его локально.',
      );
    }
    final result = await _attemptPin(browser, pin);
    if (!result) {
      return const SberSyncReport(
        state: SberConnectorState.fullLoginRequired,
        message: 'Автоматический PIN-вход не подтверждён. Войдите вручную.',
        pinAttempted: true,
      );
    }
    var authenticated = false;
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final after = await detector.inspect(browser);
      final afterType = after == null
          ? SberPageType.unknown
          : detector.detect(after);
      authenticated =
          afterType != SberPageType.login &&
          afterType != SberPageType.pinLogin &&
          afterType != SberPageType.unknown;
      if (authenticated) break;
    }
    return authenticated
        ? const SberSyncReport(
            state: SberConnectorState.authenticated,
            pinAttempted: true,
          )
        : const SberSyncReport(
            state: SberConnectorState.fullLoginRequired,
            message:
                'Сбер не подтвердил завершение PIN-входа. Войдите вручную.',
            pinAttempted: true,
          );
  }

  Future<bool> _attemptPin(BrowserController browser, String pin) async {
    final script =
        '''(() => {
      /* QESTO_SBER_AUTH_V1: click the detected virtual keypad once; no submit/network API. */
      const pin = ${jsonEncode(pin)};
      const visible = (node) => {
        if (!node) return false;
        const style = getComputedStyle(node);
        return style.display !== 'none' && style.visibility !== 'hidden' &&
          node.getBoundingClientRect().width > 0 && node.getBoundingClientRect().height > 0;
      };
      const text = (node) => String(node.getAttribute('data-value') || node.getAttribute('data-key') ||
        node.getAttribute('aria-label') || node.innerText || '').trim();
      // Sber has used both pin-button-N and pin-key-N test ids. Prefer these
      // exact hooks so a digit in an unrelated card label can never be
      // mistaken for a keypad key.
      const findKey = (digit) => {
        const exact = document.querySelector(
          '[data-testid="pin-button-' + digit + '"],[data-testid="pin-key-' + digit + '"],' +
          '[data-test="pin-button-' + digit + '"],[data-test="pin-key-' + digit + '"],' +
          '[data-key="' + digit + '"],[data-value="' + digit + '"]'
        );
        if (exact && visible(exact)) return exact;
        return Array.from(document.querySelectorAll('button,[role="button"],[data-value],[data-key]'))
          .filter(visible)
          .find((node) => /^\\s*[0-9]\\s*\$/.test(text(node)) && text(node).trim() === digit) || null;
      };
      if ([...pin].some((digit) => !findKey(digit))) {
        return JSON.stringify({ok:false, reason:'keypad-not-found'});
      }
      // A digit causes Sber/React to rerender the keypad. Resolve the button
      // again for every digit and space clicks so no detached DOM node or
      // collapsed state update can swallow the rest of the PIN.
      let elapsed = 0;
      [...pin].forEach((digit, index) => {
        if (index > 0) elapsed += 130 + Math.floor(Math.random() * 101);
        setTimeout(() => {
          const key = findKey(digit);
          if (key) key.click();
        }, elapsed);
      });
      // The current PIN page submits automatically after the final digit.
      // Never search for a generic "Войти" button: it matches the unrelated
      // "Войти другим способом" action and leaves the quick-PIN flow.
      return JSON.stringify({ok:true, scheduled:pin.length});
    })()''';
    final raw = await browser
        .evaluateConnectorJavascript(script, mode: BrowserMode.auth)
        .timeout(const Duration(seconds: 5), onTimeout: () => null);
    if (raw is! String) return false;
    try {
      return (jsonDecode(raw) as Map<String, dynamic>)['ok'] == true;
    } on Object {
      return false;
    }
  }
}
