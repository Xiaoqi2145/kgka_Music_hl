import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/ui/pages/player_page.dart';

void main() {
  test('lyric preview centers the active line at the current progress', () {
    expect(
      lyricPreviewScrollOffset(
        activeIndex: 0,
        lineExtent: 92,
        topPadding: 44,
        viewportHeight: 600,
        maxScrollExtent: 2000,
      ),
      0,
    );
    expect(
      lyricPreviewScrollOffset(
        activeIndex: 20,
        lineExtent: 92,
        topPadding: 44,
        viewportHeight: 600,
        maxScrollExtent: 2000,
      ),
      44 + 20 * 92 - 600 * .34,
    );
    expect(
      lyricPreviewScrollOffset(
        activeIndex: 99,
        lineExtent: 92,
        topPadding: 44,
        viewportHeight: 600,
        maxScrollExtent: 2000,
      ),
      2000,
    );
  });
}
