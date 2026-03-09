import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../drugs/add_drug_page.dart';
import '../drugs/repository/drugs_repository.dart';

class DrugsPage extends StatefulWidget {
  const DrugsPage({super.key});

  @override
  State<DrugsPage> createState() => _DrugsPageState();
}

class _DrugsPageState extends State<DrugsPage> {
  late final DrugsRepository repo = DrugsRepository(Supabase.instance.client);

  late Future<_Bundle> _future;
  final _searchCtl = TextEditingController();
  String _q = '';

  final _scrollCtl = ScrollController();

  // ✅ ใช้สำหรับ highlight + scroll ไปที่รายการที่เพิ่งบันทึก
  String? _highlightDrugId;

  // key ต่อการ์ดแต่ละตัว เพื่อ scroll ไปตำแหน่งได้
  final Map<String, GlobalKey> _cardKeys = {};

  @override
  void initState() {
    super.initState();
    _future = _load();
    _searchCtl.addListener(() {
      setState(() => _q = _searchCtl.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    _scrollCtl.dispose();
    super.dispose();
  }

  // ✅ helper: ถือว่า active ถ้า is_active == true หรือ status == 'active'
  bool _isDrugActive(Map<String, dynamic> d) {
    final isActive = d['is_active'];
    if (isActive is bool) return isActive;

    final status = (d['status'] ?? '').toString().toLowerCase().trim();
    if (status.isNotEmpty) return status == 'active';

    // ถ้าไม่มีทั้งสอง field ให้ถือว่า active (กันข้อมูลเก่า)
    return true;
  }

  Future<_Bundle> _load() async {
    final drugsRaw = await repo.listDrugs();

    // ✅ สำคัญ: แสดงเฉพาะยาใช้งานอยู่ (active) บนหน้า Drugs
    final drugs = drugsRaw.where(_isDrugActive).toList();

    final lots = await repo.listDrugLotsAllFromView();
    return _Bundle(drugs: drugs, lots: lots);
  }

  void _reload() {
    setState(() => _future = _load());
  }

  // ✅ เลื่อนไปหาการ์ด + highlight
  Future<void> _scrollToHighlighted() async {
    final id = _highlightDrugId;
    if (id == null) return;

    await Future.delayed(const Duration(milliseconds: 60));
    if (!mounted) return;

    final key = _cardKeys[id];
    final ctx = key?.currentContext;
    if (ctx == null) return;

    await Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
      alignment: 0.15,
    );

    await Future.delayed(const Duration(milliseconds: 1800));
    if (!mounted) return;
    setState(() => _highlightDrugId = null);
  }

  // ✅ เปิดหน้า add: รับ result เป็น drugId
  Future<void> _openAdd() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AddDrugPage()),
    );

    if (result is String && result.isNotEmpty) {
      setState(() => _highlightDrugId = result);
      _reload();
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('บันทึกยาเรียบร้อย')),
      );

      _future.whenComplete(() => _scrollToHighlighted());
    }
  }

  // ✅ เปิดหน้า edit: รับ result เป็น drugId
  Future<void> _openEdit(String drugId) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AddDrugPage(drugId: drugId)),
    );

    if (result is String && result.isNotEmpty) {
      setState(() => _highlightDrugId = result);
      _reload();
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('บันทึกการแก้ไขเรียบร้อย')),
      );

      _future.whenComplete(() => _scrollToHighlighted());
    }
  }

  // ✅ ลบยา + แจ้งผู้ใช้แบบเข้าใจง่าย (สต็อกคงเหลือ / เคยมีประวัติ)
  Future<void> _deleteDrug(String id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('ลบรายการยา'),
        content: const Text(
          'ต้องการลบรายการนี้ใช่ไหม?\n\n'
          'หมายเหตุ: ระบบจะลบได้เฉพาะยา “ที่ไม่มีสต็อกคงเหลือ” และ “ไม่เคยมีประวัติรับเข้า/ขาย” '
          'เพื่อป้องกันข้อมูลผิดพลาด',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('ยกเลิก'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('ลบ'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await repo.deleteDrug(id);
      if (!mounted) return;

      setState(() {
        _highlightDrugId = null;
        _future = _load(); // ✅ reload แล้วจะยังคงแสดงเฉพาะ active
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ลบเรียบร้อย')),
      );
    } catch (e) {
      if (!mounted) return;

      final raw = e.toString();

      String title = 'ลบไม่สำเร็จ';
      String body = 'ระบบไม่สามารถลบรายการนี้ได้\n\nรายละเอียด: $raw';
      bool showInactivate = true;

      // ✅ กรณี 1: ยังมีสต็อกคงเหลือ
      if (raw.contains('DRUG_HAS_STOCK:')) {
        title = 'ลบไม่ได้ (ยังมีสต็อกคงเหลือ)';
        final after = raw.split('DRUG_HAS_STOCK:').last.trim();

        // ดึงเลขคร่าว ๆ (กัน format ต่าง ๆ)
        final qtyMatch = RegExp(r'(-?\d+(\.\d+)?)').firstMatch(after);
        final qtyStr = qtyMatch?.group(1) ?? '-';

        body =
            'ยานี้ยังมีสต็อกคงเหลืออยู่ในคลัง\n'
            'จึงไม่สามารถลบได้ เพื่อป้องกันข้อมูลสต็อกผิดพลาด\n\n'
            'คงเหลือโดยประมาณ: $qtyStr (หน่วยฐาน)\n\n'
            'ทางเลือกที่แนะนำ:\n'
            '• ถ้าต้องการหยุดใช้ยา: กด “ปิดการใช้งาน (Inactive)”\n'
            '• หรือทำรายการให้สต็อกเป็น 0 ก่อนแล้วค่อยลบ';
      }

      // ✅ กรณี 2: สต็อกเป็น 0 แต่เคยมีประวัติรับเข้า/ขาย
      else if (raw.contains('DRUG_HAS_TXN:')) {
        title = 'ลบไม่ได้ (เคยมีประวัติทำรายการ)';

        final inMatch = RegExp(r'in=(\d+)').firstMatch(raw);
        final outMatch = RegExp(r'out=(\d+)').firstMatch(raw);
        final inCnt = inMatch?.group(1) ?? '-';
        final outCnt = outMatch?.group(1) ?? '-';

        body =
            'ยานี้เคยมีการ “รับเข้า” หรือ “ขาย/จ่ายออก” มาก่อน\n'
            'ระบบจึงไม่อนุญาตให้ลบ เพื่อให้ประวัติใบรับเข้า/ใบขายยังถูกต้อง\n\n'
            'สรุปประวัติ:\n'
            '• รับเข้า: $inCnt รายการ\n'
            '• จ่ายออก/ขาย: $outCnt รายการ\n\n'
            'ทางเลือกที่แนะนำ:\n'
            '• ปิดการใช้งาน (Inactive) เพื่อซ่อน/หยุดใช้ยา\n'
            '  (ประวัติยังอยู่ครบ)';
      }

      // ✅ กรณี 3: ไม่พบยา/สิทธิ์
      else if (raw.contains('DRUG_NOT_FOUND')) {
        title = 'ลบไม่สำเร็จ';
        body = 'ไม่พบรายการยานี้ หรือคุณไม่มีสิทธิ์ลบรายการดังกล่าว';
        showInactivate = false;
      }

      final choose = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('ปิด'),
            ),
            if (showInactivate)
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('ปิดการใช้งานแทน'),
              ),
          ],
        ),
      );

      if (choose == true) {
        try {
          await repo.setDrugActive(id, false);

          // ✅ reload แล้วรายการจะหายไปจากหน้า Drugs ทันที (เพราะเราโชว์เฉพาะ active)
          setState(() {
            _highlightDrugId = null;
            _future = _load();
          });

          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('ปิดการใช้งานเรียบร้อย')),
          );
        } catch (e2) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('ปิดการใช้งานไม่สำเร็จ: $e2')),
          );
        }
      }
    }
  }

  List<Map<String, dynamic>> _filter(List<Map<String, dynamic>> items) {
    if (_q.isEmpty) return items;

    bool hit(Map<String, dynamic> d) {
      final code = (d['code'] ?? '').toString().toLowerCase();
      final g = (d['generic_name'] ?? '').toString().toLowerCase();
      final b = (d['brand_name'] ?? '').toString().toLowerCase();
      return code.contains(_q) || g.contains(_q) || b.contains(_q);
    }

    return items.where(hit).toList();
  }

  String _dateOnly(dynamic v) {
    if (v == null) return '-';
    final s = v.toString();
    return s.length >= 10 ? s.substring(0, 10) : s;
  }

  double _toDouble(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  int _toInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  String _fmtNum(double v) {
    if (v % 1 == 0) return v.toStringAsFixed(0);
    return v.toStringAsFixed(2);
  }

  // ✅ อ่านจำนวนคงเหลือจากหลายชื่อคอลัมน์ (กัน view ไม่ตรงชื่อ)
  double _readLotQtyBase(Map<String, dynamic> lotRow) {
    final candidates = [
      'qty_on_hand_base',
      'lot_on_hand_base',
      'on_hand_base',
      'qty_on_hand',
      'lot_on_hand',
    ];
    for (final k in candidates) {
      if (lotRow.containsKey(k)) {
        return _toDouble(lotRow[k]);
      }
    }
    return 0;
  }

  _StockStatus _calcStatus({required double totalBase, required double reorderPoint}) {
    if (totalBase <= 0) return _StockStatus.out;
    if (reorderPoint > 0 && totalBase <= reorderPoint) return _StockStatus.low;
    return _StockStatus.ok;
  }

  Future<void> _showLotsDialog({
    required String drugName,
    required String unit,
    required List<Map<String, dynamic>> lots,
  }) async {
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('ล็อตของ $drugName'),
        content: SizedBox(
          width: 520,
          child: lots.isEmpty
              ? const Text('ยังไม่มีล็อต')
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: lots.length,
                  separatorBuilder: (_, __) => const Divider(height: 12),
                  itemBuilder: (_, i) {
                    final l = lots[i];
                    final lotNo = (l['lot_no'] ?? '-').toString();
                    final exp = _dateOnly(l['exp_date']);
                    final qty = _fmtNum(_readLotQtyBase(l));
                    return Row(
                      children: [
                        Expanded(
                          child: Text(
                            'ล็อต: $lotNo\nหมดอายุ: $exp',
                            style: const TextStyle(height: 1.25),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary.withOpacity(0.10),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text('$qty $unit', style: const TextStyle(fontWeight: FontWeight.w700)),
                        ),
                      ],
                    );
                  },
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('ปิด')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: const Color(0xFFF3F6FB),
      body: SafeArea(
        child: FutureBuilder<_Bundle>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return Center(child: Text('โหลดไม่สำเร็จ: ${snap.error}'));
            }

            final data = snap.data ?? const _Bundle(drugs: [], lots: []);
            final allDrugs = data.drugs; // ✅ ตอนนี้คือ "active เท่านั้น"
            final drugs = _filter(allDrugs);

            final byDrug = <String, List<Map<String, dynamic>>>{};
            for (final l in data.lots) {
              final drugId = (l['drug_id'] ?? '').toString();
              if (drugId.isEmpty) continue;
              (byDrug[drugId] ??= []).add(l);
            }

            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980),
                child: ListView(
                  controller: _scrollCtl,
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: Colors.grey.shade200),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.04),
                            blurRadius: 14,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.search_rounded, color: Colors.grey.shade700),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _searchCtl,
                              decoration: const InputDecoration(
                                hintText: 'ค้นหา: ชื่อยา / รหัส / Brand',
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                          if (_q.isNotEmpty)
                            IconButton(
                              tooltip: 'ล้าง',
                              onPressed: () => _searchCtl.clear(),
                              icon: const Icon(Icons.clear_rounded),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (allDrugs.isEmpty)
                      Center(
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.medication_rounded, size: 44),
                                const SizedBox(height: 10),
                                Text('ยังไม่มียาในระบบ', style: Theme.of(context).textTheme.titleMedium),
                                const SizedBox(height: 6),
                                const Text('กดปุ่ม + เพื่อเพิ่มยา'),
                              ],
                            ),
                          ),
                        ),
                      )
                    else if (drugs.isEmpty)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 18),
                          child: Text('ไม่พบผลลัพธ์สำหรับ “$_q”'),
                        ),
                      )
                    else
                      ...drugs.map((d) {
                        final id = (d['id'] ?? '').toString();
                        _cardKeys.putIfAbsent(id, () => GlobalKey());

                        final isHighlight = (_highlightDrugId != null && _highlightDrugId == id);

                        final code = (d['code'] ?? '').toString();
                        final g = (d['generic_name'] ?? '-').toString();
                        final b = (d['brand_name'] ?? '').toString();
                        final dosageForm = (d['dosage_form'] ?? '').toString();
                        final strength = (d['strength'] ?? '').toString();
                        final unit = (d['base_unit'] ?? '').toString();

                        final packUnit = (d['pack_unit'] ?? '').toString().trim();
                        final packToBase = _toDouble(d['pack_to_base']);
                        final reorderPoint = _toDouble(d['reorder_point']);

                        final subtitle = [
                          if (b.isNotEmpty) b,
                          if (dosageForm.isNotEmpty) dosageForm,
                          if (strength.isNotEmpty) strength,
                          if (unit.isNotEmpty) unit,
                        ].join(' • ');

                        final lotsRaw = (byDrug[id] ?? [])
                          ..sort((a, b) => _dateOnly(a['exp_date']).compareTo(_dateOnly(b['exp_date'])));

                        double total = 0;
                        for (final l in lotsRaw) {
                          total += _readLotQtyBase(l);
                        }

                        final status = _calcStatus(totalBase: total, reorderPoint: reorderPoint);

                        String packText = '';
                        if (packUnit.isNotEmpty && packToBase > 0) {
                          final packQty = total / packToBase;
                          packText = ' • ≈ ${_fmtNum(packQty)} $packUnit';
                        }

                        final badge = _StatusBadge.from(status, reorderPoint: reorderPoint, unit: unit);

                        return AnimatedContainer(
                          key: _cardKeys[id],
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOut,
                          margin: const EdgeInsets.only(bottom: 14),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(24),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.05),
                                blurRadius: 18,
                                offset: const Offset(0, 10),
                              ),
                              if (isHighlight)
                                BoxShadow(
                                  color: cs.primary.withOpacity(0.18),
                                  blurRadius: 22,
                                  offset: const Offset(0, 14),
                                ),
                            ],
                          ),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: isHighlight ? cs.primary.withOpacity(0.30) : Colors.grey.shade200,
                                width: isHighlight ? 1.4 : 1,
                              ),
                            ),
                            padding: const EdgeInsets.all(18),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '$g ${code.isEmpty ? '' : '($code)'}',
                                            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            subtitle.isEmpty ? '-' : subtitle,
                                            style: TextStyle(color: Colors.grey.shade700),
                                          ),
                                          const SizedBox(height: 10),
                                          Text(
                                            'คงเหลือ ${_fmtNum(total)} ${unit.isEmpty ? '' : unit}$packText',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w900,
                                              color: cs.primary,
                                              fontSize: 15,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    _StatusPill(text: badge.text, icon: badge.icon, tone: badge.tone),
                                  ],
                                ),
                                const SizedBox(height: 14),
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  children: [
                                    _ActionPillButton(
                                      icon: Icons.remove_red_eye_outlined,
                                      text: lotsRaw.isEmpty ? 'ยังไม่มีล็อต' : 'ดูล็อต (${lotsRaw.length})',
                                      enabled: lotsRaw.isNotEmpty,
                                      onTap: lotsRaw.isEmpty
                                          ? null
                                          : () => _showLotsDialog(drugName: g, unit: unit, lots: lotsRaw),
                                      tone: _ActionTone.primarySoft,
                                    ),
                                    _ActionPillButton(
                                      icon: Icons.edit_rounded,
                                      text: 'แก้ไข',
                                      enabled: id.isNotEmpty,
                                      onTap: id.isEmpty ? null : () => _openEdit(id),
                                      tone: _ActionTone.neutral,
                                    ),
                                    _ActionPillButton(
                                      icon: Icons.delete_outline_rounded,
                                      text: 'ลบ',
                                      enabled: id.isNotEmpty,
                                      onTap: id.isEmpty ? null : () => _deleteDrug(id),
                                      tone: _ActionTone.dangerSoft,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                  ],
                ),
              ),
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openAdd,
        child: const Icon(Icons.add_rounded),
      ),
    );
  }
}

class _Bundle {
  final List<Map<String, dynamic>> drugs;
  final List<Map<String, dynamic>> lots;
  const _Bundle({required this.drugs, required this.lots});
}

enum _StockStatus { ok, low, out }

class _StatusBadge {
  final String text;
  final IconData icon;
  final _Tone tone;
  _StatusBadge({required this.text, required this.icon, required this.tone});

  static _StatusBadge from(_StockStatus s, {required double reorderPoint, required String unit}) {
    switch (s) {
      case _StockStatus.out:
        return _StatusBadge(text: 'หมดสต็อก', icon: Icons.error_outline_rounded, tone: _Tone.red);
      case _StockStatus.low:
        final th = reorderPoint > 0
            ? ' (ต่ำกว่า ${reorderPoint % 1 == 0 ? reorderPoint.toStringAsFixed(0) : reorderPoint.toStringAsFixed(2)} ${unit.isEmpty ? '' : unit})'
            : '';
        return _StatusBadge(text: 'ใกล้หมด$th', icon: Icons.warning_amber_rounded, tone: _Tone.orange);
      case _StockStatus.ok:
      default:
        return _StatusBadge(text: 'ปกติ', icon: Icons.check_circle_outline_rounded, tone: _Tone.green);
    }
  }
}

enum _Tone { green, orange, red }

class _StatusPill extends StatelessWidget {
  final String text;
  final IconData icon;
  final _Tone tone;
  const _StatusPill({required this.text, required this.icon, required this.tone});

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;

    switch (tone) {
      case _Tone.green:
        bg = const Color(0xFFE9F8EF);
        fg = const Color(0xFF1F7A3E);
        break;
      case _Tone.orange:
        bg = const Color(0xFFFFF2E6);
        fg = const Color(0xFFB45309);
        break;
      case _Tone.red:
        bg = const Color(0xFFFFE8E8);
        fg = const Color(0xFFB91C1C);
        break;
    }

    return Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: fg.withOpacity(0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: fg),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: FontWeight.w900, color: fg),
            ),
          ),
        ],
      ),
    );
  }
}

enum _ActionTone { primarySoft, neutral, dangerSoft }

class _ActionPillButton extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool enabled;
  final VoidCallback? onTap;
  final _ActionTone tone;

  const _ActionPillButton({
    required this.icon,
    required this.text,
    required this.enabled,
    required this.onTap,
    required this.tone,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Color bg;
    Color border;
    Color fg;

    switch (tone) {
      case _ActionTone.primarySoft:
        bg = cs.primary.withOpacity(0.10);
        border = cs.primary.withOpacity(0.22);
        fg = cs.primary;
        break;
      case _ActionTone.dangerSoft:
        bg = Colors.red.withOpacity(0.08);
        border = Colors.red.withOpacity(0.20);
        fg = Colors.red.shade700;
        break;
      case _ActionTone.neutral:
      default:
        bg = Colors.grey.shade100;
        border = Colors.grey.shade300;
        fg = Colors.grey.shade900;
        break;
    }

    if (!enabled) {
      bg = Colors.grey.shade100;
      border = Colors.grey.shade200;
      fg = Colors.grey.shade500;
    }

    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: fg),
            const SizedBox(width: 8),
            Text(text, style: TextStyle(fontWeight: FontWeight.w800, color: fg)),
          ],
        ),
      ),
    );
  }
}