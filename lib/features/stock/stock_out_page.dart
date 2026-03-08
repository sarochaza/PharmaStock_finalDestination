// lib/pages/stock/stock_out_page.dart
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase_guard.dart';

// ✅ patients
import '../../core/patients/patient_repository.dart';
import '../../core/patients/patient_model.dart';
import '../../core/patients/patient_picker.dart';
import '../../core/patients/add_edit_patient_page.dart';
import '../../core/patients/patient_detail_page.dart';

// ✅ NEW: ประวัติการจ่าย/สั่งซื้อของคนไข้
import '../../core/patients/patient_orders_history_page.dart';

class StockOutPage extends StatefulWidget {
  const StockOutPage({super.key});

  @override
  State<StockOutPage> createState() => _StockOutPageState();
}

class _StockOutPageState extends State<StockOutPage> {
  late final SupabaseClient _client;

  bool _loading = true;
  bool _saving = false;

  List<_DrugOption> _drugs = [];
  _DrugOption? _selectedDrug;

  List<_UnitOption> _units = [];
  _UnitOption? _selectedUnit;

  num _availableBase = 0;

  // ✅ example_text from drugs
  String? _drugExampleText;

  // Search
  final TextEditingController _searchCtl = TextEditingController();
  String _q = '';

  final TextEditingController _qtyCtrl = TextEditingController();
  final TextEditingController _priceCtrl = TextEditingController(text: '0.00');
  final TextEditingController _patientCtrl = TextEditingController();
  final TextEditingController _noteCtrl = TextEditingController();

  final List<_CartLine> _cart = [];

  // ✅ Auto-price (FEFO-aware)
  bool _autoPrice = true;
  num? _suggestedSellPerBase;
  List<_LotPricePreview> _pricePreview = [];

  // ===============================
  // ✅ Patients state
  // ===============================
  PatientRepository? _patientRepo;
  bool _loadingPatients = false;
  List<Patient> _patients = [];
  Patient? _selectedPatient;

  @override
  void initState() {
    super.initState();

    final c = getSupabaseClientOrNull();
    if (c == null) {
      _loading = false;
      return;
    }
    _client = c;
    _patientRepo = PatientRepository(_client);

    _searchCtl.addListener(() {
      setState(() => _q = _searchCtl.text.trim().toLowerCase());
    });

    // ✅ เมื่อพิมพ์จำนวน -> recalculation FEFO price preview + auto price
    _qtyCtrl.addListener(() {
      _recalcSuggestedPrice();
    });

    _bootstrap();
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    _qtyCtrl.dispose();
    _priceCtrl.dispose();
    _patientCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  String _ownerId() {
    final user = _client.auth.currentUser;
    if (user == null) throw Exception('ยังไม่ได้ล็อกอิน');
    return user.id;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  num _parseNum(String s) => num.tryParse(s.trim()) ?? 0;
  String _fmtNum(num v) => (v % 1 == 0) ? v.toInt().toString() : v.toStringAsFixed(2);
  num _cartTotal() => _cart.fold<num>(0, (p, e) => p + e.lineTotal);

  Future<void> _bootstrap() async {
    setState(() => _loading = true);
    try {
      await _loadDrugs();
      await _loadPatients();
    } catch (e) {
      _toast('โหลดข้อมูลไม่สำเร็จ: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ===============================
  // ✅ Patients loader
  // ===============================
  Future<void> _loadPatients() async {
    if (_patientRepo == null) return;
    setState(() => _loadingPatients = true);
    try {
      final list = await _patientRepo!.listPatients();
      if (!mounted) return;
      setState(() => _patients = list);
    } catch (_) {
      // ไม่บังคับ toast
    } finally {
      if (mounted) setState(() => _loadingPatients = false);
    }
  }

  // ===============================
  // ✅ Load drug example_text
  // ===============================
  Future<void> _loadDrugExampleText(String drugId) async {
    try {
      final ownerId = _ownerId();
      final row = await _client
          .from('drugs')
          .select('example_text')
          .eq('owner_id', ownerId)
          .eq('id', drugId)
          .maybeSingle();

      if (!mounted) return;
      final t = (row?['example_text'] ?? '').toString().trim();
      setState(() => _drugExampleText = t.isEmpty ? null : t);
    } catch (_) {
      if (!mounted) return;
      setState(() => _drugExampleText = null);
    }
  }

  // ===============================
  // ✅ Load drugs (include category)
  // ===============================
  Future<void> _loadDrugs() async {
    final ownerId = _ownerId();

    final rows = await _client
    .from('drugs')
    .select('id, generic_name, code, base_unit, category')
    .eq('owner_id', ownerId)
    .eq('is_active', true)   // ✅ เพิ่มบรรทัดนี้
    .order('generic_name', ascending: true);

    final list = (rows as List)
        .map((r) => _DrugOption(
              id: (r['id'] ?? '').toString(),
              name: (r['generic_name'] ?? '').toString(),
              code: (r['code'] ?? '').toString(),
              baseUnit: (r['base_unit'] ?? '').toString(),
              category: (r['category'] ?? '').toString().trim().isEmpty ? null : r['category'].toString(),
            ))
        .where((d) => d.id.isNotEmpty && d.name.trim().isNotEmpty)
        .toList();

    setState(() {
      _drugs = list;
      _selectedDrug = list.isNotEmpty ? list.first : null;
    });

    if (_selectedDrug != null) {
      await _onSelectDrug(_selectedDrug!);
    }
  }

  List<_DrugOption> get _filteredDrugs {
    if (_q.isEmpty) return _drugs;
    return _drugs.where((d) {
      final n = d.name.toLowerCase();
      final c = d.code.toLowerCase();
      return n.contains(_q) || c.contains(_q);
    }).toList();
  }

  Future<void> _onSelectDrug(_DrugOption drug) async {
    setState(() {
      _selectedDrug = drug;
      _units = [];
      _selectedUnit = null;
      _availableBase = 0;
      _qtyCtrl.text = '';

      _suggestedSellPerBase = null;
      _pricePreview = [];

      _drugExampleText = null;
    });

    await Future.wait([
      _loadUnitsForDrug(drugId: drug.id, baseUnit: drug.baseUnit),
      _loadAvailableBase(drug.id),
      _loadDrugExampleText(drug.id),
    ]);

    if (!mounted) return;

    setState(() {
      _selectedUnit = _units.isNotEmpty ? _units.first : null;
    });

    await _recalcSuggestedPrice();
  }

  Future<void> _loadUnitsForDrug({
    required String drugId,
    required String baseUnit,
  }) async {
    final ownerId = _ownerId();

    final base = _UnitOption(
      label: baseUnit.isEmpty ? 'หน่วยฐาน' : baseUnit,
      toBase: 1,
      isDefault: true,
    );

    List<_UnitOption> extra = [];
    try {
      final rows = await _client
          .from('drug_dispense_units')
          .select('unit_name, to_base, is_default, is_active')
          .eq('owner_id', ownerId)
          .eq('drug_id', drugId)
          .or('is_active.is.null,is_active.eq.true')
          .order('is_default', ascending: false)
          .order('to_base', ascending: true);

      extra = (rows as List)
          .map((r) => _UnitOption(
                label: (r['unit_name'] ?? '').toString(),
                toBase: (r['to_base'] is num) ? (r['to_base'] as num) : 1,
                isDefault: r['is_default'] == true,
              ))
          .where((u) => u.label.trim().isNotEmpty)
          .toList();
    } catch (_) {
      extra = [];
    }

    final seen = <String>{};
    final merged = <_UnitOption>[];
    for (final u in [base, ...extra]) {
      final k = u.label.trim().toLowerCase();
      if (seen.add(k)) merged.add(u);
    }

    merged.sort((a, b) {
      if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
      return a.toBase.compareTo(b.toBase);
    });

    if (!mounted) return;
    setState(() => _units = merged);
  }

  // ✅ คงเหลือฐาน อ่านจาก qty_on_hand_base เท่านั้น
  Future<void> _loadAvailableBase(String drugId) async {
    final ownerId = _ownerId();

    final rows = await _client
        .from('drug_lots')
        .select('qty_on_hand_base')
        .eq('owner_id', ownerId)
        .eq('drug_id', drugId);

    num sum = 0;
    for (final r in (rows as List)) {
      final base = r['qty_on_hand_base'];
      if (base is num) sum += base;
    }

    if (!mounted) return;
    setState(() => _availableBase = sum);
  }

  void _addToCart() {
    final drug = _selectedDrug;
    final unit = _selectedUnit;
    if (drug == null || unit == null) return _toast('กรุณาเลือกยาและหน่วย');

    final qtyInUnit = _parseNum(_qtyCtrl.text);
    if (qtyInUnit <= 0) return _toast('กรุณาใส่จำนวนที่จ่าย');

    final sellPerBase = _parseNum(_priceCtrl.text);
    if (sellPerBase < 0) return _toast('ราคาต่อหน่วยฐานไม่ถูกต้อง');

    final qtyBase = qtyInUnit * unit.toBase;
    if (qtyBase <= 0) return _toast('จำนวนที่จ่ายไม่ถูกต้อง');

    final alreadyBase =
        _cart.where((x) => x.drugId == drug.id).fold<num>(0, (p, e) => p + e.qtyBase);

    if (alreadyBase + qtyBase > _availableBase) {
      return _toast('สต็อกไม่พอ (คงเหลือฐาน: ${_fmtNum(_availableBase)})');
    }

    setState(() {
      _cart.add(_CartLine(
        drugId: drug.id,
        drugName: drug.name,
        displayQty: qtyInUnit,
        displayUnit: unit.label,
        qtyBase: qtyBase,
        sellPerBase: sellPerBase,
      ));
      _qtyCtrl.text = '';
    });
  }

  // ✅ FEFO allocation: ตัดจาก qty_on_hand_base
  Future<List<_LotAllocation>> _allocateLotsFEFO({
    required String ownerId,
    required String drugId,
    required num needBase,
  }) async {
    final rows = await _client
        .from('drug_lots')
        .select('id, lot_no, exp_date, qty_on_hand_base')
        .eq('owner_id', ownerId)
        .eq('drug_id', drugId)
        .order('exp_date', ascending: true);

    num remaining = needBase;
    final allocations = <_LotAllocation>[];

    for (final r in (rows as List)) {
      if (remaining <= 0) break;

      final lotId = (r['id'] ?? '').toString();
      final lotNo = (r['lot_no'] ?? '').toString();
      final expDate = (r['exp_date'] ?? '').toString();

      final onHandBase = (r['qty_on_hand_base'] as num?) ?? 0;
      if (lotId.isEmpty || onHandBase <= 0) continue;

      final take = math.min(onHandBase, remaining);
      remaining -= take;

      final newBase = onHandBase - take;

      allocations.add(_LotAllocation(
        lotId: lotId,
        lotNo: lotNo,
        expDate: expDate,
        qtyBase: take,
        newQtyOnHandBase: newBase,
      ));
    }

    return allocations;
  }

  // ===============================
  // ✅ PRICE: FEFO LOT-BASED + fallback latest-drug price
  // ===============================

  Future<num?> _loadLatestSellPerBaseForDrug(String drugId) async {
    final ownerId = _ownerId();

    final rows = await _client
        .from('stock_in_items')
        .select('sell_per_base, created_at')
        .eq('owner_id', ownerId)
        .eq('drug_id', drugId)
        .not('sell_per_base', 'is', null)
        .order('created_at', ascending: false)
        .limit(1);

    if (rows is List && rows.isNotEmpty) {
      final v = rows.first['sell_per_base'];
      if (v is num) return v;
    }
    return null;
  }

  Future<Map<String, num>> _loadLatestSellPerBaseByLot({
    required String ownerId,
    required String drugId,
  }) async {
    final rows = await _client
        .from('stock_in_items')
        .select('lot_no, exp_date, sell_per_base, created_at')
        .eq('owner_id', ownerId)
        .eq('drug_id', drugId)
        .not('sell_per_base', 'is', null)
        .order('created_at', ascending: false);

    final map = <String, num>{}; // key = "lotNo|expDate"
    if (rows is List) {
      for (final r in rows) {
        final lotNo = (r['lot_no'] ?? '').toString();
        final expDate = (r['exp_date'] ?? '').toString();
        final sell = r['sell_per_base'];
        if (lotNo.isEmpty || expDate.isEmpty) continue;
        if (sell is! num) continue;

        final key = '$lotNo|$expDate';
        map.putIfAbsent(key, () => sell);
      }
    }
    return map;
  }

  Future<void> _recalcSuggestedPrice() async {
    final drug = _selectedDrug;
    final unit = _selectedUnit;
    if (drug == null || unit == null) return;

    final qtyInUnit = _parseNum(_qtyCtrl.text);
    if (qtyInUnit <= 0) {
      if (!mounted) return;
      setState(() {
        _suggestedSellPerBase = null;
        _pricePreview = [];
        if (_autoPrice) _priceCtrl.text = '0.00';
      });
      return;
    }

    final needBase = qtyInUnit * unit.toBase;
    if (needBase <= 0) return;

    final ownerId = _ownerId();

    final allocations = await _allocateLotsFEFO(
      ownerId: ownerId,
      drugId: drug.id,
      needBase: needBase,
    );

    if (allocations.isEmpty) {
      if (!mounted) return;
      setState(() {
        _suggestedSellPerBase = null;
        _pricePreview = [];
        if (_autoPrice) _priceCtrl.text = '0.00';
      });
      return;
    }

    final lotPriceMap = await _loadLatestSellPerBaseByLot(ownerId: ownerId, drugId: drug.id);
    final fallbackDrugPrice = await _loadLatestSellPerBaseForDrug(drug.id);

    num sumQty = 0;
    num sumValue = 0;

    final preview = <_LotPricePreview>[];

    for (final a in allocations) {
      final key = '${a.lotNo}|${a.expDate}';
      final lotPrice = lotPriceMap[key];
      final usedPrice = lotPrice ?? fallbackDrugPrice;

      preview.add(_LotPricePreview(
        lotNo: a.lotNo,
        expDate: a.expDate,
        qtyBase: a.qtyBase,
        lotSellPerBase: lotPrice,
        usedSellPerBase: usedPrice,
      ));

      if (usedPrice != null) {
        sumQty += a.qtyBase;
        sumValue += a.qtyBase * usedPrice;
      }
    }

    final suggested = (sumQty > 0) ? (sumValue / sumQty) : null;

    if (!mounted) return;
    setState(() {
      _pricePreview = preview;
      _suggestedSellPerBase = suggested;

      if (_autoPrice && suggested != null) {
        _priceCtrl.text = suggested.toStringAsFixed(2);
      } else if (_autoPrice && suggested == null) {
        _priceCtrl.text = '0.00';
      }
    });
  }

  // ===============================
  // SAVE
  // ===============================

  Future<void> _saveAll() async {
    if (_cart.isEmpty) {
      _toast('ยังไม่มีรายการในตะกร้า');
      return;
    }
    if (_saving) {
      _toast('กำลังบันทึกอยู่...');
      return;
    }

    setState(() => _saving = true);

    try {
      final ownerId = _ownerId();
      final nowIso = DateTime.now().toIso8601String();

      final receipt = await _client
          .from('stock_out_receipts')
          .insert({
            'owner_id': ownerId,
            'patient_id': _selectedPatient?.id,
            'patient_name': _patientCtrl.text.trim().isEmpty
                ? (_selectedPatient?.fullName)
                : _patientCtrl.text.trim(),
            'note': _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
            'sold_at': nowIso,
          })
          .select('id')
          .single()
          .timeout(const Duration(seconds: 15));

      final receiptId = (receipt['id'] ?? '').toString();

      for (final line in _cart) {
        final allocations = await _allocateLotsFEFO(
          ownerId: ownerId,
          drugId: line.drugId,
          needBase: line.qtyBase,
        ).timeout(const Duration(seconds: 15));

        final allocatedSum = allocations.fold<num>(0, (p, a) => p + a.qtyBase);
        if (allocatedSum < line.qtyBase) {
          throw Exception(
            'สต็อกไม่พอสำหรับ ${line.drugName} (ต้องการ ${line.qtyBase} ฐาน แต่มี $allocatedSum ฐาน)',
          );
        }

        for (final a in allocations) {
          final lineTotal = a.qtyBase * line.sellPerBase;

          await _client
              .from('stock_out_items')
              .insert({
                'owner_id': ownerId,
                'receipt_id': receiptId,
                'drug_id': line.drugId,
                'lot_no': a.lotNo,
                'exp_date': a.expDate,
                'qty_base': a.qtyBase,
                'sell_per_base': line.sellPerBase,
                'line_total': lineTotal,
              })
              .timeout(const Duration(seconds: 15));

          final updated = await _client
              .from('drug_lots')
              .update({
                'qty_on_hand_base': a.newQtyOnHandBase,
                'qty_on_hand': a.newQtyOnHandBase,
              })
              .eq('id', a.lotId)
              .eq('owner_id', ownerId)
              .select('id')
              .maybeSingle()
              .timeout(const Duration(seconds: 15));

          if (updated == null) {
            throw Exception('อัปเดตสต็อกล็อตไม่สำเร็จ (RLS/เงื่อนไข update ไม่ตรง) lotId=${a.lotId}');
          }
        }
      }

      final verify = await _client
          .from('stock_out_receipts')
          .select('id')
          .eq('owner_id', ownerId)
          .eq('id', receiptId)
          .maybeSingle()
          .timeout(const Duration(seconds: 15));

      if (!mounted) return;

      if (verify == null) {
        _toast('บันทึกสำเร็จ แต่ระบบอ่านข้อมูลไม่ได้ (RLS SELECT อาจบล็อก) ❗');
        Navigator.pop(context, true);
        return;
      }

      _toast('บันทึกการจ่ายสำเร็จ ✅');
      Navigator.pop(context, true);
    } on TimeoutException {
      if (!mounted) return;
      _toast('บันทึกช้า/ค้างเกินเวลา ลองใหม่อีกครั้ง');
    } catch (e) {
      if (!mounted) return;
      _toast('บันทึกไม่สำเร็จ: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ===============================
  // UI
  // ===============================

  @override
  Widget build(BuildContext context) {
    final total = _cartTotal();

    return Scaffold(
      backgroundColor: const Color(0xFFF4F7FB),
      appBar: AppBar(
        title: const Text('จ่ายยาออก'),
        centerTitle: true,
        backgroundColor: const Color(0xFF1976D2),
        foregroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        actions: [
          IconButton(
            tooltip: 'ประวัติการทำรายการ',
            icon: const Icon(Icons.history_rounded),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PatientOrdersHistoryPage(
                    initialPatient: _selectedPatient,
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_drugs.isEmpty)
              ? Center(
                  child: Text(
                    'ยังไม่มียาในระบบ (หรือ RLS บล็อก SELECT)\nไปเพิ่มยาในหน้า Add ก่อน',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade700),
                  ),
                )
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 980),
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _buildHeaderCard(),
                        const SizedBox(height: 12),
                        _buildCartCard(total),
                        const SizedBox(height: 12),
                        _buildPatientCard(),
                        const SizedBox(height: 16),
                        _buildSaveButton(),
                      ],
                    ),
                  ),
                ),
    );
  }

  Widget _buildHeaderCard() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text(
            'ทำบิลจ่ายยา (หลายชนิด)',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            'เลือกยา → ใส่จำนวน → เลือกหน่วยจ่าย → เพิ่มรายการ แล้วค่อยบันทึกทีเดียว (ตัดสต็อกแบบ FEFO)',
            style: TextStyle(color: Colors.grey.shade700),
          ),
          const SizedBox(height: 14),

          TextField(
            controller: _searchCtl,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _q.isEmpty
                  ? null
                  : IconButton(
                      onPressed: () => _searchCtl.clear(),
                      icon: const Icon(Icons.clear_rounded),
                    ),
              hintText: 'ค้นหายา (ชื่อ / รหัส)',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              filled: true,
              fillColor: Colors.white,
            ),
          ),
          const SizedBox(height: 12),

          _buildDrugDropdown(),

          // ✅ กล่อง "หมวดหมู่" ใต้ dropdown
          if ((_selectedDrug?.category ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.amber.shade200),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lightbulb_outline, color: Colors.amber.shade700),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'หมวดหมู่: ${_selectedDrug!.category!.trim()}',
                      style: TextStyle(color: Colors.amber.shade900, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // ✅ example_text
          if (_drugExampleText != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.amber.shade200),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lightbulb_outline, color: Colors.amber.shade700),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _drugExampleText!,
                      style: TextStyle(color: Colors.amber.shade900, height: 1.4),
                    ),
                  ),
                  IconButton(
                    tooltip: 'ใส่ลงหมายเหตุบิล',
                    onPressed: () {
                      final t = _drugExampleText!.trim();
                      if (t.isEmpty) return;
                      final cur = _noteCtrl.text.trim();
                      _noteCtrl.text = cur.isEmpty ? t : '$cur\n$t';
                      _toast('เพิ่มลงหมายเหตุแล้ว');
                    },
                    icon: const Icon(Icons.note_add_outlined),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _buildQtyField()),
              const SizedBox(width: 12),
              Expanded(child: _buildUnitDropdown()),
            ],
          ),
          const SizedBox(height: 12),

          Row(
            children: [
              Expanded(child: _buildPriceField()),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Auto ราคา', style: TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(width: 8),
                      Switch(
                        value: _autoPrice,
                        onChanged: (v) async {
                          setState(() => _autoPrice = v);
                          if (_autoPrice) await _recalcSuggestedPrice();
                        },
                      ),
                    ],
                  ),
                  if (_suggestedSellPerBase != null)
                    Text(
                      'แนะนำ: ${_suggestedSellPerBase!.toStringAsFixed(2)}',
                      style: TextStyle(color: Colors.grey.shade700),
                    ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 10),
          _buildAddButton(),
          const SizedBox(height: 8),
          _buildStockHint(),

          if (_pricePreview.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'FEFO Preview (ล็อตที่จะถูกตัด) + ราคา:',
              style: TextStyle(color: Colors.grey.shade700, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            ..._pricePreview.map((p) {
              final lotPriceText = (p.lotSellPerBase == null)
                  ? 'ไม่มีราคาล็อต → fallback ${p.usedSellPerBase?.toStringAsFixed(2) ?? '-'}'
                  : 'ราคาล็อต ${p.lotSellPerBase!.toStringAsFixed(2)}';

              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '• Lot ${p.lotNo} / EXP ${p.expDate} : ตัด ${_fmtNum(p.qtyBase)} ฐาน • $lotPriceText',
                  style: TextStyle(color: Colors.grey.shade700),
                ),
              );
            }),
          ],
        ]),
      ),
    );
  }

  // ✅ กัน overflow ตอน dropdown แสดงค่าที่เลือก
  Widget _buildDrugDropdown() {
    final list = _filteredDrugs;

    if (_selectedDrug != null && list.isNotEmpty) {
      final stillExists = list.any((x) => x.id == _selectedDrug!.id);
      if (!stillExists) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted) return;
          await _onSelectDrug(list.first);
        });
      }
    }

    Widget itemTile(_DrugOption d) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            d.code.isEmpty ? d.name : '${d.name} (${d.code})',
            style: const TextStyle(fontWeight: FontWeight.w800),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if ((d.category ?? '').trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'หมวดหมู่: ${d.category!.trim()}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      );
    }

    final current = (list.isNotEmpty)
        ? (list.firstWhere(
            (x) => _selectedDrug != null && x.id == _selectedDrug!.id,
            orElse: () => list.first,
          ))
        : null;

    return InputDecorator(
      decoration: InputDecoration(
        labelText: 'เลือกยา',
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<_DrugOption>(
          isExpanded: true,
          value: current,
          selectedItemBuilder: (context) {
            return list.map((d) {
              return Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  d.code.isEmpty ? d.name : '${d.name} (${d.code})',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              );
            }).toList();
          },
          items: list.map((d) {
            return DropdownMenuItem<_DrugOption>(
              value: d,
              child: itemTile(d),
            );
          }).toList(),
          onChanged: (v) async {
            if (v == null) return;
            await _onSelectDrug(v);
          },
        ),
      ),
    );
  }

  Widget _buildUnitDropdown() {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: 'หน่วยที่จ่าย',
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        filled: true,
        fillColor: Colors.white,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<_UnitOption>(
          isExpanded: true,
          value: _selectedUnit,
          items: _units
              .map((u) => DropdownMenuItem(
                    value: u,
                    child: Text('${u.label} (1 = ${_fmtNum(u.toBase)} ฐาน)'),
                  ))
              .toList(),
          onChanged: (v) async {
            setState(() => _selectedUnit = v);
            await _recalcSuggestedPrice();
          },
        ),
      ),
    );
  }

  Widget _buildQtyField() {
    return TextField(
      controller: _qtyCtrl,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: 'จำนวนที่จ่าย (ตามหน่วยที่เลือก)',
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        filled: true,
        fillColor: Colors.white,
      ),
    );
  }

  Widget _buildPriceField() {
    return TextField(
      controller: _priceCtrl,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: 'ราคาขายต่อหน่วยฐาน (บาท/หน่วยฐาน)',
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        filled: true,
        fillColor: Colors.white,
      ),
    );
  }

  Widget _buildAddButton() {
    return SizedBox(
      height: 52,
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _addToCart,
        icon: const Icon(Icons.add),
        label: const Text(
          'เพิ่มรายการ',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        style: ElevatedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
    );
  }

  Widget _buildStockHint() {
    return Row(
      children: [
        Icon(Icons.inventory_2_outlined, size: 18, color: Colors.grey.shade700),
        const SizedBox(width: 6),
        Text(
          'คงเหลือ (หน่วยฐาน): ${_fmtNum(_availableBase)}',
          style: TextStyle(color: Colors.grey.shade700),
        ),
      ],
    );
  }

  Widget _buildCartCard(num total) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Row(children: [
            _pill('ตะกร้า: ${_cart.length} รายการ'),
            const SizedBox(width: 8),
            _pill('รวม: ${total.toStringAsFixed(2)} ฿', strong: true),
            const Spacer(),
            TextButton(
              onPressed: _cart.isEmpty ? null : () => setState(() => _cart.clear()),
              child: const Text('ล้างตะกร้า'),
            ),
          ]),
          const SizedBox(height: 10),
          if (_cart.isEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Text('ยังไม่มีรายการในตะกร้า', style: TextStyle(color: Colors.grey.shade700)),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _cart.length,
              separatorBuilder: (_, __) => const Divider(height: 18),
              itemBuilder: (_, i) {
                final c = _cart[i];
                return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(c.drugName, style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      Text(
                        '${_fmtNum(c.displayQty)} ${c.displayUnit} (= ${_fmtNum(c.qtyBase)} ฐาน)',
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${c.sellPerBase.toStringAsFixed(2)} / ฐาน • รวม ${c.lineTotal.toStringAsFixed(2)} ฿',
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                    ]),
                  ),
                  IconButton(
                    onPressed: () => setState(() => _cart.removeAt(i)),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ]);
              },
            ),
        ]),
      ),
    );
  }

  // ===============================
  // ✅ Patient Card
  // ===============================
  Widget _buildPatientCard() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('ข้อมูลผู้ป่วย', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
          const SizedBox(height: 10),

          if (_loadingPatients)
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: LinearProgressIndicator(minHeight: 3),
            ),

          PatientPicker(
            patients: _patients,
            value: _selectedPatient,
            onChanged: (p) {
              setState(() {
                _selectedPatient = p;
                _patientCtrl.text = p?.fullName ?? '';
              });
            },
          ),

          const SizedBox(height: 10),

          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _patientCtrl,
                  decoration: InputDecoration(
                    labelText: 'ชื่อผู้รับยา / ผู้ป่วย (แก้เองได้)',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                    filled: true,
                    fillColor: Colors.white,
                    prefixIcon: const Icon(Icons.person_rounded),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 54,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final saved = await Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const AddEditPatientPage()),
                    );
                    if (saved != null) {
                      await _loadPatients();
                      if (!mounted) return;
                      if (saved is Patient) {
                        setState(() {
                          _selectedPatient = saved;
                          _patientCtrl.text = saved.fullName;
                        });
                      }
                    }
                  },
                  icon: const Icon(Icons.person_add_alt_rounded),
                  label: const Text('เพิ่ม'),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          TextField(
            controller: _noteCtrl,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: 'หมายเหตุ / อาการป่วย (ใช้ร่วมทั้งบิล)',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              filled: true,
              fillColor: Colors.white,
              prefixIcon: const Icon(Icons.note_alt_rounded),
            ),
          ),

          if (_selectedPatient != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.04),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _selectedPatient!.fullName,
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'อายุ: ${_selectedPatient!.age ?? '-'} • กรุ๊ปเลือด: ${_selectedPatient!.bloodGroup ?? '-'}',
                        ),
                        if (_selectedPatient!.drugAllergies.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            'แพ้ยา: ${_selectedPatient!.drugAllergies.join(', ')}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ],
                        if (_selectedPatient!.chronicConditions.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            'โรคประจำตัว: ${_selectedPatient!.chronicConditions.join(', ')}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  height: 54,
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => PatientDetailPage(patientId: _selectedPatient!.id),
                        ),
                      );
                    },
                    icon: const Icon(Icons.history_rounded),
                    label: const Text('ประวัติ'),
                  ),
                ),
              ],
            ),
          ],
        ]),
      ),
    );
  }

  Widget _buildSaveButton() {
    return SizedBox(
      height: 56,
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: (_saving || _cart.isEmpty) ? null : _saveAll,
        icon: _saving
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.check_circle_outline),
        label: Text(
          _saving ? 'กำลังบันทึก...' : 'บันทึกการจ่าย (ทั้งหมด)',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFEF4444),
          disabledBackgroundColor: Colors.grey.shade400,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
    );
  }

  Widget _pill(String text, {bool strong = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: strong ? const Color(0xFFE6F7EC) : const Color(0xFFEAF2FF),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
          color: strong ? const Color(0xFF0F7A3B) : const Color(0xFF2158B6),
        ),
      ),
    );
  }
}

// ===============================
// Models
// ===============================

class _DrugOption {
  final String id;
  final String name;
  final String code;
  final String baseUnit;
  final String? category;

  _DrugOption({
    required this.id,
    required this.name,
    required this.code,
    required this.baseUnit,
    this.category,
  });
}

class _UnitOption {
  final String label;
  final num toBase;
  final bool isDefault;

  _UnitOption({required this.label, required this.toBase, required this.isDefault});
}

class _CartLine {
  final String drugId;
  final String drugName;
  final num displayQty;
  final String displayUnit;
  final num qtyBase;
  final num sellPerBase;

  _CartLine({
    required this.drugId,
    required this.drugName,
    required this.displayQty,
    required this.displayUnit,
    required this.qtyBase,
    required this.sellPerBase,
  });

  num get lineTotal => qtyBase * sellPerBase;
}

class _LotAllocation {
  final String lotId;
  final String lotNo;
  final String expDate;
  final num qtyBase;
  final num newQtyOnHandBase;

  _LotAllocation({
    required this.lotId,
    required this.lotNo,
    required this.expDate,
    required this.qtyBase,
    required this.newQtyOnHandBase,
  });
}

// ✅ FEFO price preview row
class _LotPricePreview {
  final String lotNo;
  final String expDate;
  final num qtyBase;

  final num? lotSellPerBase;
  final num? usedSellPerBase;

  _LotPricePreview({
    required this.lotNo,
    required this.expDate,
    required this.qtyBase,
    required this.lotSellPerBase,
    required this.usedSellPerBase,
  });
}