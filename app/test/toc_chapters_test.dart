// effectiveTocChapters（corpus/toc_chapters.dart）专项：真章救援（derm/
// endo/patho 真实形态——17 垃圾 chapters + 29 真章 sections）、flat 书辅文
// 过滤（垃圾清零 + 原 no 保留稀疏编号）、ortho「 / 页码」尾巴剥离、幂等
// （同 sidecar 二跑/已变换 chapters 再跑）、空防御（不抛异常、退化原样），
// 以及稀疏编号下 learned_through 收口按最大 no（initFromTocSidecar /
// applyChange / setSubjectChapters 接线口径）。
//
// 纯 Dart 测试：纯函数 + 临时目录文件 IO，无需 TestWidgetsFlutterBinding
// 与 sqlite3（Windows 测试宿主基建零依赖，同 progress_db_test 形态）。
import 'dart:convert';
import 'dart:io';

import 'package:hengya/services/local/corpus/progress_db.dart';
import 'package:hengya/services/local/corpus/toc_chapters.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ---------------- fixtures（真实 sidecar 同构，全角空格 \u3000 如实） ----------------

  /// derm 真实形态（2026-09-07 建库实测）：chapters=17 条书签第一层垃圾
  /// （含第一篇/第二篇），sections=29 条真章（全角空格分隔）。
  Map<String, Object?> dermSidecar() {
    final junkTitles = [
      '封面页', '书名页', '版权页', '编委名单', '新形态教材使用说明', '序言',
      '教材修订说明', '主审简介', '主编简介', '副主编简介', '前言', '目录',
      '第一篇\u3000皮肤性病学总论', '第二篇\u3000皮肤性病学各论', '推荐阅读',
      '中英文名词对照索引', '封底页',
    ];
    final sectionTitles = <String>[
      '第一章\u3000皮肤性病学导论',
      '第二章\u3000皮肤的结构',
      '第三章\u3000皮肤的功能',
      '第四章\u3000皮肤病和性病的临床表现',
      '第五章\u3000皮肤病和性病的辅助检查方法',
      '第六章\u3000皮肤病和性病的诊断',
      '第七章\u3000皮肤病和性病的治疗',
      '第八章\u3000皮肤美容',
      '第九章\u3000皮肤病和性病的预防和康复',
      '第十章\u3000病毒性皮肤病',
      '第十一章\u3000细菌性皮肤病',
      '第十二章\u3000真菌性皮肤病',
      '第十三章\u3000动物性皮肤病',
      '第十四章\u3000皮炎和湿疹',
      '第十五章\u3000荨麻疹类皮肤病',
      '第十六章\u3000药疹',
      '第十七章\u3000物理性皮肤病',
      '第十八章\u3000瘙痒性皮肤病',
      '第十九章\u3000红斑丘疹鳞屑性皮肤病',
      '第二十章\u3000结缔组织病',
      '第二十一章\u3000大疱性皮肤病',
      '第二十二章\u3000血管炎与脂膜炎',
      '第二十三章\u3000嗜中性皮肤病',
      '第二十四章\u3000皮肤附属器疾病',
      '第二十五章\u3000色素性皮肤病',
      '第二十六章\u3000遗传性皮肤病',
      '第二十七章\u3000营养与代谢障碍性皮肤病',
      '第二十八章\u3000皮肤肿瘤',
      '第二十九章\u3000性传播疾病',
    ];
    return {
      'version': 1,
      'subject': 'derm',
      'textbook': '《皮肤性病学（第10版）》',
      'updated_at': '2026-09-07T23:26:15',
      'chapters': [
        for (var i = 0; i < junkTitles.length; i++)
          {'no': i + 1, 'title': junkTitles[i], 'page_start': i + 1},
      ],
      'sections': [
        for (var i = 0; i < sectionTitles.length; i++)
          {
            'chapter_no': i < 9 ? 13 : 14,
            'title': sectionTitles[i],
            'page_start': 23 + i * 6,
          },
      ],
    };
  }

  /// oms 真实形态：flat 章 + 单独成条的实习教程 + 辅文；sections 为
  /// 「第X节」节级（不触发救援）。
  Map<String, Object?> omsSidecar() => {
        'version': 1,
        'subject': 'oms',
        'textbook': '口腔颌面外科学-第8版',
        'updated_at': '2026-09-06T11:45:41',
        'chapters': [
          {'no': 1, 'title': '目录', 'page_start': 3},
          {'no': 2, 'title': '目录尾', 'page_start': 12},
          {'no': 3, 'title': '第一章 绪论', 'page_start': 13},
          {'no': 4, 'title': '第二章 基本操作', 'page_start': 16},
          {'no': 5, 'title': '第三章 麻醉', 'page_start': 51},
          {'no': 6, 'title': '实习教程', 'page_start': 396},
          {'no': 7, 'title': '附录', 'page_start': 416},
          {'no': 8, 'title': '中英文名词对照索引', 'page_start': 422},
        ],
        'sections': [
          {'chapter_no': 4, 'title': '第一节 病史记录', 'page_start': 16},
          {'chapter_no': 4, 'title': '第二节 体格检查', 'page_start': 20},
          {'chapter_no': 4, 'title': '第三节 无菌术', 'page_start': 25},
        ],
      };

  /// ortho 真实形态：章标题带「 / 页码」尾巴，索引也带尾巴。
  Map<String, Object?> orthoSidecar() => {
        'version': 1,
        'subject': 'ortho',
        'textbook': '口腔正畸学 第8版',
        'updated_at': '2026-09-06T11:45:42',
        'chapters': [
          {'no': 1, 'title': '目录', 'page_start': 7},
          {'no': 2, 'title': '第一章 绪论 / 1', 'page_start': 11},
          {'no': 3, 'title': '第二章 颌面的生长发育 / 10', 'page_start': 20},
          {'no': 4, 'title': '索引 / 270', 'page_start': 280},
        ],
        'sections': <Object?>[
          {'chapter_no': 2, 'title': '一、错骀畸形的临床表现', 'page_start': 11},
        ],
      };

  // ---------------- sections 救援（真章全丢的根治） ----------------

  group('sections 救援', () {
    test('derm：17 垃圾 chapters + 29 真章 sections → 29 章 no=1..29', () {
      final sc = dermSidecar();
      final before = jsonEncode(sc);
      final out = effectiveTocChapters(sc);
      expect(out.length, 29, reason: '真章全丢根治：sections 真章接管');
      expect(
        [for (final c in out) c['no']],
        [for (var i = 1; i <= 29; i++) i],
        reason: '救援路径 no 重编 1..N 连续',
      );
      expect(out.first['title'], '第一章\u3000皮肤性病学导论',
          reason: 'title 归一只剥尾+trim，内部全角空格保留');
      expect(out.first['page_start'], 23, reason: '救援保留 page_start');
      expect(
        out.first.containsKey('chapter_no'),
        false,
        reason: '救援丢弃 chapter_no 字段',
      );
      expect(out.last['title'], '第二十九章\u3000性传播疾病');
      expect(jsonEncode(sc), before, reason: 'sidecar 只读不改（幂等根基）');
    });

    test('endo：救援只采纳 sections 真章，节级（一、二、三、）不误 adopt', () {
      final out = effectiveTocChapters({
        'version': 1,
        'subject': 'endo',
        'textbook': '牙体牙髓病学-第5版',
        'chapters': [
          {'no': 1, 'title': '目录', 'page_start': 3},
          {'no': 2, 'title': '目录尾', 'page_start': 13},
          {'no': 3, 'title': '绪论', 'page_start': 14},
          {'no': 4, 'title': '第一篇 龋病学', 'page_start': 18},
          {'no': 5, 'title': '第二篇 牙体硬组织非龋性疾病', 'page_start': 58},
          {'no': 8, 'title': '中英文名词对照索引', 'page_start': 367},
        ],
        'sections': [
          {'chapter_no': 3, 'title': '一、龋病学的发展', 'page_start': 14},
          {'chapter_no': 3, 'title': '二、牙髓病学的发展', 'page_start': 15},
          {'chapter_no': 3, 'title': '三、保存牙科学的主要内容', 'page_start': 16},
          {'chapter_no': 4, 'title': '第一章 龋病学概论', 'page_start': 19},
          {'chapter_no': 4, 'title': '第二章 龋病病因与发病机制', 'page_start': 24},
          {'chapter_no': 4, 'title': '第三章 临床表现与诊断', 'page_start': 41},
        ],
      });
      expect(
        [for (final c in out) c['title']],
        ['第一章 龋病学概论', '第二章 龋病病因与发病机制', '第三章 临床表现与诊断'],
        reason: '节级内容一律不采纳——只收真章',
      );
      expect([for (final c in out) c['no']], [1, 2, 3]);
    });

    test('救援门：chapters 真章 1<2 触发 / 2 不触发 / sections 真章 <3 不触发', () {
      final chOne = [
        {'no': 1, 'title': '目录', 'page_start': 3},
        {'no': 2, 'title': '第一章 总论', 'page_start': 9},
      ];
      final chTwo = [
        {'no': 1, 'title': '目录', 'page_start': 3},
        {'no': 2, 'title': '第一章 总论', 'page_start': 9},
        {'no': 3, 'title': '第二章 各论', 'page_start': 30},
      ];
      final secThree = [
        {'chapter_no': 2, 'title': '第一章 总论', 'page_start': 9},
        {'chapter_no': 2, 'title': '第二章 各论', 'page_start': 30},
        {'chapter_no': 3, 'title': '第三章 融合', 'page_start': 60},
      ];
      // chapters 真章=1 < 2 且 sections 真章=3 ≥ 3 → 救援（重编 1..3）
      final r1 =
          effectiveTocChapters({'chapters': chOne, 'sections': secThree});
      expect([for (final c in r1) c['no']], [1, 2, 3]);
      expect(r1.first['title'], '第一章 总论');
      // chapters 真章=2 → 不救援：走 chapters 过滤（目录剔除、原 no 保留）
      final r2 =
          effectiveTocChapters({'chapters': chTwo, 'sections': secThree});
      expect([for (final c in r2) c['no']], [2, 3],
          reason: '不救援：原 no 保留（稀疏编号）');
      // sections 真章=0 < 3 → 不救援：chapters 过滤（[绪论] 幸存）
      final r3 = effectiveTocChapters({
        'chapters': [
          {'no': 1, 'title': '目录', 'page_start': 3},
          {'no': 2, 'title': '绪论', 'page_start': 9},
        ],
        'sections': [
          {'chapter_no': 2, 'title': '一、开头', 'page_start': 9},
          {'chapter_no': 2, 'title': '二、发展', 'page_start': 30},
        ],
      });
      expect([for (final c in r3) c['no']], [2]);
      expect(r3.single['title'], '绪论');
    });

    test('sections 中的「绪论」按真章判定可被采纳', () {
      final out = effectiveTocChapters({
        'chapters': [
          {'no': 1, 'title': '目录', 'page_start': 3},
        ],
        'sections': [
          {'chapter_no': 1, 'title': '绪论', 'page_start': 5},
          {'chapter_no': 1, 'title': '第一章 总论', 'page_start': 9},
          {'chapter_no': 1, 'title': '第二章 各论', 'page_start': 30},
          {'chapter_no': 1, 'title': '第三章 融合', 'page_start': 60},
        ],
      });
      expect([for (final c in out) c['title']],
          ['绪论', '第一章 总论', '第二章 各论', '第三章 融合']);
      expect([for (final c in out) c['no']], [1, 2, 3, 4]);
    });
  });

  // ---------------- chapters 过滤（flat 书） ----------------

  group('chapters 过滤', () {
    test('oms：辅文剔除、原 no 保留（稀疏）、实习教程幸存、节级 sections 不救援', () {
      final out = effectiveTocChapters(omsSidecar());
      expect([for (final c in out) c['no']], [3, 4, 5, 6],
          reason: '辅文剔除后幸存条目保留原 no（稀疏编号，不重编）');
      expect(
        [for (final c in out) c['title']],
        ['第一章 绪论', '第二章 基本操作', '第三章 麻醉', '实习教程'],
        reason: '单独成条的实习教程是真实学习内容，勿误杀；节级 sections 不被采纳',
      );
    });

    test('ortho：「 / 页码」尾巴剥离；垃圾「索引 / 270」剥尾后命中精确集合', () {
      final out = effectiveTocChapters(orthoSidecar());
      expect(
        [for (final c in out) c['title']],
        ['第一章 绪论', '第二章 颌面的生长发育'],
        reason: '尾部「 / 页码」污染剥离（比对前先归一）',
      );
      expect([for (final c in out) c['no']], [2, 3], reason: '剥尾不改编号');
    });

    test('前缀/篇级：附录·附表开头剔除、第X篇剔除、第X章实习教程章保留', () {
      final out = effectiveTocChapters({
        'chapters': [
          {'no': 1, 'title': '目录', 'page_start': 3},
          {'no': 2, 'title': '第一章 绪论', 'page_start': 10},
          {'no': 3, 'title': '附录 口腔解剖生理学实验教程', 'page_start': 284},
          {'no': 4, 'title': '附录I 医学影像诊断学实习教程', 'page_start': 200},
          {'no': 5, 'title': '附表 国内12所口腔医学院统计分析', 'page_start': 370},
          {'no': 6, 'title': '第一篇 总论', 'page_start': 11},
          {'no': 7, 'title': '中英文名词对照索引', 'page_start': 329},
        ],
        'sections': <Object?>[],
      });
      expect(out.length, 1, reason: '附录/附表前缀与篇级条目全部剔除');
      expect(out.single['no'], 2);
      expect(out.single['title'], '第一章 绪论');

      final out2 = effectiveTocChapters({
        'chapters': [
          {'no': 17, 'title': '第十五章 儿童口腔医学实习教程', 'page_start': 252},
          {'no': 18, 'title': '中英文名词对照索引', 'page_start': 269},
        ],
        'sections': <Object?>[],
      });
      expect(out2.length, 1, reason: '带「第X章」编号的实习教程章必须保留');
      expect(out2.single['no'], 17, reason: '稀疏原 no 保留');
    });
  });

  // ---------------- 幂等 ----------------

  group('幂等', () {
    test('同 sidecar 二跑 / 已变换 chapters 再跑——结构完全一致（双路径）', () {
      // 救援路径：sections 永远保留不动 → 二跑一致
      final derm = dermSidecar();
      final r1 = effectiveTocChapters(derm);
      expect(jsonEncode(effectiveTocChapters(derm)), jsonEncode(r1));
      // 救援产物作为 chapters 再跑 → 真章数 29 ≥ 2 走过滤路径空操作
      final dermAgain = {...derm, 'chapters': r1};
      expect(jsonEncode(effectiveTocChapters(dermAgain)), jsonEncode(r1));

      // 过滤路径（稀疏编号）：幸存者再过滤不变
      final oms = omsSidecar();
      final s1 = effectiveTocChapters(oms);
      expect(jsonEncode(effectiveTocChapters(oms)), jsonEncode(s1));
      final omsAgain = {...oms, 'chapters': s1};
      expect(jsonEncode(effectiveTocChapters(omsAgain)), jsonEncode(s1));

      // 尾巴剥离后归一为 no-op
      final ortho = orthoSidecar();
      final t1 = effectiveTocChapters(ortho);
      final orthoAgain = {...ortho, 'chapters': t1};
      expect(jsonEncode(effectiveTocChapters(orthoAgain)), jsonEncode(t1));
    });
  });

  // ---------------- 空防御 ----------------

  group('空防御（任何输入不抛异常）', () {
    test('chapters 非 List / 空列表 → 空结果', () {
      expect(effectiveTocChapters({'chapters': 'nope'}), isEmpty);
      expect(effectiveTocChapters({}), isEmpty);
      expect(
          effectiveTocChapters({'chapters': null, 'sections': <Object?>[]}),
          isEmpty);
      expect(
          effectiveTocChapters({'chapters': <Object?>[], 'sections': <Object?>[]}),
          isEmpty);
    });

    test('sections 非 List → chapters 原样返回', () {
      final ch = [
        {'no': 1, 'title': '目录', 'page_start': 3},
        {'no': 2, 'title': '第一章 总论', 'page_start': 9},
      ];
      final out =
          effectiveTocChapters({'chapters': ch, 'sections': 'garbage'});
      expect(jsonEncode(out), jsonEncode(ch),
          reason: '宁可不修，绝不歪曲数据');
    });

    test('条目缺 title → 整体退化原样；非 Map 条目静默丢弃', () {
      final ch = [
        {'no': 1, 'page_start': 3}, // 缺 title
        {'no': 2, 'title': '第一章 总论', 'page_start': 9},
      ];
      final out = effectiveTocChapters({'chapters': ch, 'sections': <Object?>[]});
      expect(jsonEncode(out), jsonEncode(ch),
          reason: '整体退化：不过滤、不归一、不重编');

      final out2 = effectiveTocChapters({
        'chapters': [
          'junk-entry',
          {'no': 2, 'title': '第一章 总论', 'page_start': 9},
        ],
        'sections': <Object?>[],
      });
      expect(out2.length, 1, reason: '非 Map 条目无法装入返回类型 → 丢弃');
      expect(out2.single['no'], 2);
      expect(out2.single['title'], '第一章 总论');
    });

    test('sections 条目畸形 → 同样退化 chapters 原样', () {
      final ch = [
        {'no': 1, 'title': '目录', 'page_start': 3},
        {'no': 2, 'title': '第一章 总论', 'page_start': 9},
      ];
      final out = effectiveTocChapters({
        'chapters': ch,
        'sections': [
          {'chapter_no': 1, 'page_start': 9}, // 缺 title
        ],
      });
      expect(jsonEncode(out), jsonEncode(ch));
    });
  });

  // ---------------- 稀疏编号接线（progress_db 收口按最大 no） ----------------

  group('稀疏编号接线', () {
    test('initFromTocSidecar：收口=最大 no；推进/跳过上界同口径', () {
      final tmp = Directory.systemTemp.createTempSync('hengya-tocch-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final toc = Directory('${tmp.path}${Platform.pathSeparator}toc')
        ..createSync();
      // oms 同构：过滤后幸存 no=3..6（条目数 4、最大 no=6）
      File('${toc.path}${Platform.pathSeparator}oms.json')
          .writeAsStringSync(jsonEncode(omsSidecar()));

      final data = emptyProgress();
      final r = initFromTocSidecar(data, toc.path, 'oms');
      expect(r.ok, true, reason: r.note);
      expect(r.note, contains('4 章'), reason: 'note 报有效章数（非 sidecar 8 条）');
      final e = (data['subjects'] as Map)['oms'] as Map<String, Object?>;
      expect([for (final c in e['chapters'] as List) (c as Map)['no']],
          [3, 4, 5, 6],
          reason: '落库即稀疏编号');

      // 推进到最大 no=6 可达（旧按条目数 4 会拒绝：6 > 4）
      final adv = setSubjectNo(data, 'oms', 6);
      expect(adv.ok, true, reason: '上界=最大 no（实习教程 no=6 可达）');
      expect(applyChange(data, 'oms', 7).ok, false,
          reason: '超出罗盘：7 > 最大 no 6');

      // 已有条目重 init：learned_through=6 不被「条目数 4」错误截断
      final r2 = initFromTocSidecar(data, toc.path, 'oms');
      expect(r2.ok, true);
      expect(r2.note, contains('保留进度与历史'));
      expect(e['learned_through'], 6, reason: '收口按最大 no，保留进度');

      // 超界脏数据自愈：99 → 收口到最大 no 6（非条目数 4）
      e['learned_through'] = 99;
      initFromTocSidecar(data, toc.path, 'oms');
      expect(e['learned_through'], 6);

      // 跳过章规范化域同样按最大 no：skip no=6（实习教程）可保留
      final skip = setSubjectChapters(data, 'oms', skipped: [6]);
      expect(skip.ok, true, reason: skip.note);
      expect(skippedChaptersOf(e), [6],
          reason: 'no=6 > 条目数 4 仍可跳过（⑨ 契约域=最大 no）');
    });
  });
}
