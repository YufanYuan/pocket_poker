enum Suit {
  clubs('C'),
  diamonds('D'),
  hearts('H'),
  spades('S');

  const Suit(this.label);

  final String label;
}

enum Rank {
  two(2, '2'),
  three(3, '3'),
  four(4, '4'),
  five(5, '5'),
  six(6, '6'),
  seven(7, '7'),
  eight(8, '8'),
  nine(9, '9'),
  ten(10, 'T'),
  jack(11, 'J'),
  queen(12, 'Q'),
  king(13, 'K'),
  ace(14, 'A');

  const Rank(this.value, this.label);

  final int value;
  final String label;
}

class PlayingCard {
  const PlayingCard(this.rank, this.suit);

  final Rank rank;
  final Suit suit;

  String get label => '${rank.label}${suit.label}';

  @override
  String toString() => label;

  @override
  bool operator ==(Object other) {
    return other is PlayingCard && other.rank == rank && other.suit == suit;
  }

  @override
  int get hashCode => Object.hash(rank, suit);
}
