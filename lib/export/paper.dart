import '../geometry/dsl/figure.dart';
import '../typeset/vertical.dart';

/// 答案页位置。做成可配置项，家长自己决定。
enum AnswerPlacement {
  end('末尾统一'),
  inline('紧邻题目'),
  hidden('不打印答案');

  const AnswerPlacement(this.label);
  final String label;
}

/// 试卷配置：这几项直接决定打印体验，全部可配。
class PaperConfig {
  final String title;

  /// 每页题数（1 页 2 题还是 4 题，打印体验差别很大）。
  final int itemsPerPage;

  /// 每题作答区留白高度（PDF 点）。
  final double answerSpace;

  final AnswerPlacement answerPlacement;

  /// 是否在题目下方显示知识点（给孩子看还是给家长看，取向不同）。
  final bool showKnowledge;

  /// 是否显示难度。
  final bool showDifficulty;

  const PaperConfig({
    this.title = '错题练习卷',
    this.itemsPerPage = 4,
    this.answerSpace = 70,
    this.answerPlacement = AnswerPlacement.end,
    this.showKnowledge = true,
    this.showDifficulty = false,
  });
}

/// 试卷里的一道题。
class PaperItem {
  final String id;
  final String stem;

  /// 图形（可为 null，纯文字题）。
  final FigureSpec? figure;

  /// 需要画竖式的题（可为 null）。
  final VerticalLayout? vertical;

  /// 长除法（可为 null）。
  final LongDivision? longDivision;

  final String answer;
  final String? knowledgeLabel;
  final int difficulty;
  final int importance;

  const PaperItem({
    required this.id,
    required this.stem,
    required this.answer,
    this.figure,
    this.vertical,
    this.longDivision,
    this.knowledgeLabel,
    this.difficulty = 3,
    this.importance = 0,
  });
}

/// 一份试卷。
class Paper {
  final String title;
  final List<PaperItem> items;
  final PaperConfig config;
  final DateTime createdAt;

  const Paper({
    required this.title,
    required this.items,
    required this.config,
    required this.createdAt,
  });

  int get count => items.length;

  /// 组卷排序：重要度高的优先，其次难度降序。
  /// 注意这里按"重要度"而不是"错误次数"排序 —— 练了很多次和依然不会是两回事。
  static List<PaperItem> sortForPrint(List<PaperItem> items) {
    final list = [...items];
    list.sort((a, b) {
      final c = b.importance.compareTo(a.importance);
      if (c != 0) return c;
      return a.difficulty.compareTo(b.difficulty);
    });
    return list;
  }
}

/// 组卷筛选条件。
class PaperFilter {
  final int? grade;
  final String? domainCode;

  /// 知识编码前缀，如 'MA-G3-S1-NA-04' 表示整个单元。
  final String? codePrefix;

  /// 只出重要度 >= 该值的题。
  final int minImportance;

  final int? maxCount;

  const PaperFilter({
    this.grade,
    this.domainCode,
    this.codePrefix,
    this.minImportance = 0,
    this.maxCount,
  });
}
