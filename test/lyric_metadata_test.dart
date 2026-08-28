import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/services/music_api.dart';

void main() {
  group('parseLyrics metadata credits', () {
    const content = '''
[00:00.00]Recording&Mixing Engineers：中谷浩平
[00:00.00]词 Lyricist：Xulai
[00:00.00]第一句歌词
[00:10.00]第二句歌词
''';

    const translation = '''
[00:00.00]First line translated
[00:10.00]Second line translated
''';

    test('credit lines never carry a translation', () {
      final lines = parseLyrics(content, translationContent: translation);

      final creditLines = lines.where(
        (line) => line.text.contains('中谷浩平') || line.text.contains('Xulai'),
      );
      expect(creditLines, isNotEmpty,
          reason: 'credit lines stay visible as original text');
      for (final line in creditLines) {
        expect(line.translation, isNull,
            reason: '"${line.text}" must not receive a translation');
      }
    });

    test('real lyric lines keep their translations aligned', () {
      final lines = parseLyrics(content, translationContent: translation);

      final first = lines.firstWhere((line) => line.text == '第一句歌词');
      final second = lines.firstWhere((line) => line.text == '第二句歌词');
      expect(first.translation, 'First line translated');
      expect(second.translation, 'Second line translated');
    });

    test('bilingual credit prefix is detected as metadata', () {
      final lines = parseLyrics('''
[00:00.00]作词 Lyricist：Xulai
[00:00.00]作曲 Composer：Someone
[00:01.00]歌词正文
''', translationContent: '''
[00:00.00]translated lyric
''');

      for (final line in lines.take(2)) {
        expect(line.translation, isNull,
            reason: '"${line.text}" is a credit line');
      }
    });

    test('long compound credit prefix is detected as metadata', () {
      final lines = parseLyrics('''
[00:00.00]Recording and Mixing Engineers：中谷浩平
[00:01.00]歌词正文
''', translationContent: '''
[00:01.00]translated lyric
''');

      final credit = lines.firstWhere(
        (line) => line.text.contains('中谷浩平'),
      );
      expect(credit.translation, isNull);
      final lyric = lines.firstWhere((line) => line.text == '歌词正文');
      expect(lyric.translation, 'translated lyric');
    });

    test('traditional/Japanese credit prefixes never carry the first-line '
        'translation', () {
      final lines = parseLyrics('''
[00:00.00]作詞：吉田穣
[00:00.00]編曲：Someone
[00:00.00]第一句歌词
[00:10.00]第二句歌词
''', translationContent: '''
[00:00.00]First line translated
[00:10.00]Second line translated
''');

      final lyricist = lines.firstWhere((line) => line.text.contains('吉田穣'));
      expect(lyricist.translation, isNull);
      final arranger = lines.firstWhere((line) => line.text.contains('編曲'));
      expect(arranger.translation, isNull);
      final first = lines.firstWhere((line) => line.text == '第一句歌词');
      expect(first.translation, 'First line translated');
    });

    test('slash-combined credit prefixes are detected as metadata', () {
      final lines = parseLyrics('''
[00:00.00]作詞/作曲：吉田穣
[00:00.00]第一句歌词
''', translationContent: '''
[00:00.00]First line translated
''');

      final credit = lines.firstWhere(
        (line) => line.text.contains('吉田穣'),
      );
      expect(credit.translation, isNull);
      final first = lines.firstWhere((line) => line.text == '第一句歌词');
      expect(first.translation, 'First line translated');
    });

    test('bilingual compound credits never carry the first-line translation',
        () {
      final lines = parseLyrics('''
[00:00.00]和声编写 Voicing Arrangement:jixwang
[00:00.00]乐器独奏 Instrument Solo:Guitar: 愤怒的糖
[00:00.00]监制 Music Supervisor: jixwang
[00:00.00]助理 Assistant:markmilian/Ream雨舒/TLK天翔/auburn
[00:00.00]出品 Produced by：鸣潮先约电台
[00:00.00]第一句歌词
[00:10.00]第二句歌词
''', translationContent: '''
[00:00.00]First line translated
[00:10.00]Second line translated
''');

      const creditMarkers = [
        'Voicing Arrangement',
        'Instrument Solo',
        'Music Supervisor',
        'Assistant',
        'Produced by',
      ];
      for (final marker in creditMarkers) {
        final credit = lines.firstWhere(
          (line) => line.text.contains(marker),
        );
        expect(credit.translation, isNull, reason: '"$marker" is a credit');
      }
      final first = lines.firstWhere((line) => line.text == '第一句歌词');
      expect(first.translation, 'First line translated');
      final second = lines.firstWhere((line) => line.text == '第二句歌词');
      expect(second.translation, 'Second line translated');
    });

    test('LLM attribution watermark in KRC translation list does not shift '
        'alignments', () {
      final language = {
        'type': 1,
        'lyricContent': [
          ['以下歌词翻译由文曲大模型提供'],
          ['第一句翻译'],
          ['第二句翻译'],
        ],
      };
      final encoded = base64Encode(utf8.encode(jsonEncode(language)));
      final content = '''
[language:$encoded]
[0,2000]この星では私の歌声
[2000,2000]次の行の歌詞
''';

      final lines = parseLyrics(content);

      expect(lines.length, 2);
      expect(lines[0].text, 'この星では私の歌声');
      expect(lines[0].translation, '第一句翻译');
      expect(lines[1].text, '次の行の歌詞');
      expect(lines[1].translation, '第二句翻译');
    });

    test('LLM attribution watermark in main lyrics is removed', () {
      final lines = parseLyrics('''
[00:00.00]以下歌词翻译由文曲大模型提供
[00:00.00]この星では私の歌声
[00:10.00]次の行の歌詞
''');

      expect(lines.length, 2);
      expect(lines.first.text, 'この星では私の歌声');
    });

    test('colon-form attribution prefixes are detected as metadata', () {
      final lines = parseLyrics('''
[00:00.00]翻译：文曲大模型
[00:00.00]第一句歌词
''', translationContent: '''
[00:00.00]First line translated
''');

      final credit = lines.firstWhere((line) => line.text.contains('文曲'));
      expect(credit.translation, isNull);
      final first = lines.firstWhere((line) => line.text == '第一句歌词');
      expect(first.translation, 'First line translated');
    });
  });
}
