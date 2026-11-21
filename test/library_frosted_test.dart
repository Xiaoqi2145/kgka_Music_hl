import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/ui/pages/library_page.dart';

void main() {
  test('frosted only when background enabled and image set', () {
    expect(
      libraryFrostedActive(enabled: true, imagePath: '/tmp/bg.jpg'),
      isTrue,
    );
    expect(
      libraryFrostedActive(enabled: false, imagePath: '/tmp/bg.jpg'),
      isFalse,
    );
    expect(libraryFrostedActive(enabled: true, imagePath: null), isFalse);
  });

  test('inactive keeps the original opaque container color', () {
    const light = ColorScheme.light();
    const dark = ColorScheme.dark();
    expect(
      libraryFrostedCardColor(light, active: false),
      light.surfaceContainer,
    );
    expect(
      libraryFrostedRowColor(light, active: false),
      light.surfaceContainer,
    );
    expect(libraryFrostedCardColor(dark, active: false), dark.surfaceContainer);
    expect(libraryFrostedRowColor(dark, active: false), dark.surfaceContainer);
  });

  test('active card color is translucent', () {
    const light = ColorScheme.light();
    const dark = ColorScheme.dark();
    final lightCard = libraryFrostedCardColor(light, active: true);
    final darkCard = libraryFrostedCardColor(dark, active: true);
    expect(lightCard.a, closeTo(.72, .001));
    expect(darkCard.a, closeTo(.68, .001));
  });

  test('active row color keeps higher opacity for readability', () {
    const light = ColorScheme.light();
    const dark = ColorScheme.dark();
    expect(libraryFrostedRowColor(light, active: true).a, closeTo(.80, .001));
    expect(libraryFrostedRowColor(dark, active: true).a, closeTo(.78, .001));
  });
}
