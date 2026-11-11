import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/ui/pages/home_page.dart';

void main() {
  test('feature cards stay square and bounded on wide screens', () {
    expect(featureCardSize(390), 190);
    expect(featureCardSize(410), 200);
    expect(featureCardSize(1000), 200);
    expect(featureCardSize(280), 140);
  });
}
