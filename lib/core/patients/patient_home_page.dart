// lib/pages/patients/patients_page.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PatientsPage extends StatefulWidget {
  const PatientsPage({super.key});

  @override
  State<PatientsPage> createState() => _PatientsPageState();
}

class _PatientsPageState extends State<PatientsPage> {
  final SupabaseClient _sb = Supabase.instance.client;

  bool _loading = true;
  String? _error;

  final TextEditingController _searchCtl = TextEditingController();
  String _q = '';

  // raw
  List<Map<String, dynamic>> _patients = [];
  List<Map<String, dynamic>> _receipts = [];

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

  String _dateOnly(dynamic v) {
    if (v == null) return '-';
    final s = v.toString();
    return s.length >= 10 ? s.substring(0, 10) : s;
  }

  String _s(dynamic v) => (v ?? '').toString().trim();

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final ownerId = _ownerId();

      final patientsRes = await _sb
          .from('patients')
          .select('''
            id, owner_id, full_name, phone, national_id, birth_date,
            chronic_conditions, drug_allergies, note,
            created_at, updated_at
          ''')
          .eq('owner_id', ownerId)
          .order('updated_at', ascending: false);

      final receiptsRes = await _sb
          .from('stock_out_receipts')
          .select('id, owner_id, patient_id, patient_name, note, sold_at, created_at')
          .eq('owner_id', ownerId)
          .not('patient_id', 'is', null)
          .order('sold_at', ascending: false);

      _patients = (patientsRes as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      _receipts = (receiptsRes as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e) {
      _error = '$e';
      _patients = [];
      _receipts = [];
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> _filteredPatients() {
    final q = _q;
    if (q.isEmpty) return _patients;

    bool match(Map<String, dynamic> p) {
      final hay = [
        _s(p['full_name']).toLowerCase(),
        _s(p['phone']).toLowerCase(),
        _s(p['national_id']).toLowerCase(),
      ].join(' | ');
      return hay.contains(q);
    }

    return _patients.where(match).toList();
  }

  /// สรุป: จำนวนครั้งมา / ล่าสุด
  _PatientSummary _summaryOf(String patientId) {
    int count = 0;
    DateTime? last;

    for (final r in _receipts) {
      if ((r['patient_id'] ?? '').toString() != patientId) continue;
      count++;

      final soldAt = r['sold_at'];
      final dt = _parseDateTime(soldAt);
      if (dt != null) {
        if (last == null || dt.isAfter(last!)) last = dt;
      }
    }

    return _PatientSummary(count: count, lastVisit: last);
  }

  DateTime? _parseDateTime(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString());
  }

  Future<void> _openPatient(Map<String, dynamic> p) async {
    final id = (p['id'] ?? '').toString();
    if (id.isEmpty) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PatientHistoryPage(patient: p),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = _filteredPatients();

    return Scaffold(
      appBar: AppBar(
        title: const Text('ผู้ป่วยในระบบ', style: TextStyle(fontWeight: FontWeight.w900)),
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
                      // Search
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
                                  hintText: 'ค้นหา: ชื่อ / เบอร์โทร / เลขบัตร',
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

                      // Stats header
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'ทั้งหมด ${_patients.length} คน',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                color: Colors.black.withOpacity(0.75),
                              ),
                            ),
                          ),
                          Text(
                            'ประวัติขาย ${_receipts.length} รายการ',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              color: Colors.black.withOpacity(0.55),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 12),

                      if (list.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 40),
                          child: Center(
                            child: Text(
                              _q.isEmpty ? 'ยังไม่มีผู้ป่วยในระบบ' : 'ไม่พบผู้ป่วย',
                              style: TextStyle(
                                color: Colors.black.withOpacity(0.55),
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),

                      ...List.generate(list.length, (i) {
                        final p = list[i];
                        final id = (p['id'] ?? '').toString();
                        final name = _s(p['full_name']).isEmpty ? '-' : _s(p['full_name']);
                        final phone = _s(p['phone']);
                        final nid = _s(p['national_id']);
                        final birth = _dateOnly(p['birth_date']);

                        final sum = _summaryOf(id);

                        final lastText =
                            sum.lastVisit == null ? '-' : _dateOnly(sum.lastVisit!.toIso8601String());

                        return InkWell(
                          onTap: () => _openPatient(p),
                          borderRadius: BorderRadius.circular(18),
                          child: Container(
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
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      color: Theme.of(context).colorScheme.primary.withOpacity(0.10),
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: Theme.of(context).colorScheme.primary.withOpacity(0.18),
                                      ),
                                    ),
                                    child: Icon(
                                      Icons.person_rounded,
                                      color: Theme.of(context).colorScheme.primary,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                                        ),
                                        const SizedBox(height: 4),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 6,
                                          children: [
                                            _chip(
                                              context,
                                              icon: Icons.phone_rounded,
                                              text: phone.isEmpty ? 'ไม่มีเบอร์' : phone,
                                            ),
                                            _chip(
                                              context,
                                              icon: Icons.cake_rounded,
                                              text: birth == '-' ? 'ไม่ระบุวันเกิด' : birth,
                                            ),
                                            if (nid.isNotEmpty)
                                              _chip(context, icon: Icons.badge_rounded, text: nid),
                                          ],
                                        ),
                                        const SizedBox(height: 10),
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                'มาซื้อทั้งหมด: ${sum.count} ครั้ง',
                                                style: TextStyle(
                                                  color: Colors.black.withOpacity(0.62),
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                            ),
                                            Text(
                                              'ล่าสุด: $lastText',
                                              style: TextStyle(
                                                color: Colors.black.withOpacity(0.52),
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            Icon(Icons.chevron_right_rounded,
                                                color: Colors.black.withOpacity(0.35)),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
    );
  }

  Widget _chip(BuildContext context, {required IconData icon, required String text}) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.primary.withOpacity(0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: cs.primary),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(fontWeight: FontWeight.w800, color: cs.primary),
          ),
        ],
      ),
    );
  }
}

class _PatientSummary {
  final int count;
  final DateTime? lastVisit;
  const _PatientSummary({required this.count, required this.lastVisit});
}

// =====================================================
// Patient History Page: ประวัติผู้ป่วย + ประวัติการมาซื้อยา
// =====================================================
class PatientHistoryPage extends StatefulWidget {
  final Map<String, dynamic> patient;
  const PatientHistoryPage({super.key, required this.patient});

  @override
  State<PatientHistoryPage> createState() => _PatientHistoryPageState();
}

class _PatientHistoryPageState extends State<PatientHistoryPage> {
  final SupabaseClient _sb = Supabase.instance.client;

  bool _loading = true;
  String? _error;

  List<Map<String, dynamic>> _receipts = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _ownerId() {
    final u = _sb.auth.currentUser;
    if (u == null) throw Exception('ยังไม่ได้ล็อกอิน');
    return u.id;
  }

  String _s(dynamic v) => (v ?? '').toString().trim();

  String _dateOnly(dynamic v) {
    if (v == null) return '-';
    final s = v.toString();
    return s.length >= 10 ? s.substring(0, 10) : s;
  }

  DateTime? _parseDateTime(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final ownerId = _ownerId();
      final pid = (widget.patient['id'] ?? '').toString();

      final res = await _sb
          .from('stock_out_receipts')
          .select('id, owner_id, patient_id, patient_name, note, sold_at, created_at')
          .eq('owner_id', ownerId)
          .eq('patient_id', pid)
          .order('sold_at', ascending: false);

      _receipts = (res as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e) {
      _error = '$e';
      _receipts = [];
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openReceipt(Map<String, dynamic> r) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ReceiptItemsSheet(receipt: r),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.patient;

    final name = _s(p['full_name']).isEmpty ? '-' : _s(p['full_name']);
    final phone = _s(p['phone']);
    final nid = _s(p['national_id']);
    final birth = _dateOnly(p['birth_date']);

    final conditions = (p['chronic_conditions'] as List?)?.map((e) => e.toString()).toList() ?? const [];
    final allergies = (p['drug_allergies'] as List?)?.map((e) => e.toString()).toList() ?? const [];
    final note = _s(p['note']);

    return Scaffold(
      appBar: AppBar(
        title: const Text('ข้อมูลผู้ป่วย', style: TextStyle(fontWeight: FontWeight.w900)),
      ),
      backgroundColor: const Color(0xFFF4F7FB),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(16), child: Text('เกิดข้อผิดพลาด: $_error')))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(14),
                    children: [
                      // Patient card
                      Container(
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
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 46,
                                  height: 46,
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary.withOpacity(0.10),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Icon(Icons.person_rounded, color: Theme.of(context).colorScheme.primary),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(name,
                                          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
                                      const SizedBox(height: 4),
                                      Text(
                                        [
                                          if (phone.isNotEmpty) 'โทร: $phone',
                                          if (birth != '-' && birth.isNotEmpty) 'วันเกิด: $birth',
                                          if (nid.isNotEmpty) 'เลขบัตร: $nid',
                                        ].join('  •  ').isEmpty
                                            ? 'ยังไม่มีข้อมูลติดต่อ'
                                            : [
                                                if (phone.isNotEmpty) 'โทร: $phone',
                                                if (birth != '-' && birth.isNotEmpty) 'วันเกิด: $birth',
                                                if (nid.isNotEmpty) 'เลขบัตร: $nid',
                                              ].join('  •  '),
                                        style: TextStyle(color: Colors.black.withOpacity(0.60), fontWeight: FontWeight.w700),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            if (conditions.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Text('โรคประจำตัว', style: TextStyle(fontWeight: FontWeight.w900, color: Colors.black.withOpacity(0.75))),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: conditions.map((t) => _tag(t)).toList(),
                              ),
                            ],
                            if (allergies.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Text('แพ้ยา', style: TextStyle(fontWeight: FontWeight.w900, color: Colors.black.withOpacity(0.75))),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: allergies.map((t) => _tag(t, danger: true)).toList(),
                              ),
                            ],
                            if (note.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Text('หมายเหตุ', style: TextStyle(fontWeight: FontWeight.w900, color: Colors.black.withOpacity(0.75))),
                              const SizedBox(height: 6),
                              Text(note, style: TextStyle(color: Colors.black.withOpacity(0.65), fontWeight: FontWeight.w700)),
                            ],
                          ],
                        ),
                      ),

                      const SizedBox(height: 12),

                      // History title
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'ประวัติการมาซื้อยา (${_receipts.length})',
                              style: TextStyle(fontWeight: FontWeight.w900, color: Colors.black.withOpacity(0.78)),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 10),

                      if (_receipts.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 30),
                          child: Center(
                            child: Text(
                              'ยังไม่มีประวัติการมาซื้อยา',
                              style: TextStyle(color: Colors.black.withOpacity(0.55), fontWeight: FontWeight.w800),
                            ),
                          ),
                        ),

                      ...List.generate(_receipts.length, (i) {
                        final r = _receipts[i];
                        final soldAt = _parseDateTime(r['sold_at']);
                        final soldText = soldAt == null ? _dateOnly(r['sold_at']) : _dateOnly(soldAt.toIso8601String());
                        final noteR = _s(r['note']);
                        final id = (r['id'] ?? '').toString();

                        return InkWell(
                          onTap: () => _openReceipt(r),
                          borderRadius: BorderRadius.circular(18),
                          child: Container(
                            margin: EdgeInsets.only(bottom: i == _receipts.length - 1 ? 0 : 12),
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
                            padding: const EdgeInsets.all(14),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary.withOpacity(0.10),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.receipt_long_rounded, size: 18, color: Theme.of(context).colorScheme.primary),
                                      const SizedBox(width: 6),
                                      Text(
                                        soldText,
                                        style: TextStyle(fontWeight: FontWeight.w900, color: Theme.of(context).colorScheme.primary),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'ใบขาย: ${id.isEmpty ? '-' : id.substring(0, id.length.clamp(0, 8))}…',
                                        style: const TextStyle(fontWeight: FontWeight.w900),
                                      ),
                                      if (noteR.isNotEmpty) ...[
                                        const SizedBox(height: 4),
                                        Text(
                                          noteR,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(color: Colors.black.withOpacity(0.60), fontWeight: FontWeight.w700),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                Icon(Icons.chevron_right_rounded, color: Colors.black.withOpacity(0.35)),
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

  Widget _tag(String text, {bool danger = false}) {
    final bg = danger ? Colors.red.withOpacity(0.10) : Colors.black.withOpacity(0.06);
    final fg = danger ? Colors.red.shade700 : Colors.black.withOpacity(0.75);
    final bd = danger ? Colors.red.withOpacity(0.25) : Colors.black.withOpacity(0.12);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: bd),
      ),
      child: Text(text, style: TextStyle(fontWeight: FontWeight.w900, color: fg)),
    );
  }
}

// =====================================================
// Bottom sheet: รายการยาในใบขาย (stock_out_items)
// =====================================================
class ReceiptItemsSheet extends StatefulWidget {
  final Map<String, dynamic> receipt;
  const ReceiptItemsSheet({super.key, required this.receipt});

  @override
  State<ReceiptItemsSheet> createState() => _ReceiptItemsSheetState();
}

class _ReceiptItemsSheetState extends State<ReceiptItemsSheet> {
  final SupabaseClient _sb = Supabase.instance.client;

  bool _loading = true;
  String? _error;

  List<Map<String, dynamic>> _items = [];

  String _ownerId() {
    final u = _sb.auth.currentUser;
    if (u == null) throw Exception('ยังไม่ได้ล็อกอิน');
    return u.id;
  }

  String _s(dynamic v) => (v ?? '').toString().trim();

  double _toDouble(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  String _fmtNum(double v) => (v % 1 == 0) ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final ownerId = _ownerId();
      final rid = (widget.receipt['id'] ?? '').toString();
      if (rid.isEmpty) throw Exception('receipt_id ไม่ถูกต้อง');

     final res = await _sb
    .from('stock_out_items')
    .select('''
      id, receipt_id, drug_id, lot_no, exp_date, qty_base, sell_per_base, line_total, created_at,
      drugs(code, generic_name, brand_name, base_unit, strength, dosage_form)
    ''')
    .eq('owner_id', ownerId)
    .eq('receipt_id', rid)
    .order('created_at', ascending: true);

      _items = (res as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e) {
      _error = '$e';
      _items = [];
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final soldAt = widget.receipt['sold_at'];

    double sum = 0;
    for (final it in _items) {
      sum += _toDouble(it['line_total']);
    }

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 14,
          right: 14,
          top: 4,
          bottom: 14 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: _loading
            ? const SizedBox(height: 240, child: Center(child: CircularProgressIndicator()))
            : _error != null
                ? SizedBox(
                    height: 240,
                    child: Center(child: Text('เกิดข้อผิดพลาด: $_error')),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'รายการยาในใบขาย',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 16,
                                color: Colors.black.withOpacity(0.80),
                              ),
                            ),
                          ),
                          Text(
                            soldAt == null ? '-' : soldAt.toString().substring(0, soldAt.toString().length.clamp(0, 10)),
                            style: TextStyle(fontWeight: FontWeight.w800, color: Colors.black.withOpacity(0.55)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (_items.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 20),
                          child: Text(
                            'ไม่มีรายการยา',
                            style: TextStyle(color: Colors.black.withOpacity(0.55), fontWeight: FontWeight.w800),
                          ),
                        )
                      else
                        Flexible(
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: _items.length,
                            separatorBuilder: (_, __) => const Divider(height: 12),
                            itemBuilder: (_, i) {
                              final it = _items[i];
                              final drug = (it['drugs'] as Map?) ?? {};

                              final g = _s(drug['generic_name']).isEmpty ? '-' : _s(drug['generic_name']);
                              final code = _s(drug['code']);
                              final brand = _s(drug['brand_name']);
                              final unit = _s(drug['base_unit']);
                              final strength = _s(drug['strength']);
                              final form = _s(drug['dosage_form']).isNotEmpty
                                  ? _s(drug['dosage_form'])
                                  : _s(drug['form']);

                              final lot = _s(it['lot_no']);
                              final exp = _s(it['exp_date']).isEmpty ? '-' : it['exp_date'].toString().substring(0, 10);

                              final qtyBase = _toDouble(it['qty_base']);
                              final sell = _toDouble(it['sell_per_base']);
                              final line = _toDouble(it['line_total']);

                              final title = '$g${code.isEmpty ? '' : ' ($code)'}';
                              final sub = [
                                if (brand.isNotEmpty) brand,
                                if (form.isNotEmpty) form,
                                if (strength.isNotEmpty) strength,
                                if (unit.isNotEmpty) unit,
                              ].join(' • ');

                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
                                        const SizedBox(height: 4),
                                        Text(sub.isEmpty ? '-' : sub,
                                            style: TextStyle(color: Colors.black.withOpacity(0.60), fontWeight: FontWeight.w700)),
                                        const SizedBox(height: 6),
                                        Text(
                                          'ล็อต: ${lot.isEmpty ? '-' : lot} • หมดอายุ: $exp',
                                          style: TextStyle(color: Colors.black.withOpacity(0.55), fontWeight: FontWeight.w700),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(
                                        '${_fmtNum(qtyBase)} ${unit.isEmpty ? 'หน่วยฐาน' : unit}',
                                        style: TextStyle(fontWeight: FontWeight.w900, color: Theme.of(context).colorScheme.primary),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'x ${_fmtNum(sell)} = ${_fmtNum(line)}',
                                        style: TextStyle(color: Colors.black.withOpacity(0.60), fontWeight: FontWeight.w800),
                                      ),
                                    ],
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'รวมทั้งหมด',
                              style: TextStyle(fontWeight: FontWeight.w900, color: Colors.black.withOpacity(0.75)),
                            ),
                          ),
                          Text(
                            _fmtNum(sum),
                            style: TextStyle(fontWeight: FontWeight.w900, color: Theme.of(context).colorScheme.primary),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('ปิด'),
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }
}