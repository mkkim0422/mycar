import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../core/theme/app_theme.dart';

/// 약관·정책 카테고리.
///
/// 각 항목은 `assets/legal/` 의 Markdown 파일을 가리킨다. 패키지 의존성 없이
/// 자체 파서로 헤더(`#`, `##`, `###`) · 리스트(`-`) · 표(`|`) 를 간이 렌더링한다.
enum PolicyDocument {
  privacy(
    title: '개인정보처리방침',
    assetPath: 'assets/legal/privacy_policy.md',
  ),
  location(
    title: '위치기반서비스 이용약관',
    assetPath: 'assets/legal/location_terms.md',
  ),
  terms(
    title: '서비스 이용약관',
    assetPath: 'assets/legal/terms_of_service.md',
  );

  final String title;
  final String assetPath;
  const PolicyDocument({required this.title, required this.assetPath});
}

/// 약관 본문을 풀스크린으로 표시한다.
///
/// 외부 URL 의존 없이 앱에 번들된 Markdown 을 그대로 보여줘 네트워크 끊김에도
/// 사용자가 정책을 확인할 수 있도록 한다 (Play Store 정책 + PIPA 30조 충족).
class PolicyPage extends StatefulWidget {
  final PolicyDocument doc;
  const PolicyPage({super.key, required this.doc});

  @override
  State<PolicyPage> createState() => _PolicyPageState();
}

class _PolicyPageState extends State<PolicyPage> {
  String? _content;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final text = await rootBundle.loadString(widget.doc.assetPath);
      if (!mounted) return;
      setState(() => _content = text);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppTheme.gray900),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          widget.doc.title,
          style: const TextStyle(
            color: AppTheme.gray900,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_error) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '약관 파일을 불러올 수 없습니다.\n앱을 재설치하거나 고객센터로 문의해 주세요.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.gray500),
          ),
        ),
      );
    }
    if (_content == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: _SimpleMarkdown(text: _content!),
    );
  }
}

/// 가벼운 Markdown 렌더러 — 약관 표시에 필요한 최소 문법만 지원.
///
/// 지원: `# H1`, `## H2`, `### H3`, `- 리스트`, 표(`| ... |`), 굵게(`**...**`).
/// flutter_markdown 의존성을 피해 빌드 사이즈를 줄인다.
class _SimpleMarkdown extends StatelessWidget {
  final String text;
  const _SimpleMarkdown({required this.text});

  @override
  Widget build(BuildContext context) {
    final lines = text.split('\n');
    final widgets = <Widget>[];
    int i = 0;
    while (i < lines.length) {
      final line = lines[i];

      // ── 표 (연속된 | ... | 줄) ───────────────────────────────────────
      if (line.trimLeft().startsWith('|')) {
        final tableLines = <String>[];
        while (i < lines.length && lines[i].trimLeft().startsWith('|')) {
          tableLines.add(lines[i]);
          i++;
        }
        widgets.add(_buildTable(tableLines));
        continue;
      }

      // ── 헤더 ───────────────────────────────────────────────────────
      if (line.startsWith('### ')) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 6),
          child: Text(
            line.substring(4),
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppTheme.gray900,
            ),
          ),
        ));
      } else if (line.startsWith('## ')) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 24, bottom: 10),
          child: Text(
            line.substring(3),
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: AppTheme.gray900,
              letterSpacing: -0.3,
            ),
          ),
        ));
      } else if (line.startsWith('# ')) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            line.substring(2),
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              color: AppTheme.gray900,
              letterSpacing: -0.5,
            ),
          ),
        ));
      }
      // ── 리스트 ─────────────────────────────────────────────────────
      else if (line.startsWith('- ') || line.startsWith('* ')) {
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('• ', style: TextStyle(color: AppTheme.gray500)),
              Expanded(child: _renderInline(line.substring(2))),
            ],
          ),
        ));
      }
      // ── 빈 줄 ──────────────────────────────────────────────────────
      else if (line.trim().isEmpty) {
        widgets.add(const SizedBox(height: 8));
      }
      // ── 일반 단락 ─────────────────────────────────────────────────
      else {
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: _renderInline(line),
        ));
      }
      i++;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  /// `**굵게**` 처리. 그 외는 일반 텍스트.
  Widget _renderInline(String line) {
    final spans = <TextSpan>[];
    final regex = RegExp(r'\*\*(.+?)\*\*');
    int pos = 0;
    for (final m in regex.allMatches(line)) {
      if (m.start > pos) {
        spans.add(TextSpan(text: line.substring(pos, m.start)));
      }
      spans.add(TextSpan(
        text: m.group(1)!,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ));
      pos = m.end;
    }
    if (pos < line.length) {
      spans.add(TextSpan(text: line.substring(pos)));
    }
    return Text.rich(
      TextSpan(
        children: spans,
        style: const TextStyle(
          fontSize: 14,
          height: 1.65,
          color: AppTheme.gray900,
          letterSpacing: -0.1,
        ),
      ),
    );
  }

  Widget _buildTable(List<String> tableLines) {
    // 첫 줄: 헤더, 둘째 줄: 구분선(---) 무시, 셋째 줄부터 본문.
    final rows = tableLines.map((l) {
      final cells = l.trim();
      final parts = cells
          .substring(cells.startsWith('|') ? 1 : 0,
              cells.endsWith('|') ? cells.length - 1 : cells.length)
          .split('|')
          .map((s) => s.trim())
          .toList();
      return parts;
    }).toList();

    if (rows.isEmpty) return const SizedBox.shrink();

    // 구분선(`---`) 행 제거
    rows.removeWhere((r) => r.every((c) => RegExp(r'^-+$').hasMatch(c)));
    if (rows.isEmpty) return const SizedBox.shrink();

    final header = rows.first;
    final body = rows.skip(1).toList();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: AppTheme.gray100, width: 1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            // 헤더
            Container(
              decoration: const BoxDecoration(
                color: Color(0xFFF7F8FA),
                borderRadius:
                    BorderRadius.vertical(top: Radius.circular(7)),
              ),
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              child: Row(
                children: header
                    .map((c) => Expanded(
                          child: Text(
                            c,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.gray900,
                            ),
                          ),
                        ))
                    .toList(),
              ),
            ),
            // 본문
            ...body.map((row) => Container(
                  decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: Color(0xFFEEF1F4))),
                  ),
                  padding:
                      const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: row
                        .map((c) => Expanded(
                              child: Text(
                                c,
                                style: const TextStyle(
                                  fontSize: 12,
                                  height: 1.5,
                                  color: AppTheme.gray900,
                                ),
                              ),
                            ))
                        .toList(),
                  ),
                )),
          ],
        ),
      ),
    );
  }
}
