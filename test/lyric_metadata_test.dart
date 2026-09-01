import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/models/music_models.dart';
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
      expect(
        creditLines,
        isNotEmpty,
        reason: 'credit lines stay visible as original text',
      );
      for (final line in creditLines) {
        expect(
          line.translation,
          isNull,
          reason: '"${line.text}" must not receive a translation',
        );
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
      final lines = parseLyrics(
        '''
[00:00.00]作词 Lyricist：Xulai
[00:00.00]作曲 Composer：Someone
[00:01.00]歌词正文
''',
        translationContent: '''
[00:00.00]translated lyric
''',
      );

      for (final line in lines.take(2)) {
        expect(
          line.translation,
          isNull,
          reason: '"${line.text}" is a credit line',
        );
      }
    });

    test('long compound credit prefix is detected as metadata', () {
      final lines = parseLyrics(
        '''
[00:00.00]Recording and Mixing Engineers：中谷浩平
[00:01.00]歌词正文
''',
        translationContent: '''
[00:01.00]translated lyric
''',
      );

      final credit = lines.firstWhere((line) => line.text.contains('中谷浩平'));
      expect(credit.translation, isNull);
      final lyric = lines.firstWhere((line) => line.text == '歌词正文');
      expect(lyric.translation, 'translated lyric');
    });

    test('traditional/Japanese credit prefixes never carry the first-line '
        'translation', () {
      final lines = parseLyrics(
        '''
[00:00.00]作詞：吉田穣
[00:00.00]編曲：Someone
[00:00.00]第一句歌词
[00:10.00]第二句歌词
''',
        translationContent: '''
[00:00.00]First line translated
[00:10.00]Second line translated
''',
      );

      final lyricist = lines.firstWhere((line) => line.text.contains('吉田穣'));
      expect(lyricist.translation, isNull);
      final arranger = lines.firstWhere((line) => line.text.contains('編曲'));
      expect(arranger.translation, isNull);
      final first = lines.firstWhere((line) => line.text == '第一句歌词');
      expect(first.translation, 'First line translated');
    });

    test('slash-combined credit prefixes are detected as metadata', () {
      final lines = parseLyrics(
        '''
[00:00.00]作詞/作曲：吉田穣
[00:00.00]第一句歌词
''',
        translationContent: '''
[00:00.00]First line translated
''',
      );

      final credit = lines.firstWhere((line) => line.text.contains('吉田穣'));
      expect(credit.translation, isNull);
      final first = lines.firstWhere((line) => line.text == '第一句歌词');
      expect(first.translation, 'First line translated');
    });

    test(
      'bilingual compound credits never carry the first-line translation',
      () {
        final lines = parseLyrics(
          '''
[00:00.00]和声编写 Voicing Arrangement:jixwang
[00:00.00]乐器独奏 Instrument Solo:Guitar: 愤怒的糖
[00:00.00]监制 Music Supervisor: jixwang
[00:00.00]助理 Assistant:markmilian/Ream雨舒/TLK天翔/auburn
[00:00.00]出品 Produced by：鸣潮先约电台
[00:00.00]第一句歌词
[00:10.00]第二句歌词
''',
          translationContent: '''
[00:00.00]First line translated
[00:10.00]Second line translated
''',
        );

        const creditMarkers = [
          'Voicing Arrangement',
          'Instrument Solo',
          'Music Supervisor',
          'Assistant',
          'Produced by',
        ];
        for (final marker in creditMarkers) {
          final credit = lines.firstWhere((line) => line.text.contains(marker));
          expect(credit.translation, isNull, reason: '"$marker" is a credit');
        }
        final first = lines.firstWhere((line) => line.text == '第一句歌词');
        expect(first.translation, 'First line translated');
        final second = lines.firstWhere((line) => line.text == '第二句歌词');
        expect(second.translation, 'Second line translated');
      },
    );

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
      final content =
          '''
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

    test('watermark line in main lyrics is kept but hidden', () {
      final lines = parseLyrics('''
[00:00.00]以下歌词翻译由文曲大模型提供
[00:00.00]この星では私の歌声
[00:10.00]次の行の歌詞
''');

      expect(lines.length, 3, reason: '不删行，保持与翻译轨行号对齐');
      expect(lines[0].text, '以下歌词翻译由文曲大模型提供');
      expect(lines[0].hidden, isTrue);
      expect(lines[1].text, 'この星では私の歌声');
      expect(lines[1].hidden, isFalse);
      expect(lines[2].text, '次の行の歌詞');
    });

    test('leading title card never consumes the first indexed translation', () {
      final language = {
        'type': 1,
        'lyricContent': [
          ['以下歌词翻译由文曲大模型提供'],
          ['末班车即将发车的站台上 两人  '],
          ['分饮着同一杯咖啡  '],
        ],
      };
      final encoded = base64Encode(utf8.encode(jsonEncode(language)));
      final content =
          '''
[language:$encoded]
[614,27446]<0,192,0>Ending <192,184,0>Note - <376,360,0>門<736,460,0>谷<1196,460,0>純
[28060,6104]<0,664,0>終<664,992,0>電<1656,320,0>間<1976,832,0>際
[34164,6649]<0,400,0>一<400,344,0>つ<744,376,0>の
''';

      final lines = parseLyrics(content);

      expect(lines.length, 3);
      expect(lines[0].text, 'Ending Note - 門谷純');
      expect(lines[0].hidden, isTrue, reason: '标题卡打 hidden 标记');
      expect(lines[0].translation, isNull, reason: '标题卡不应挂首句翻译');
      expect(lines[1].text, '終電間際');
      expect(lines[1].hidden, isFalse);
      expect(lines[1].translation, '末班车即将发车的站台上 两人');
      expect(lines[2].translation, '分饮着同一杯咖啡');
    });

    test('empty translation rows occupy title/credit line slots', () {
      // 远航星的告别：标题卡+12 行署名在翻译轨里各有一行空串占位，
      // 真正的歌词从第 13 行开始 1:1 对齐。
      final language = {
        'type': 1,
        'lyricContent': [
          [''],
          [''],
          ['那片雪花曾落在我的鼻尖'],
          ['那些孤独路上的追光者'],
        ],
      };
      final encoded = base64Encode(utf8.encode(jsonEncode(language)));
      final content =
          '''
[language:$encoded]
[0,3000]<0,1500,0>远航星的告别 - 鸣潮先约电台
[100,2000]<0,1000,0>词 Lyricist：Xulai
[5000,3000]<0,1500,0>That snowflake once fell on my nose
[8000,3000]<0,1500,0>Those who trace starlight on their lonely roads
''';

      final lines = parseLyrics(content);

      expect(lines.length, 4);
      expect(lines[0].hidden, isTrue, reason: '标题卡');
      expect(lines[1].hidden, isTrue, reason: '署名行');
      expect(lines[2].hidden, isFalse);
      expect(lines[2].translation, '那片雪花曾落在我的鼻尖');
      expect(lines[3].translation, '那些孤独路上的追光者');
    });

    test('AKINO 海色 production credits preserve KRC translation slots', () {
      // Candidate 166040617 contains ten title/production-credit rows before
      // the first lyric. Its language track preserves those rows as blanks.
      final language = {
        'type': 1,
        'lyricContent': [
          for (var index = 0; index < 10; index++) [' '],
          ['在绚烂夺目的晨光下'],
          ['拔锚起航吧'],
          ['相顾无言'],
        ],
      };
      final encoded = base64Encode(utf8.encode(jsonEncode(language)));
      final content =
          '''
[language:$encoded]
[0,249]海色 - AKINO (川満愛希信)
[250,57]词：minatoku
[307,114]曲：WEST GROUND
[423,153]编曲：WEST GROUND
[576,95]Guitar：城石真臣
[672,57]Bass：Kei Nakamura
[730,57]Drums：Shohei（LOTH）
[788,95]Piano：伊賀拓郎
[884,76]Strings：門脇Strings
[961,134]Recordind＆Mixing Engineers：中谷浩平
[1096,5091]朝の光 眩しくて
[6187,10154]Weigh anchor
[16341,2486]言葉もなくて
''';

      final lines = parseLyrics(content);

      expect(lines.length, 13);
      expect(lines.take(10).every((line) => line.hidden), isTrue);
      expect(
        lines.firstWhere((line) => line.text.startsWith('Piano')).translation,
        isNull,
      );
      expect(lines[10].text, '朝の光 眩しくて');
      expect(lines[10].translation, '在绚烂夺目的晨光下');
      expect(lines[11].translation, '拔锚起航吧');
      expect(lines[12].translation, '相顾无言');
    });

    test('watermark row pairs with hidden main line instead of shifting', () {
      // 水印同时出现在主歌词与翻译轨顶部时，两处隐藏行互相配对，
      // 真正的歌词保持对齐。
      final language = {
        'type': 1,
        'lyricContent': [
          ['以下歌词翻译由文曲大模型提供'],
          ['第一句翻译'],
          ['第二句翻译'],
        ],
      };
      final encoded = base64Encode(utf8.encode(jsonEncode(language)));
      final content =
          '''
[language:$encoded]
[0,2000]以下歌词翻译由文曲大模型提供
[2000,2000]この星では私の歌声
[4000,2000]次の行の歌詞
''';

      final lines = parseLyrics(content);

      expect(lines.length, 3);
      expect(lines[0].hidden, isTrue);
      expect(lines[0].translation, isNull);
      expect(lines[1].text, 'この星では私の歌声');
      expect(lines[1].translation, '第一句翻译');
      expect(lines[2].translation, '第二句翻译');
    });

    test(
      'short hyphenated first lyric line still consumes its translation',
      () {
        final language = {
          'type': 1,
          'lyricContent': [
            ['哇哦'],
            ['下一句'],
          ],
        };
        final encoded = base64Encode(utf8.encode(jsonEncode(language)));
        final content =
            '''
[language:$encoded]
[0,3000]<0,1500,0>Wow - <1500,1500,0>oh
[3000,3000]next line
''';

        final lines = parseLyrics(content);

        expect(lines[0].text, 'Wow - oh');
        expect(lines[0].translation, '哇哦');
        expect(lines[1].translation, '下一句');
      },
    );

    test('colon-form attribution prefixes are detected as metadata', () {
      final lines = parseLyrics(
        '''
[00:00.00]翻译：文曲大模型
[00:00.00]第一句歌词
''',
        translationContent: '''
[00:00.00]First line translated
''',
      );

      final credit = lines.firstWhere((line) => line.text.contains('文曲'));
      expect(credit.translation, isNull);
      final first = lines.firstWhere((line) => line.text == '第一句歌词');
      expect(first.translation, 'First line translated');
    });

    test('hidden flag survives cache round-trip', () {
      const hiddenLine = LyricLine(
        time: Duration.zero,
        text: '作词：X',
        hidden: true,
      );
      final restoredHidden = LyricLine.fromCache(hiddenLine.toCache());
      expect(restoredHidden.hidden, isTrue);

      const visibleLine = LyricLine(time: Duration.zero, text: '歌詞');
      expect(LyricLine.fromCache(visibleLine.toCache()).hidden, isFalse);
    });
  });
}
