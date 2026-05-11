import 'package:flutter_test/flutter_test.dart';
import 'package:poker_ai/src/domain/card.dart';
import 'package:poker_ai/src/domain/hand_evaluator.dart';

void main() {
  test('straight flush outranks four of a kind', () {
    final HandValue straightFlush = HandEvaluator.bestOf(<PlayingCard>[
      c(Rank.ace, Suit.hearts),
      c(Rank.king, Suit.hearts),
      c(Rank.queen, Suit.hearts),
      c(Rank.jack, Suit.hearts),
      c(Rank.ten, Suit.hearts),
      c(Rank.two, Suit.clubs),
      c(Rank.three, Suit.clubs),
    ]);
    final HandValue quads = HandEvaluator.bestOf(<PlayingCard>[
      c(Rank.nine, Suit.hearts),
      c(Rank.nine, Suit.clubs),
      c(Rank.nine, Suit.diamonds),
      c(Rank.nine, Suit.spades),
      c(Rank.ace, Suit.clubs),
      c(Rank.two, Suit.clubs),
      c(Rank.three, Suit.clubs),
    ]);

    expect(straightFlush.category, HandCategory.straightFlush);
    expect(straightFlush.compareTo(quads), greaterThan(0));
  });

  test('ace can play low in a wheel straight', () {
    final HandValue value = HandEvaluator.bestOf(<PlayingCard>[
      c(Rank.ace, Suit.hearts),
      c(Rank.two, Suit.clubs),
      c(Rank.three, Suit.diamonds),
      c(Rank.four, Suit.spades),
      c(Rank.five, Suit.hearts),
      c(Rank.king, Suit.clubs),
      c(Rank.queen, Suit.clubs),
    ]);

    expect(value.category, HandCategory.straight);
    expect(value.kickers.first, 5);
  });

  test('best full house uses highest trip first', () {
    final HandValue value = HandEvaluator.bestOf(<PlayingCard>[
      c(Rank.ace, Suit.hearts),
      c(Rank.ace, Suit.clubs),
      c(Rank.ace, Suit.diamonds),
      c(Rank.king, Suit.spades),
      c(Rank.king, Suit.hearts),
      c(Rank.queen, Suit.clubs),
      c(Rank.queen, Suit.diamonds),
    ]);

    expect(value.category, HandCategory.fullHouse);
    expect(value.kickers, <int>[14, 13]);
  });
}

PlayingCard c(Rank rank, Suit suit) => PlayingCard(rank, suit);
