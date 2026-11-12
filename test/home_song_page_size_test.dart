import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/ui/pages/home_page.dart';

void main() {
  test('wide song pages contain an even number of rows', () {
    expect(homeSongPageSize(false), 5);
    expect(homeSongPageSize(true), 6);
    expect((homeSongPageSize(true) / 2).ceil(), 3);
  });
}
