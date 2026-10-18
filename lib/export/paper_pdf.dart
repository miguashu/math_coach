import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../geometry/dsl/figure.dart';
import '../geometry/render/figure_pdf.dart';
import '../geometry/solver/solver.dart';
import '../typeset/vertical.dart';
import '../typeset/vertical_pdf.dart';
import 'paper.dart';

/// 组卷 PDF 导出。
///
/// 全部本地生成：几何是真矢量（PdfGraphics 路径），中文字体随文档内嵌，
/// 不写任何 EXIF/位置元数据（孩子的作业照片信息不能随试卷流出）。
///
/// 字体传原始字节：widgets 层用 pw.Font（给 pw.Text 排版用），
/// 绘图层用 PdfFont（给 PdfGraphics 用），两者都从同一份字节构建。
class PaperPdfExporter {
  final ByteData fontData;
  final ByteData? fontBoldData;

  const PaperPdfExporter({required this.fontData, this.fontBoldData});

  /// 生成 PDF 字节流。
  Future<Uint8List> export(Paper paper) async {
    final doc = pw.Document(
      title: paper.title,
      author: '小学数学辅导',
      creator: 'math_coach',
      compress: true,
    );

    final pdfDoc = doc.document;
    final gFont = PdfTtfFont(pdfDoc, fontData);
    final gFontBold = fontBoldData != null ? PdfTtfFont(pdfDoc, fontBoldData!) : gFont;

    final wFont = pw.Font.ttf(fontData);
    final wFontBold = fontBoldData != null ? pw.Font.ttf(fontBoldData!) : wFont;

    final figureRenderer = FigurePdfRenderer(font: gFont, fontBold: gFontBold);
    final verticalPdf = VerticalPdf(font: gFont, fontBold: gFontBold);

    final items = Paper.sortForPrint(paper.items);
    // 题号按"打印顺序"重新编 1..N：错题卷按重要度排序后，
    // 若沿用原始编号，学生会看到 9、10、11 开头的试卷。
    final numbered = <MapEntry<int, PaperItem>>[
      for (var i = 0; i < items.length; i++) MapEntry(i + 1, items[i]),
    ];
    final chunks = _chunk(numbered, paper.config.itemsPerPage);

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        header: (ctx) => _header(ctx, paper, wFont, wFontBold),
        footer: (ctx) => _footer(ctx, wFont),
        build: (ctx) => [
          for (final chunk in chunks)
            ..._buildPage(chunk, paper, ctx, figureRenderer, verticalPdf, wFont, wFontBold),
        ],
      ),
    );

    return doc.save();
  }

  /// 单独导出答案页（家长自己保管，不给孩子）。
  Future<Uint8List> exportAnswers(Paper paper) async {
    final doc = pw.Document(title: '${paper.title}（答案）', compress: true);
    final wFont = pw.Font.ttf(fontData);
    final wFontBold = fontBoldData != null ? pw.Font.ttf(fontBoldData!) : wFont;
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        build: (ctx) => [
          pw.Text('${paper.title} · 答案',
              style: pw.TextStyle(font: wFontBold, fontSize: 16)),
          pw.SizedBox(height: 10),
          ...Paper.sortForPrint(paper.items).asMap().entries.map((e) => pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 6),
                child: pw.Text('${e.key + 1}. ${e.value.answer}',
                    style: pw.TextStyle(font: wFont, fontSize: 12)),
              )),
        ],
      ),
    );
    return doc.save();
  }

  List<List<MapEntry<int, PaperItem>>> _chunk(List<MapEntry<int, PaperItem>> items, int size) {
    if (size <= 0) return [items];
    final out = <List<MapEntry<int, PaperItem>>>[];
    for (var i = 0; i < items.length; i += size) {
      out.add(items.sublist(i, (i + size).clamp(0, items.length)));
    }
    return out;
  }

  pw.Widget _header(pw.Context ctx, Paper paper, pw.Font font, pw.Font fontBold) {
    if (ctx.pageNumber == 1) {
      return pw.Container(
        alignment: pw.Alignment.centerLeft,
        margin: const pw.EdgeInsets.only(bottom: 10),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(paper.title,
                style: pw.TextStyle(font: fontBold, fontSize: 18)),
            pw.SizedBox(height: 4),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  '姓名 ____________    用时 ______ 分钟    正确率 ______',
                  style: pw.TextStyle(font: font, fontSize: 10, color: PdfColors.grey700),
                ),
                pw.Text(
                  '共 ${paper.count} 题',
                  style: pw.TextStyle(font: font, fontSize: 10, color: PdfColors.grey700),
                ),
              ],
            ),
            pw.Divider(height: 8, thickness: 0.6),
          ],
        ),
      );
    }
    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 8),
      child: pw.Text(paper.title,
          style: pw.TextStyle(font: font, fontSize: 10, color: PdfColors.grey700)),
    );
  }

  pw.Widget _footer(pw.Context ctx, pw.Font font) => pw.Container(
        alignment: pw.Alignment.centerRight,
        margin: const pw.EdgeInsets.only(top: 6),
        child: pw.Text('第 ${ctx.pageNumber} / ${ctx.pagesCount} 页',
            style: pw.TextStyle(font: font, fontSize: 9, color: PdfColors.grey600)),
      );

  List<pw.Widget> _buildPage(
    List<MapEntry<int, PaperItem>> chunk,
    Paper paper,
    pw.Context ctx,
    FigurePdfRenderer figureRenderer,
    VerticalPdf verticalPdf,
    pw.Font font,
    pw.Font fontBold,
  ) {
    final ws = <pw.Widget>[];
    for (var i = 0; i < chunk.length; i++) {
      final item = chunk[i].value;
      final index = chunk[i].key;
      ws.add(_buildItem(index, item, paper.config, figureRenderer, verticalPdf, font, fontBold));
      if (i < chunk.length - 1) ws.add(pw.SizedBox(height: 14));
    }

    // 答案：紧邻题目
    if (paper.config.answerPlacement == AnswerPlacement.inline) {
      ws.add(pw.SizedBox(height: 10));
      ws.add(pw.Container(
        padding: const pw.EdgeInsets.all(6),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
        ),
        child: pw.Text(
          '答案：${chunk.map((e) => e.value.answer).join('    ')}',
          style: pw.TextStyle(font: font, fontSize: 10, color: PdfColors.grey800),
        ),
      ));
    }
    return ws;
  }

  pw.Widget _buildItem(
    int index,
    PaperItem item,
    PaperConfig config,
    FigurePdfRenderer figureRenderer,
    VerticalPdf verticalPdf,
    pw.Font font,
    pw.Font fontBold,
  ) {
    final children = <pw.Widget>[
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('$index. ', style: pw.TextStyle(font: fontBold, fontSize: 13)),
          pw.Expanded(
            child: pw.Text(item.stem,
                style: pw.TextStyle(font: font, fontSize: 13, lineSpacing: 3)),
          ),
        ],
      ),
    ];

    // 图形
    if (item.figure != null) {
      final solved = FigureSolver.solve(item.figure!);
      children.add(pw.SizedBox(height: 8));
      children.add(pw.Align(
        alignment: pw.Alignment.centerLeft,
        child: figureRenderer.render(solved.scene, widthPt: 190),
      ));
    }

    // 竖式
    if (item.vertical != null) {
      children.add(pw.SizedBox(height: 8));
      children.add(verticalPdf.render(item.vertical!));
    }
    if (item.longDivision != null) {
      children.add(pw.SizedBox(height: 8));
      children.add(verticalPdf.renderLongDivision(item.longDivision!));
    }

    // 知识点（可关）
    if (config.showKnowledge && item.knowledgeLabel != null) {
      children.add(pw.SizedBox(height: 4));
      children.add(pw.Text('考点：${item.knowledgeLabel}',
          style: pw.TextStyle(font: font, fontSize: 9, color: PdfColors.grey700)));
    }

    // 作答区留白
    children.add(pw.SizedBox(height: 6));
    children.add(pw.Container(
      height: config.answerSpace,
      width: double.infinity,
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey300, width: 0.5),
      ),
    ));

    // 用 Row 包一层：MultiPage 会从 Column 中间把题目拆到两页
    // （题干在一页、竖式在另一页），Row 不可拆分，整题会整体移到下页。
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Container(
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.grey300, width: 0.5),
              borderRadius: pw.BorderRadius.circular(4),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ),
      ],
    );
  }
}
