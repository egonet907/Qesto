import '../runtime/browser_controller.dart';

class SberNavigator {
  const SberNavigator();

  Future<bool> openDashboard(BrowserController browser) => _open(
    browser,
    const ['главная', 'на главную'],
    hrefHints: const ['/app/main', '/main'],
  );

  Future<bool> openAccounts(BrowserController browser) => _open(
    browser,
    const [
      'все счета',
      'все счета и карты',
      'счета и карты',
      'счета',
      'мои счета',
    ],
    hrefHints: const ['/app/wallet', '/app/accounts'],
  );

  Future<bool> openTransactions(BrowserController browser) => _open(
    browser,
    const ['операции', 'история операций', 'транзакции', 'история'],
    hrefHints: const ['/app/operations', '/app/history'],
  );

  Future<bool> _open(
    BrowserController browser,
    List<String> labels, {
    List<String> hrefHints = const [],
  }) async {
    final encoded = labels.map(_quote).join(',');
    final encodedHints = hrefHints.map(_quote).join(',');
    final raw = await browser
        .evaluateConnectorJavascript('''(() => {
        /* QESTO_SBER_READ_V1: click only an unambiguous read-only navigation item. */
        const labels = [$encoded];
        const hrefHints = [$encodedHints];
        const visible = (node) => {
          const style = getComputedStyle(node);
          return style.display !== 'none' && style.visibility !== 'hidden' &&
            node.getBoundingClientRect().width > 0 && node.getBoundingClientRect().height > 0;
        };
        const text = (node) => String(node.innerText || node.getAttribute('aria-label') || '').replace(/\\s+/g, ' ').trim().toLowerCase();
        const candidates = Array.from(document.querySelectorAll('a,button,[role="link"],[role="button"]')).filter(visible);
        const hrefMatches = candidates.filter((node) => {
          const href = String(node.getAttribute('href') || '').split('?')[0].toLowerCase();
          return hrefHints.some((hint) => href === hint || href.startsWith(hint + '/'));
        });
        const score = (node) => {
          const value = text(node);
          let best = 10000;
          labels.forEach((label, index) => {
            if (value === label) best = Math.min(best, index);
            else if (value.startsWith(label + ' ') || value.endsWith(' ' + label)) best = Math.min(best, 100 + index);
            else if (value.includes(label)) best = Math.min(best, 200 + index);
          });
          return best;
        };
        if (hrefMatches.length > 0) {
          hrefMatches.sort((left, right) => score(left) - score(right) || text(left).length - text(right).length);
          setTimeout(() => hrefMatches[0].click(), 500);
          return '1';
        }
        const matches = candidates.filter((node) => {
          const value = text(node);
          return labels.some((label) => value === label || value.startsWith(label + ' ') || value.endsWith(' ' + label));
        });
        if (matches.length !== 1) return '0';
        setTimeout(() => matches[0].click(), 500);
        return '1';
      })()''')
        .timeout(const Duration(seconds: 5), onTimeout: () => null);
    if (raw != '1') return false;
    await Future<void>.delayed(const Duration(milliseconds: 900));
    return true;
  }

  static String _quote(String value) => "'${value.replaceAll("'", "\\'")}'";
}
