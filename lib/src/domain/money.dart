class Chips {
  static const int unit = 100;
  static const int smallBlind = 50;
  static const int bigBlind = 100;

  static int fromWhole(num value) => (value * unit).round();

  static String format(int amount) {
    final bool negative = amount < 0;
    final int absolute = amount.abs();
    final int whole = absolute ~/ unit;
    final int cents = absolute % unit;
    final String sign = negative ? '-' : '';
    if (cents == 0) {
      return '$sign$whole';
    }
    if (cents == 50) {
      return '$sign$whole.5';
    }
    return '$sign$whole.${cents.toString().padLeft(2, '0')}';
  }
}
