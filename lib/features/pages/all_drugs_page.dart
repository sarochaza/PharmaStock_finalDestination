import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ถ้าพาธคุณต่าง ให้แก้ import นี้ให้ตรงโปรเจกต์
import '../drugs/add_drug_page.dart';

class AllDrugsPage extends StatefulWidget {
  const AllDrugsPage({super.key});

  @override
  State<AllDrugsPage> createState() => _AllDrugsPageState();
}

class _AllDrugsPageState extends State<AllDrugsPage> {
  final SupabaseClient _sb = Supabase.instance.client;

  bool _loading = true;
  String? _error;

  final TextEditingController _searchCtl = TextEditingController();
  String _q = '';

  // 0=ทั้งหมด, 1=ใช้งานอยู่, 2=ปิดการใช้งาน
  int _tab = 0;

  // raw rows from DB
  List<Map<String, dynamic>> _rows = [];

  @override
  void initState() {
    super.initState();
    _searchCtl.addListener(() {
      setState(() => _q = _searchCtl.text.trim().toLowerCase());
    });
    _load();
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  String _ownerId() {
    final u = _sb.auth.currentUser;
    if (u == null) throw Exception('ยังไม่ได้ล็อกอิน');
    return u.id;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final ownerId = _ownerId();

      final rows = await _sb
          .from('drugs')
          .select('''
            id,
            owner_id,
            code,
            generic_name,
            brand_name,
            dosage_form,
            strength,
            base_unit,
            pack_unit,
            pack_to_base,
            category,
            manufacturer,
            reorder_point,
            is_active,
            status,
            updated_at,
            created_at
          ''')
          .eq('owner_id', ownerId)
          .order('updated_at', ascending: false);

      _rows = (rows as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e) {
      _error = '$e';
      _rows = [];
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> _filteredRows() {
    final q = _q;
    final tab = _tab;

    bool matchTab(Map<String, dynamic> r) {
      final isActive = (r['is_active'] as bool?) ?? true;
      if (tab == 0) return true;
      if (tab == 1) return isActive == true;
      return isActive == false;
    }

    bool matchQuery(Map<String, dynamic> r) {
      if (q.isEmpty) return true;

      String s(dynamic v) => (v ?? '').toString().toLowerCase();
      final hay = [
        s(r['generic_name']),
        s(r['brand_name']),
        s(r['code']),
        s(r['manufacturer']),
        s(r['category']),
        s(r['dosage_form']),
        s(r['strength']),
        s(r['base_unit']),
        s(r['pack_unit']),
      ].join(' | ');

      return hay.contains(q);
    }

    return _rows.where((r) => matchTab(r) && matchQuery(r)).toList();
  }

  int _countTab(int tab) {
    int c = 0;
    for (final r in _rows) {
      final isActive = (r['is_active'] as bool?) ?? true;
      if (tab == 0) c++;
      if (tab == 1 && isActive) c++;
      if (tab == 2 && !isActive) c++;
    }
    return c;
  }

  Future<void> _setActive({
    required String drugId,
    required bool newActive,
  }) async {
    final ownerId = _ownerId();

    try {
      await _sb
          .from('drugs')
          .update({
            'is_active': newActive,
            'updated_at': DateTime.now().toIso8601String(),
          })
          .eq('owner_id', ownerId)
          .eq('id', drugId);

      if (!mounted) return;
      setState(() {
        for (final r in _rows) {
          if ((r['id'] ?? '').toString() == drugId) {
            r['is_active'] = newActive;
            r['updated_at'] = DateTime.now().toIso8601String();
            break;
          }
        }
      });

      _toast(newActive ? 'เปิดใช้งานแล้ว' : 'ปิดการใช้งานแล้ว');
    } catch (e) {
      _toast('ทำรายการไม่สำเร็จ: $e', isError: true);
    }
  }

  Future<void> _tryDeleteDrug(Map<String, dynamic> drug) async {
    final drugId = (drug['id'] ?? '').toString();
    final code = (drug['code'] ?? '').toString().trim();
    final name = _drugName(drug);

    if (drugId.isEmpty) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('ลบรายการยา', style: TextStyle(fontWeight: FontWeight.w900)),
        content: Text(
          'ต้องการลบ "$name"${code.isNotEmpty ? ' ($code)' : ''} ใช่ไหม?\n\n'
          'หมายเหตุ: หากเคยมีรายการซื้อเข้า/ขายออก หรือมีล็อตคงเหลือ ระบบจะไม่อนุญาตให้ลบ และจะแนะนำให้ "ปิดการใช้งาน" แทน',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ยกเลิก')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('ลบ'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    try {
      final ownerId = _ownerId();

      final hasIn = await _exists(
        table: 'stock_in_items',
        ownerId: ownerId,
        drugId: drugId,
      );
      final hasOut = await _exists(
        table: 'stock_out_items',
        ownerId: ownerId,
        drugId: drugId,
      );

      final lots = await _sb
          .from('drug_lots')
          .select('qty_on_hand_base')
          .eq('owner_id', ownerId)
          .eq('drug_id', drugId);

      num onHand = 0;
      for (final r in (lots as List)) {
        final q = (r['qty_on_hand_base'] as num?) ?? 0;
        onHand += q;
      }

      if (hasIn || hasOut || onHand > 0) {
        final reasons = <String>[];
        if (onHand > 0) {
          reasons.add('ยังมีสต็อกคงเหลือ (${_fmtQty(onHand)} หน่วยฐาน)');
        }
        if (hasIn) reasons.add('เคยมีรายการ “รับเข้า (Stock In)”');
        if (hasOut) reasons.add('เคยมีรายการ “จ่ายออก/ขาย (Stock Out)”');

        final msg = [
          'ไม่สามารถลบรายการยาได้',
          if (reasons.isNotEmpty) 'เพราะ: ${reasons.join(' • ')}',
          '',
          'ทางออกที่แนะนำ:',
          '• กด “ปิดการใช้งาน” เพื่อซ่อนจากหน้าทำรายการ แต่ยังเก็บประวัติไว้',
          '• หากต้องการลบจริง ต้องลบ/ย้อนรายการที่เกี่ยวข้องทั้งหมดก่อน (ไม่แนะนำสำหรับระบบจริง)',
        ].join('\n');

        _toast(msg, isError: true);

        final wantDisable = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('แนะนำ: ปิดการใช้งานแทน', style: TextStyle(fontWeight: FontWeight.w900)),
            content: Text(msg),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ไม่ทำตอนนี้')),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('ปิดการใช้งาน'),
              ),
            ],
          ),
        );

        if (wantDisable == true) {
          await _setActive(drugId: drugId, newActive: false);
        }
        return;
      }

      await _sb
          .from('drug_dispense_units')
          .delete()
          .eq('owner_id', ownerId)
          .eq('drug_id', drugId);

      await _sb
          .from('drug_lots')
          .delete()
          .eq('owner_id', ownerId)
          .eq('drug_id', drugId);

      await _sb.from('drugs').delete().eq('owner_id', ownerId).eq('id', drugId);

      if (!mounted) return;
      setState(() {
        _rows.removeWhere((r) => (r['id'] ?? '').toString() == drugId);
      });

      _toast('ลบรายการยาแล้ว');
    } catch (e) {
      _toast(
        'ลบไม่สำเร็จ: ยานี้อาจถูกอ้างอิงอยู่ในรายการรับเข้า/จ่ายออก หรือมีข้อมูลที่เชื่อมโยงอยู่\n'
        'แนะนำให้ใช้ “ปิดการใช้งาน” แทน\n\nรายละเอียด: $e',
        isError: true,
      );
    }
  }

  Future<bool> _exists({
    required String table,
    required String ownerId,
    required String drugId,
  }) async {
    try {
      final rows = await _sb
          .from(table)
          .select('id')
          .eq('owner_id', ownerId)
          .eq('drug_id', drugId)
          .limit(1);

      return (rows as List).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  String _drugName(Map<String, dynamic> d) {
    final g = (d['generic_name'] ?? '-').toString().trim();
    final b = (d['brand_name'] ?? '').toString().trim();
    return b.isNotEmpty ? '$g ($b)' : g;
  }

  String _subtitle(Map<String, dynamic> d) {
    final brand = (d['brand_name'] ?? '').toString().trim();
    final dosageForm = (d['dosage_form'] ?? '').toString().trim();
    final strength = (d['strength'] ?? '').toString().trim();
    final base = (d['base_unit'] ?? '').toString().trim();

    final parts = <String>[];
    if (brand.isNotEmpty) parts.add(brand);
    if (dosageForm.isNotEmpty) parts.add(dosageForm);
    if (strength.isNotEmpty) parts.add(strength);
    if (base.isNotEmpty) parts.add(base);

    return parts.join(' • ');
  }

  String _meta(Map<String, dynamic> d) {
    final cat = (d['category'] ?? '').toString().trim();
    final manu = (d['manufacturer'] ?? '').toString().trim();
    final rp = (d['reorder_point'] as num?) ?? 0;

    final parts = <String>[];
    if (cat.isNotEmpty) parts.add('หมวด: $cat');
    if (manu.isNotEmpty) parts.add('ผู้ผลิต: $manu');
    if (rp > 0) parts.add('จุดสั่งซื้อ: ${_fmtQty(rp)}');

    return parts.join('  •  ');
  }

  String _fmtQty(num v) => (v % 1 == 0) ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  void _toast(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.red.shade700 : null,
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: isError ? 5 : 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final list = _filteredRows();
    final totalAll = _countTab(0);
    final totalActive = _countTab(1);
    final totalInactive = _countTab(2);

    return Scaffold(
      appBar: AppBar(
        title: const Text('รายการยาทั้งหมด', style: TextStyle(fontWeight: FontWeight.w900)),
      ),
      backgroundColor: const Color(0xFFF4F7FB),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('เกิดข้อผิดพลาด: $_error'),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(14),
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: Colors.black.withOpacity(0.06)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.03),
                              blurRadius: 10,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.search_rounded, color: Colors.black.withOpacity(0.45)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextField(
                                controller: _searchCtl,
                                decoration: const InputDecoration(
                                  hintText: 'ค้นหา: ชื่อยา / รหัส / Brand / ผู้ผลิต / หมวดหมู่',
                                  border: InputBorder.none,
                                  isDense: true,
                                ),
                              ),
                            ),
                            if (_q.isNotEmpty)
                              IconButton(
                                tooltip: 'ล้าง',
                                onPressed: () {
                                  _searchCtl.clear();
                                  FocusScope.of(context).unfocus();
                                },
                                icon: const Icon(Icons.close_rounded),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          ChoiceChip(
                            label: Text('ทั้งหมด ($totalAll)'),
                            selected: _tab == 0,
                            onSelected: (_) => setState(() => _tab = 0),
                          ),
                          ChoiceChip(
                            label: Text('ใช้งานอยู่ ($totalActive)'),
                            selected: _tab == 1,
                            onSelected: (_) => setState(() => _tab = 1),
                          ),
                          ChoiceChip(
                            label: Text('ปิดการใช้งาน ($totalInactive)'),
                            selected: _tab == 2,
                            onSelected: (_) => setState(() => _tab = 2),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (list.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 40),
                          child: Center(
                            child: Text(
                              'ไม่พบรายการยา',
                              style: TextStyle(
                                color: Colors.black.withOpacity(0.55),
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                      ...List.generate(list.length, (i) {
                        final d = list[i];
                        final id = (d['id'] ?? '').toString();
                        final code = (d['code'] ?? '').toString().trim();

                        final isActive = (d['is_active'] as bool?) ?? true;

                        final name = _drugName(d);
                        final sub = _subtitle(d);
                        final meta = _meta(d);

                        return Container(
                          margin: EdgeInsets.only(bottom: i == list.length - 1 ? 0 : 12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: Colors.black.withOpacity(0.06)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.03),
                                blurRadius: 10,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '$name${code.isNotEmpty ? ' ($code)' : ''}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w900,
                                              fontSize: 16,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            sub,
                                            style: TextStyle(
                                              color: Colors.black.withOpacity(0.60),
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      decoration: BoxDecoration(
                                        color: isActive
                                            ? Colors.green.withOpacity(0.10)
                                            : Colors.orange.withOpacity(0.12),
                                        borderRadius: BorderRadius.circular(999),
                                        border: Border.all(
                                          color: isActive
                                              ? Colors.green.withOpacity(0.25)
                                              : Colors.orange.withOpacity(0.25),
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            isActive ? Icons.check_circle_rounded : Icons.pause_circle_filled_rounded,
                                            size: 18,
                                            color: isActive ? Colors.green : Colors.orange,
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            isActive ? 'ใช้งานอยู่' : 'ปิดการใช้งาน',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w900,
                                              color: isActive ? Colors.green : Colors.orange,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                if (meta.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    meta,
                                    style: TextStyle(
                                      color: Colors.black.withOpacity(0.60),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  children: [
                                    OutlinedButton.icon(
                                      onPressed: () async {
                                        final res = await Navigator.of(context).push<bool?>(
                                          MaterialPageRoute(builder: (_) => AddDrugPage(drugId: id)),
                                        );
                                        if (res == true && mounted) {
                                          await _load();
                                        }
                                      },
                                      icon: const Icon(Icons.edit_rounded),
                                      label: const Text('แก้ไข'),
                                    ),
                                    if (isActive)
                                      FilledButton.icon(
                                        onPressed: () => _setActive(drugId: id, newActive: false),
                                        style: FilledButton.styleFrom(
                                          backgroundColor: cs.primary.withOpacity(0.10),
                                          foregroundColor: cs.primary,
                                        ),
                                        icon: const Icon(Icons.pause_rounded),
                                        label: const Text('ปิดการใช้งาน'),
                                      )
                                    else
                                      FilledButton.icon(
                                        onPressed: () => _setActive(drugId: id, newActive: true),
                                        icon: const Icon(Icons.check_rounded),
                                        label: const Text('เปิดใช้งาน'),
                                      ),
                                    OutlinedButton.icon(
                                      onPressed: () => _tryDeleteDrug(d),
                                      icon: const Icon(Icons.delete_outline_rounded, color: Colors.red),
                                      label: const Text('ลบ', style: TextStyle(color: Colors.red)),
                                      style: OutlinedButton.styleFrom(
                                        side: BorderSide(color: Colors.red.withOpacity(0.45)),
                                      ),
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
  }
}