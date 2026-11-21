import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/ui/pages/home_page.dart';

void main() {
  test('banner colour stays opaque without a custom background', () {
    const light = ColorScheme.light();
    const dark = ColorScheme.dark();
    expect(homeBannerCardColor(light, frosted: false), light.surfaceContainer);
    expect(homeBannerCardColor(dark, frosted: false), dark.surfaceContainer);
    expect(light.surfaceContainer.a, 1);
  });

  test('frosted banner matches the mine-page card alphas', () {
    const light = ColorScheme.light();
    const dark = ColorScheme.dark();
    final lightCard = homeBannerCardColor(light, frosted: true);
    final darkCard = homeBannerCardColor(dark, frosted: true);
    expect(lightCard.a, closeTo(.72, .001));
    expect(darkCard.a, closeTo(.68, .001));
    expect(lightCard, light.surfaceContainer.withValues(alpha: .72));
    expect(darkCard, dark.surfaceContainer.withValues(alpha: .68));
  });
}
