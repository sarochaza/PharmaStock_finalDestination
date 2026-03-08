// lib/stock/stock_in_page.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../drugs/repository/drugs_repository.dart';

class StockInPage extends StatefulWidget {
  const StockInPage({super.key});

  @override
  State<StockInPage> createState() => _StockInPageState();
}

class _StockInPageState extends State<StockInPage> {
  final _headerKey = GlobalKey<FormState>();
  final _itemKey = GlobalKey<FormState>();

  late final SupabaseClient sb = Supabase.instance.client;
  late final DrugsRepository repo = DrugsRepository(sb);

  // ===== data =====
  List<Map<String, dynamic>> drugs = [];
  String? selectedDrugId;
  bool loading = true;
  bool saving = false;

  // ✅ drug search
  final TextEditingController _drugSearchCtl = TextEditingController();
  String _drugQuery = '';

  // ===== suppliers (new) =====
  String? _selectedSupplierId; // link to suppliers.id (nullable)

  // ✅ Supplier details cache (for nice display)
  Map<String, dynamic>? _selectedSupplier; // row from suppliers (optional cache)

  // supplier search (dialog/sheet)
  final TextEditingController _supplierSearchCtl = TextEditingController();

  // ===== header (receipt) =====
  final supplierCtl = TextEditingController();
  final dnCtl = TextEditingController(); // delivery note
  final invoiceCtl = TextEditingController();
  final poCtl = TextEditingController();
  final noteCtl = TextEditingController();

  DateTime receivedAt = DateTime.now();
  final receivedAtCtl = TextEditingController();

  // ===== evidence (UI only - optional) =====
  String? evidenceFileName;

  // ===== item draft =====
  final lotCtl = TextEditingController();
  DateTime? expDate;
  final qtyCtl = TextEditingController();
  bool isPackInput = false;

  // ✅ NEW: price input mode
  _PriceInputMode _priceInputMode = _PriceInputMode.base;

  final costPerBaseCtl = TextEditingController();
  final sellPerBaseCtl = TextEditingController();

  // ===== items list =====
  final List<_StockInItemDraft> items = [];

  // ===== edit mode =====
  int? editingIndex;

  @override
  void initState() {
    super.initState();
    _syncReceivedAtCtl();
    _loadDrugs();
    _loadLastReceiptAutofill();

    _drugSearchCtl.addListener(() {
      setState(() => _drugQuery = _drugSearchCtl.text.trim().toLowerCase());
    });

    qtyCtl.addListener(_refreshPricePreview);
    costPerBaseCtl.addListener(_refreshPricePreview);
    sellPerBaseCtl.addListener(_refreshPricePreview);
  }

  @override
  void dispose() {
    supplierCtl.dispose();
    dnCtl.dispose();
    invoiceCtl.dispose();
    poCtl.dispose();
    noteCtl.dispose();
    receivedAtCtl.dispose();

    lotCtl.dispose();
    qtyCtl.dispose();
    costPerBaseCtl.dispose();
    sellPerBaseCtl.dispose();

    _drugSearchCtl.dispose();
    _supplierSearchCtl.dispose();

    super.dispose();
  }

  void _refreshPricePreview() {
    if (!mounted) return;
    setState(() {});
  }

  void _syncReceivedAtCtl() {
    receivedAtCtl.text =
        '${_fmtDate(receivedAt)} ${receivedAt.hour.toString().padLeft(2, '0')}:'
        '${receivedAt.minute.toString().padLeft(2, '0')}:'
        '${receivedAt.second.toString().padLeft(2, '0')}';
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _loadDrugs() async {
    setState(() => loading = true);
    try {
      drugs = (await repo.listDrugs())
          .where((d) => (d['is_active'] ?? true) == true)
          .toList();
      if (drugs.isNotEmpty) {
        selectedDrugId ??= drugs.first['id'].toString();
      }
    } catch (e) {
      _toast('โหลดรายการยาไม่สำเร็จ: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  /// ✅ Autofill จากบิลล่าสุด (ไม่ทำให้ของเดิมพัง)
  /// - supplier_name ยังคงใช้
  /// - supplier_id ถ้ามีจะ set ให้ (ถ้าไม่มี ก็ปล่อย null)
  Future<void> _loadLastReceiptAutofill() async {
    final user = sb.auth.currentUser;
    if (user == null) return;

    try {
      final res = await sb
          .from('stock_in_receipts')
          .select(
              'supplier_id, supplier_name, delivery_note_no, invoice_no, po_no, note')
          .eq('owner_id', user.id)
          .order('created_at', ascending: false)
          .limit(1);

      if (res is List && res.isNotEmpty) {
        final r = Map<String, dynamic>.from(res.first);

        _selectedSupplierId =
            (r['supplier_id'] == null) ? null : (r['supplier_id']).toString();

        supplierCtl.text = (r['supplier_name'] ?? '').toString();
        dnCtl.text = (r['delivery_note_no'] ?? '').toString();
        invoiceCtl.text = (r['invoice_no'] ?? '').toString();
        poCtl.text = (r['po_no'] ?? '').toString();
        noteCtl.text = (r['note'] ?? '').toString();

        // ✅ โหลดรายละเอียด supplier มาโชว์ (optional)
        if (_selectedSupplierId != null) {
          _selectedSupplier = await _getSupplierById(_selectedSupplierId!);
        }
      }
    } catch (_) {
      // optional
    }
  }

  Map<String, dynamic>? get _selectedDrug {
    if (selectedDrugId == null) return null;
    try {
      return drugs.firstWhere((d) => d['id'].toString() == selectedDrugId);
    } catch (_) {
      return null;
    }
  }

  // ✅ filter drugs by search (name/code/brand)
  List<Map<String, dynamic>> get _filteredDrugs {
    final q = _drugQuery;
    if (q.isEmpty) return drugs;

    return drugs.where((d) {
      final name = (d['generic_name'] ?? '').toString().toLowerCase();
      final code = (d['code'] ?? '').toString().toLowerCase();
      final brand = (d['brand_name'] ?? '').toString().toLowerCase();
      return name.contains(q) || code.contains(q) || brand.contains(q);
    }).toList();
  }

  Future<void> _pickExpDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: expDate ?? now.add(const Duration(days: 365)),
      firstDate: now.subtract(const Duration(days: 365 * 2)),
      lastDate: now.add(const Duration(days: 365 * 10)),
    );
    if (picked != null) setState(() => expDate = picked);
  }

  String _fmtDate(DateTime d) {
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }

  String _fmtMoney(num v, {int digits = 2}) => v.toStringAsFixed(digits);

  num? _tryNum(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    return num.tryParse(t);
  }

  double _round4(num v) => ((v * 10000).round() / 10000).toDouble();

  InputDecoration _dec(String label, {String? hint, IconData? icon}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: icon == null ? null : Icon(icon),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      filled: true,
      fillColor: Colors.white,
    );
  }

  String _baseUnitLabel(Map<String, dynamic>? drug) {
    final base = (drug?['base_unit'] ?? '').toString().trim();
    return base.isEmpty ? 'หน่วยฐาน' : base;
  }

  String _packUnitLabel(Map<String, dynamic>? drug) {
    final pack = (drug?['pack_unit'] ?? '').toString().trim();
    return pack.isEmpty ? 'Pack' : pack;
  }

  double? _packToBase(Map<String, dynamic>? drug) {
    final v = drug?['pack_to_base'];
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  String _normLot(String s) => s.trim().toLowerCase();

  bool _sameDateOnly(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  bool _sameDouble(double? a, double? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    return a == b;
  }

  int _findDuplicateCartIndex(
    _StockInItemDraft draft, {
    int? ignoreIndex,
  }) {
    for (int i = 0; i < items.length; i++) {
      if (ignoreIndex != null && i == ignoreIndex) continue;

      final it = items[i];
      final sameDrug = it.drugId == draft.drugId;
      final sameLot = _normLot(it.lotNo) == _normLot(draft.lotNo);
      final sameExp = _sameDateOnly(it.expDate, draft.expDate);

      if (sameDrug && sameLot && sameExp) {
        return i;
      }
    }
    return -1;
  }

  bool _canMergeDuplicate(_StockInItemDraft existing, _StockInItemDraft incoming) {
    return existing.inputUnitKind == incoming.inputUnitKind &&
        existing.inputUnitName == incoming.inputUnitName &&
        existing.toBase == incoming.toBase &&
        _sameDouble(existing.costPerBase, incoming.costPerBase) &&
        _sameDouble(existing.sellPerBase, incoming.sellPerBase);
  }

  Future<_DuplicateDecision?> _showDuplicateDialog({
    required _StockInItemDraft existing,
    required _StockInItemDraft incoming,
    required bool canMerge,
    required bool editingMode,
  }) async {
    if (!mounted) return null;

    return showDialog<_DuplicateDecision>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        final cs = Theme.of(context).colorScheme;

        Widget infoBox({
          required String title,
          required _StockInItemDraft item,
          required Color color,
        }) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: color.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color.withOpacity(0.25)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontWeight: FontWeight.w800, color: color)),
                const SizedBox(height: 8),
                Text(
                  '${item.drugName} (${item.drugCode})',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Text('Lot: ${item.lotNo}'),
                Text('EXP: ${_fmtDate(item.expDate)}'),
                Text('จำนวน: ${item.inputQty} ${item.inputUnitName}'),
                Text('หน่วยฐาน: ${item.baseQty.toStringAsFixed(2)} ${item.baseUnitName}'),
                if (item.costInputValue != null)
                  Text(
                    'ทุนที่กรอก: ${item.costInputValue} / ${item.priceInputMode == _PriceInputMode.base ? item.baseUnitName : item.packUnitNameForPrice}',
                  ),
                if (item.sellInputValue != null)
                  Text(
                    'ขายที่กรอก: ${item.sellInputValue} / ${item.priceInputMode == _PriceInputMode.base ? item.baseUnitName : item.packUnitNameForPrice}',
                  ),
                if (item.costPerBase != null)
                  Text('ทุน/หน่วยฐาน: ${item.costPerBase}'),
                if (item.sellPerBase != null)
                  Text('ขาย/หน่วยฐาน: ${item.sellPerBase}'),
              ],
            ),
          );
        }

        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.orange.shade700),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'พบล็อตซ้ำในตะกร้า',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    editingMode
                        ? 'รายการที่คุณกำลังแก้ไข ชนกับรายการเดิมในตะกร้า'
                        : 'มียาตัวเดียวกัน เลขล็อตเดียวกัน และวันหมดอายุเดียวกัน อยู่ในตะกร้าแล้ว',
                    style: const TextStyle(height: 1.5),
                  ),
                  const SizedBox(height: 12),
                  infoBox(
                    title: 'รายการเดิมในตะกร้า',
                    item: existing,
                    color: cs.primary,
                  ),
                  const SizedBox(height: 10),
                  infoBox(
                    title: editingMode ? 'รายการหลังแก้ไข' : 'รายการที่กำลังเพิ่ม',
                    item: incoming,
                    color: Colors.deepOrange,
                  ),
                  const SizedBox(height: 12),
                  if (canMerge)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.green.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.green.withOpacity(0.25)),
                      ),
                      child: const Text(
                        'รายการนี้สามารถ "รวมจำนวน" ได้ เพราะหน่วยรับเข้า และราคาทุน/ราคาขายต่อหน่วยฐาน ตรงกัน',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    )
                  else
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.orange.withOpacity(0.25)),
                      ),
                      child: const Text(
                        'รายการนี้ไม่ควรรวมอัตโนมัติ เพราะหน่วยรับเข้า หรือราคาทุน/ราคาขาย ต่างกัน\nแนะนำให้กลับไปแก้ไขรายการเดิมให้ถูกต้องก่อน',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, _DuplicateDecision.cancel),
              child: const Text('ยกเลิก'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, _DuplicateDecision.editExisting),
              child: const Text('ไปแก้ไขรายการเดิม'),
            ),
            if (canMerge)
              FilledButton.icon(
                onPressed: () => Navigator.pop(context, _DuplicateDecision.merge),
                icon: const Icon(Icons.merge_type_rounded),
                label: const Text('รวมจำนวน'),
              ),
          ],
        );
      },
    );
  }

  void _resetItemDraft() {
    lotCtl.clear();
    qtyCtl.clear();
    costPerBaseCtl.clear();
    sellPerBaseCtl.clear();
    expDate = null;
    isPackInput = false;
    _priceInputMode = _PriceInputMode.base;
    editingIndex = null;
  }

  void _startEditItem(int index) {
    final it = items[index];
    setState(() {
      editingIndex = index;
      selectedDrugId = it.drugId;
      lotCtl.text = it.lotNo;
      expDate = it.expDate;
      qtyCtl.text = it.inputQty.toString();
      isPackInput = it.inputUnitKind == _InputUnitKind.pack;
      _priceInputMode = it.priceInputMode;
      costPerBaseCtl.text = it.costInputValue?.toString() ?? '';
      sellPerBaseCtl.text = it.sellInputValue?.toString() ?? '';
    });
  }

  void _removeItem(int index) {
    setState(() {
      if (editingIndex == index) {
        _resetItemDraft();
      } else if (editingIndex != null && index < editingIndex!) {
        editingIndex = editingIndex! - 1;
      }
      items.removeAt(index);
    });
  }

  _ComputedPriceResult _computePriceResultForDrug(Map<String, dynamic>? drug) {
    final baseUnit = _baseUnitLabel(drug);
    final packUnit = _packUnitLabel(drug);
    final packToBase = _packToBase(drug);

    final costInput = _tryNum(costPerBaseCtl.text);
    final sellInput = _tryNum(sellPerBaseCtl.text);

    if (_priceInputMode == _PriceInputMode.base) {
      return _ComputedPriceResult(
        ok: true,
        baseUnitName: baseUnit,
        priceRefUnitName: baseUnit,
        packUnitName: packUnit,
        packToBase: packToBase,
        costInputValue: costInput?.toDouble(),
        sellInputValue: sellInput?.toDouble(),
        costPerBase: costInput == null ? null : _round4(costInput),
        sellPerBase: sellInput == null ? null : _round4(sellInput),
      );
    }

    if (packToBase == null || packToBase <= 0) {
      return _ComputedPriceResult(
        ok: false,
        baseUnitName: baseUnit,
        priceRefUnitName: packUnit,
        packUnitName: packUnit,
        packToBase: packToBase,
        errorMessage: 'ยานี้ยังไม่ได้ตั้งค่าหน่วยบรรจุ/pack_to_base',
      );
    }

    return _ComputedPriceResult(
      ok: true,
      baseUnitName: baseUnit,
      priceRefUnitName: packUnit,
      packUnitName: packUnit,
      packToBase: packToBase,
      costInputValue: costInput?.toDouble(),
      sellInputValue: sellInput?.toDouble(),
      costPerBase:
          costInput == null ? null : _round4(costInput / packToBase),
      sellPerBase:
          sellInput == null ? null : _round4(sellInput / packToBase),
    );
  }

  Future<void> _addOrUpdateItem() async {
    final form = _itemKey.currentState;
    if (form == null) {
      _toast('ฟอร์มรายการยังไม่พร้อม ลองใหม่อีกครั้ง');
      return;
    }
    if (!form.validate()) return;
    if (selectedDrugId == null) {
      _toast('กรุณาเลือกยา');
      return;
    }

    final drug = _selectedDrug;
    if (drug == null) {
      _toast('กรุณาเลือกยา');
      return;
    }
    if (expDate == null) {
      _toast('กรุณาเลือกวันหมดอายุ');
      return;
    }

    final qty = int.parse(qtyCtl.text.trim());
    final packToBase = _packToBase(drug);

    final unitKind = isPackInput ? _InputUnitKind.pack : _InputUnitKind.base;
    final inputUnitName = isPackInput ? _packUnitLabel(drug) : _baseUnitLabel(drug);

    final toBase = (unitKind == _InputUnitKind.base) ? 1.0 : (packToBase ?? 0);

    if (unitKind == _InputUnitKind.pack && (packToBase == null || packToBase <= 0)) {
      _toast('ยานี้ยังไม่มี pack_to_base ที่ถูกต้อง');
      return;
    }

    final priceResult = _computePriceResultForDrug(drug);
    if (!priceResult.ok) {
      _toast(priceResult.errorMessage ?? 'คำนวณราคาไม่สำเร็จ');
      return;
    }

    final costInput = _tryNum(costPerBaseCtl.text);
    final sellInput = _tryNum(sellPerBaseCtl.text);

    if (costInput != null && costInput < 0) {
      _toast('ราคาทุนต้องเป็นเลข 0 ขึ้นไป');
      return;
    }
    if (sellInput != null && sellInput < 0) {
      _toast('ราคาขายต้องเป็นเลข 0 ขึ้นไป');
      return;
    }

    final baseQty = qty * toBase;

    final draft = _StockInItemDraft(
      drugId: selectedDrugId!,
      drugName: (drug['generic_name'] ?? '').toString(),
      drugCode: (drug['code'] ?? '').toString(),
      lotNo: lotCtl.text.trim(),
      expDate: expDate!,
      inputQty: qty,
      inputUnitName: inputUnitName,
      inputUnitKind: unitKind,
      toBase: toBase,
      baseQty: baseQty,
      costInputValue: priceResult.costInputValue,
      sellInputValue: priceResult.sellInputValue,
      priceInputMode: _priceInputMode,
      costPerBase: priceResult.costPerBase,
      sellPerBase: priceResult.sellPerBase,
      baseUnitName: _baseUnitLabel(drug),
      packUnitNameForPrice: _packUnitLabel(drug),
    );

    final wasEditing = editingIndex != null;
    final duplicateIndex = _findDuplicateCartIndex(
      draft,
      ignoreIndex: editingIndex,
    );

    if (duplicateIndex >= 0) {
      final existing = items[duplicateIndex];
      final canMerge = _canMergeDuplicate(existing, draft);

      final decision = await _showDuplicateDialog(
        existing: existing,
        incoming: draft,
        canMerge: canMerge,
        editingMode: wasEditing,
      );

      if (decision == null || decision == _DuplicateDecision.cancel) {
        return;
      }

      if (decision == _DuplicateDecision.editExisting) {
        _startEditItem(duplicateIndex);
        _toast('เปิดรายการเดิมให้แก้ไขแล้ว');
        return;
      }

      if (decision == _DuplicateDecision.merge && canMerge) {
        final merged = existing.copyWith(
          inputQty: existing.inputQty + draft.inputQty,
          baseQty: existing.baseQty + draft.baseQty,
        );

        setState(() {
          items[duplicateIndex] = merged;

          if (wasEditing && editingIndex != null) {
            final oldEditingIndex = editingIndex!;
            if (oldEditingIndex != duplicateIndex) {
              items.removeAt(oldEditingIndex);
            }
          }

          _resetItemDraft();
        });

        _toast('รวมจำนวนเข้ากับล็อตเดิมแล้ว');
        return;
      }

      return;
    }

    setState(() {
      if (editingIndex == null) {
        items.add(draft);
      } else {
        items[editingIndex!] = draft;
      }
      _resetItemDraft();
    });

    _toast(wasEditing ? 'อัปเดตรายการแล้ว' : 'เพิ่มรายการแล้ว');
  }

  // ✅ ปุ่มกดต้อง “เห็นผลแน่ ๆ”
  Future<void> _onSavePressed() async {
    debugPrint('=== STOCK_IN: Save button pressed ===');
    FocusScope.of(context).unfocus();
    await _saveAll();
  }

  // ===============================
  // SUPPLIERS (Upgraded like manufacturer)
  // ===============================

  static const String _suppliersTable = 'suppliers';

  Future<Map<String, dynamic>?> _getSupplierById(String id) async {
    final user = sb.auth.currentUser;
    if (user == null) return null;

    final row = await sb
        .from(_suppliersTable)
        .select(
          'id, name, company_name, contact_name, address, delivery_area, phone, line_id, email, company_reg_no, drug_license_no, code, is_default, is_active',
        )
        .eq('owner_id', user.id)
        .eq('id', id)
        .maybeSingle();

    if (row == null) return null;
    return Map<String, dynamic>.from(row as Map);
  }

  Future<List<Map<String, dynamic>>> _loadSuppliers({String q = ''}) async {
    final user = sb.auth.currentUser;
    if (user == null) return [];

    final query = q.trim().toLowerCase();

    final rows = await sb
        .from(_suppliersTable)
        .select(
          'id, name, company_name, contact_name, address, delivery_area, phone, line_id, email, company_reg_no, drug_license_no, code, is_default, is_active',
        )
        .eq('owner_id', user.id)
        .eq('is_active', true)
        .order('is_default', ascending: false)
        .order('name', ascending: true)
        .limit(300);

    final list = (rows is List)
        ? rows.map((e) => Map<String, dynamic>.from(e as Map)).toList()
        : <Map<String, dynamic>>[];

    if (query.isEmpty) return list;

    bool containsAny(Map<String, dynamic> s) {
      String t(String k) => (s[k] ?? '').toString().toLowerCase();
      final ql = query;
      return t('name').contains(ql) ||
          t('company_name').contains(ql) ||
          t('contact_name').contains(ql) ||
          t('code').contains(ql) ||
          t('phone').contains(ql) ||
          t('line_id').contains(ql) ||
          t('email').contains(ql) ||
          t('company_reg_no').contains(ql) ||
          t('drug_license_no').contains(ql) ||
          t('address').contains(ql) ||
          t('delivery_area').contains(ql);
    }

    return list.where(containsAny).toList();
  }

  String _supplierTitle(Map<String, dynamic> s) {
    final name = (s['name'] ?? '').toString().trim();
    final company = (s['company_name'] ?? '').toString().trim();

    if (company.isNotEmpty) return company;
    return name.isEmpty ? '-' : name;
  }

  String _supplierSubtitle(Map<String, dynamic> s) {
    final contact = (s['contact_name'] ?? '').toString().trim();
    final phone = (s['phone'] ?? '').toString().trim();
    final line = (s['line_id'] ?? '').toString().trim();
    final email = (s['email'] ?? '').toString().trim();
    final area = (s['delivery_area'] ?? '').toString().trim();

    final parts = <String>[];
    if (contact.isNotEmpty) parts.add('ติดต่อ $contact');
    if (phone.isNotEmpty) parts.add('โทร $phone');
    if (line.isNotEmpty) parts.add('Line $line');
    if (email.isNotEmpty) parts.add(email);
    if (area.isNotEmpty) parts.add('ส่ง $area');

    return parts.isEmpty ? '-' : parts.join(' • ');
  }

  String _supplierDetailText(Map<String, dynamic>? s) {
    if (s == null) return '';
    String g(String k) => (s[k] ?? '').toString().trim();

    final company = g('company_name');
    final name = g('name');
    final contact = g('contact_name');
    final address = g('address');
    final area = g('delivery_area');
    final phone = g('phone');
    final line = g('line_id');
    final email = g('email');
    final reg = g('company_reg_no');
    final lic = g('drug_license_no');

    final lines = <String>[];
    if (company.isNotEmpty) lines.add(company);
    if (company.isNotEmpty && name.isNotEmpty && name != company) {
      lines.add('Supplier: $name');
    }
    if (company.isEmpty && name.isNotEmpty) lines.add(name);
    if (contact.isNotEmpty) lines.add('ผู้ติดต่อ: $contact');
    if (address.isNotEmpty) lines.add('ที่อยู่: $address');
    if (area.isNotEmpty) lines.add('พื้นที่จัดส่ง: $area');

    final comm = <String>[];
    if (phone.isNotEmpty) comm.add('โทร $phone');
    if (line.isNotEmpty) comm.add('Line $line');
    if (email.isNotEmpty) comm.add(email);
    if (comm.isNotEmpty) lines.add(comm.join(' • '));

    if (reg.isNotEmpty) lines.add('เลขทะเบียนบริษัท: $reg');
    if (lic.isNotEmpty) lines.add('ใบอนุญาตจำหน่ายยา: $lic');

    return lines.join('\n');
  }

  // ✅ Bottom Sheet เลือก Supplier (เหมือน manufacturer)
  void _showSupplierPickerSheet() {
    String searchQuery = _supplierSearchCtl.text;
    bool loadingList = true;
    bool didInit = false;
    List<Map<String, dynamic>> list = [];

    Future<void> load(StateSetter setModalState) async {
      setModalState(() => loadingList = true);
      try {
        list = await _loadSuppliers(q: searchQuery);
      } catch (e) {
        debugPrint('SUPPLIER LOAD ERROR: $e');
      } finally {
        setModalState(() => loadingList = false);
      }
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            if (!didInit) {
              didInit = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (Navigator.of(context).canPop()) {
                  load(setModalState);
                }
              });
            }

            return Container(
              height: MediaQuery.of(context).size.height * 0.82,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'เลือก Supplier',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      controller: _supplierSearchCtl,
                      decoration: InputDecoration(
                        hintText:
                            'ค้นหา: ชื่อ/บริษัท/ผู้ติดต่อ/โทร/Line/Email/ทะเบียน/ใบอนุญาต',
                        prefixIcon: const Icon(Icons.search),
                        filled: true,
                        fillColor: Colors.grey.shade100,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onChanged: (value) {
                        searchQuery = value;
                        unawaited(load(setModalState));
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: loadingList
                        ? const Center(child: CircularProgressIndicator())
                        : list.isEmpty
                            ? Center(
                                child: Text(
                                  'ไม่พบ Supplier\nคุณสามารถ “เพิ่มใหม่” ได้ด้านล่าง',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: Colors.grey),
                                ),
                              )
                            : ListView.separated(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                itemCount: list.length,
                                separatorBuilder: (_, __) => const Divider(height: 1),
                                itemBuilder: (context, index) {
                                  final s = list[index];
                                  final isDefault = (s['is_default'] == true);

                                  return ListTile(
                                    leading: CircleAvatar(
                                      backgroundColor: Theme.of(context)
                                          .colorScheme
                                          .primary
                                          .withOpacity(0.1),
                                      child: Icon(
                                        isDefault
                                            ? Icons.star_rounded
                                            : Icons.store_rounded,
                                        color: isDefault
                                            ? Colors.amber.shade700
                                            : Theme.of(context).colorScheme.primary,
                                      ),
                                    ),
                                    title: Text(
                                      _supplierTitle(s),
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w700),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(
                                      _supplierSubtitle(s),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    onTap: () {
                                      setState(() {
                                        _selectedSupplier = s;
                                        _selectedSupplierId =
                                            (s['id'] ?? '').toString();

                                        final displayName = (s['company_name'] ?? '')
                                                .toString()
                                                .trim()
                                                .isNotEmpty
                                            ? (s['company_name'] ?? '').toString()
                                            : (s['name'] ?? '').toString();
                                        supplierCtl.text = displayName;
                                      });
                                      Navigator.pop(context);
                                    },
                                  );
                                },
                              ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () {
                          Navigator.pop(context);
                          _showAddSupplierDialog();
                        },
                        icon: const Icon(Icons.add_business_rounded),
                        label: const Text('เพิ่ม Supplier ใหม่',
                            style: TextStyle(fontSize: 16)),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  InputDecoration _niceDec(String label,
      {String? hintText, String? helperText, IconData? icon}) {
    return InputDecoration(
      labelText: label,
      hintText: hintText,
      helperText: helperText,
      prefixIcon: icon == null ? null : Icon(icon),
      filled: true,
      fillColor: Colors.grey.shade50,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.grey.shade300),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.grey.shade300),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide:
            BorderSide(color: Theme.of(context).colorScheme.primary, width: 2),
      ),
    );
  }

  // ✅ Dialog เพิ่ม Supplier ใหม่ (เหมือน manufacturer)
  void _showAddSupplierDialog() {
    final formKey = GlobalKey<FormState>();

    final nameCtl = TextEditingController();
    final companyCtl = TextEditingController();
    final contactCtl = TextEditingController();

    final addressCtl = TextEditingController();
    final areaCtl = TextEditingController();

    final phoneCtl = TextEditingController();
    final lineCtl = TextEditingController();
    final emailCtl = TextEditingController();

    final regCtl = TextEditingController();
    final licenseCtl = TextEditingController();

    bool savingLocal = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> doSave() async {
              if (!(formKey.currentState?.validate() ?? false)) return;

              setDialogState(() => savingLocal = true);
              try {
                final user = sb.auth.currentUser;
                if (user == null) throw Exception('ยังไม่ได้ล็อกอิน');

                final payload = <String, dynamic>{
                  'owner_id': user.id,
                  'name': nameCtl.text.trim(),
                  'company_name': companyCtl.text.trim().isEmpty
                      ? null
                      : companyCtl.text.trim(),
                  'contact_name': contactCtl.text.trim().isEmpty
                      ? null
                      : contactCtl.text.trim(),
                  'address': addressCtl.text.trim().isEmpty
                      ? null
                      : addressCtl.text.trim(),
                  'delivery_area': areaCtl.text.trim().isEmpty
                      ? null
                      : areaCtl.text.trim(),
                  'phone': phoneCtl.text.trim().isEmpty
                      ? null
                      : phoneCtl.text.trim(),
                  'line_id': lineCtl.text.trim().isEmpty
                      ? null
                      : lineCtl.text.trim(),
                  'email': emailCtl.text.trim().isEmpty
                      ? null
                      : emailCtl.text.trim(),
                  'company_reg_no': regCtl.text.trim().isEmpty
                      ? null
                      : regCtl.text.trim(),
                  'drug_license_no': licenseCtl.text.trim().isEmpty
                      ? null
                      : licenseCtl.text.trim(),
                  'is_active': true,
                };

                final created = await sb
                    .from(_suppliersTable)
                    .insert(payload)
                    .select(
                      'id, name, company_name, contact_name, address, delivery_area, phone, line_id, email, company_reg_no, drug_license_no, code, is_default, is_active',
                    )
                    .single();

                final row = Map<String, dynamic>.from(created as Map);

                if (!mounted) return;
                setState(() {
                  _selectedSupplier = row;
                  _selectedSupplierId = (row['id'] ?? '').toString();

                  final displayName =
                      (row['company_name'] ?? '').toString().trim().isNotEmpty
                          ? (row['company_name'] ?? '').toString()
                          : (row['name'] ?? '').toString();
                  supplierCtl.text = displayName;
                });

                if (mounted) Navigator.pop(context);

                _toast('เพิ่ม Supplier เรียบร้อยแล้ว ✅');
              } catch (e) {
                _toast('เพิ่ม Supplier ไม่สำเร็จ: $e');
              } finally {
                setDialogState(() => savingLocal = false);
              }
            }

            return AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  Icon(Icons.add_business_rounded,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  const Text('เพิ่ม Supplier ใหม่',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
              content: SingleChildScrollView(
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: nameCtl,
                        decoration: _niceDec('ชื่อ Supplier *',
                            hintText: 'เช่น ร้าน A / คลัง B / บริษัท C'),
                        validator: (v) =>
                            (v ?? '').trim().isEmpty ? 'กรุณากรอกชื่อ Supplier' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: companyCtl,
                        decoration: _niceDec('ชื่อบริษัท',
                            hintText: 'เช่น ABC Pharma Co., Ltd.'),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: contactCtl,
                        decoration:
                            _niceDec('ชื่อผู้ติดต่อ', hintText: 'เช่น คุณสมชาย'),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: addressCtl,
                        maxLines: 2,
                        decoration: _niceDec('ที่อยู่'),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: areaCtl,
                        decoration: _niceDec('พื้นที่จัดส่ง',
                            hintText: 'เช่น กทม./นนทบุรี/ปริมณฑล'),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: phoneCtl,
                        keyboardType: TextInputType.phone,
                        decoration: _niceDec('เบอร์โทร'),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: lineCtl,
                        decoration: _niceDec('Line ID'),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: emailCtl,
                        keyboardType: TextInputType.emailAddress,
                        decoration: _niceDec('Email'),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: regCtl,
                        decoration: _niceDec('เลขทะเบียนบริษัท'),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: licenseCtl,
                        decoration: _niceDec('ใบอนุญาตจำหน่ายยา'),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: savingLocal ? null : () => Navigator.pop(context),
                  child: const Text('ยกเลิก',
                      style: TextStyle(color: Colors.grey)),
                ),
                FilledButton(
                  onPressed: savingLocal ? null : doSave,
                  child: savingLocal
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2),
                        )
                      : const Text('บันทึก'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<String?> _ensureSupplierIdFromName(String name) async {
    final user = sb.auth.currentUser;
    if (user == null) return null;

    final n = name.trim();
    if (n.isEmpty) return null;

    final found = await sb
        .from(_suppliersTable)
        .select(
          'id, name, company_name, contact_name, address, delivery_area, phone, line_id, email, company_reg_no, drug_license_no, is_default, is_active',
        )
        .eq('owner_id', user.id)
        .eq('name', n)
        .limit(1);

    if (found is List && found.isNotEmpty) {
      final row = Map<String, dynamic>.from(found.first as Map);
      _selectedSupplier = row;
      return (row['id'] ?? '').toString();
    }

    final created = await sb
        .from(_suppliersTable)
        .insert({
          'owner_id': user.id,
          'name': n,
          'is_active': true,
        })
        .select(
          'id, name, company_name, contact_name, address, delivery_area, phone, line_id, email, company_reg_no, drug_license_no, is_default, is_active',
        )
        .single();

    final row = Map<String, dynamic>.from(created as Map);
    _selectedSupplier = row;

    return (row['id'] ?? '').toString();
  }

  // ===============================
  // ✅ SAVE ALL (Receipt + Items + RPC add_stock_lot)
  // ===============================
  Future<void> _saveAll() async {
    final user = sb.auth.currentUser;
    if (user == null) {
      _toast('กรุณาเข้าสู่ระบบก่อน');
      return;
    }

    if (saving) {
      _toast('กำลังบันทึกอยู่...');
      return;
    }

    final headerOk = _headerKey.currentState?.validate() ?? true;
    if (!headerOk) {
      _toast('กรุณาตรวจสอบข้อมูลหัวบิล');
      return;
    }

    if (items.isEmpty) {
      _toast('ตะกร้าว่าง — เพิ่มรายการก่อน');
      return;
    }

    setState(() => saving = true);
    _toast('กำลังบันทึก...');

    try {
      final supplierName = supplierCtl.text.trim();
      String? supplierId = _selectedSupplierId;

      if (supplierId == null && supplierName.isNotEmpty) {
        supplierId = await _ensureSupplierIdFromName(supplierName);
      }

      final receiptInsert = await sb
          .from('stock_in_receipts')
          .insert({
            'owner_id': user.id,
            'supplier_name': supplierName.isEmpty ? null : supplierName,
            'supplier_id': supplierId,
            'delivery_note_no': dnCtl.text.trim().isEmpty ? null : dnCtl.text.trim(),
            'invoice_no': invoiceCtl.text.trim().isEmpty ? null : invoiceCtl.text.trim(),
            'po_no': poCtl.text.trim().isEmpty ? null : poCtl.text.trim(),
            'note': noteCtl.text.trim().isEmpty ? null : noteCtl.text.trim(),
            'received_at': receivedAt.toIso8601String(),
          })
          .select('id')
          .single()
          .timeout(const Duration(seconds: 15));

      final receiptId = (receiptInsert['id'] ?? '').toString();
      debugPrint('Receipt created: $receiptId');

      for (final it in items) {
        debugPrint(
            'Insert item drug=${it.drugId} lot=${it.lotNo} exp=${_fmtDate(it.expDate)} baseQty=${it.baseQty} cost_per_base=${it.costPerBase} sell_per_base=${it.sellPerBase}');

        await sb.from('stock_in_items').insert({
          'owner_id': user.id,
          'receipt_id': receiptId,
          'drug_id': it.drugId,
          'lot_no': it.lotNo,
          'exp_date': _fmtDate(it.expDate),
          'input_qty': it.inputQty,
          'input_unit': it.inputUnitName,
          'to_base': it.toBase,
          'base_qty': it.baseQty,
          'cost_per_base': it.costPerBase,
          'sell_per_base': it.sellPerBase,
        }).timeout(const Duration(seconds: 15));

        await sb.rpc('add_stock_lot', params: {
          'p_owner_id': user.id,
          'p_drug_id': it.drugId,
          'p_lot_no': it.lotNo,
          'p_exp_date': _fmtDate(it.expDate),
          'p_add_qty': it.baseQty,
        }).timeout(const Duration(seconds: 15));
      }

      if (!mounted) return;
      _toast('บันทึกรับยาเข้าเรียบร้อย ✅');

      Navigator.pop(context, true);
    } on TimeoutException {
      debugPrint('=== STOCK_IN TIMEOUT ===');
      _toast('บันทึกช้า/ค้างเกินเวลา ลองใหม่อีกครั้ง (เช็คเน็ต/เช็ค RPC)');
    } catch (e, st) {
      debugPrint('=== STOCK_IN SAVE ERROR ===');
      debugPrint('Error: $e');
      debugPrint('Stack: $st');
      _toast('บันทึกไม่สำเร็จ: $e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final filtered = _filteredDrugs;

    final selectedOk = selectedDrugId != null &&
        filtered.any((d) => d['id'].toString() == selectedDrugId);
    if (!selectedOk && filtered.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final next = filtered.first['id'].toString();
        if (selectedDrugId == next) return;
        setState(() => selectedDrugId = next);
      });
    }

    final drug = _selectedDrug;
    final baseUnit = _baseUnitLabel(drug);
    final packUnit = _packUnitLabel(drug);
    final packToBase = _packToBase(drug);

    final unitLabel = isPackInput ? packUnit : baseUnit;

    final supplierDetail = _supplierDetailText(_selectedSupplier);
    final priceResult = _computePriceResultForDrug(drug);

    return Scaffold(
      backgroundColor: const Color(0xFFF4F7FB),
      appBar: AppBar(
        backgroundColor: cs.primary,
        foregroundColor: Colors.white,
        title: const Text('รับยาเข้า'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ===== Header Card =====
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: Colors.black.withOpacity(0.06)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Form(
                      key: _headerKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.inventory_2_rounded),
                              const SizedBox(width: 8),
                              const Expanded(
                                child: Text(
                                  'รับยาเข้าจาก Supplier (บิลเดียวหลายรายการ)',
                                  style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.green.withOpacity(0.10),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                      color: Colors.green.withOpacity(0.25)),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.check_circle_rounded,
                                        size: 16, color: Colors.green),
                                    SizedBox(width: 6),
                                    Text('เลือก EXP ได้',
                                        style: TextStyle(
                                            fontWeight: FontWeight.w600)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'กรอกข้อมูลเอกสาร → เพิ่มรายการรับยาเข้า → กดยืนยันครั้งเดียว',
                            style: TextStyle(color: Colors.black.withOpacity(0.55)),
                          ),
                          const SizedBox(height: 16),
                          LayoutBuilder(
                            builder: (context, c) {
                              final wide = c.maxWidth >= 720;
                              return Wrap(
                                runSpacing: 12,
                                spacing: 12,
                                children: [
                                  SizedBox(
                                    width: wide ? (c.maxWidth - 12) / 2 : c.maxWidth,
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: TextFormField(
                                                controller: supplierCtl,
                                                decoration: _dec(
                                                  'Supplier (ชื่อแหล่งที่มียาออกมา)',
                                                  icon: Icons.store_rounded,
                                                ),
                                                onChanged: (_) {
                                                  if (_selectedSupplierId != null) {
                                                    setState(() {
                                                      _selectedSupplierId = null;
                                                      _selectedSupplier = null;
                                                    });
                                                  }
                                                },
                                              ),
                                            ),
                                            const SizedBox(width: 10),
                                            SizedBox(
                                              height: 56,
                                              child: OutlinedButton.icon(
                                                icon: const Icon(
                                                    Icons.manage_search_rounded),
                                                label: const Text('เลือก'),
                                                onPressed: saving
                                                    ? null
                                                    : _showSupplierPickerSheet,
                                              ),
                                            ),
                                          ],
                                        ),
                                        if (supplierDetail.trim().isNotEmpty) ...[
                                          const SizedBox(height: 10),
                                          Container(
                                            width: double.infinity,
                                            padding: const EdgeInsets.all(12),
                                            decoration: BoxDecoration(
                                              color: cs.primary.withOpacity(0.06),
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              border: Border.all(
                                                  color:
                                                      cs.primary.withOpacity(0.18)),
                                            ),
                                            child: Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Icon(Icons.info_outline_rounded,
                                                    color: cs.primary),
                                                const SizedBox(width: 10),
                                                Expanded(
                                                  child: Text(
                                                    supplierDetail,
                                                    style: TextStyle(
                                                      color: Colors.black
                                                          .withOpacity(0.75),
                                                      height: 1.35,
                                                      fontWeight: FontWeight.w600,
                                                    ),
                                                  ),
                                                ),
                                                IconButton(
                                                  tooltip:
                                                      'ล้าง Supplier ที่เลือก',
                                                  onPressed: () {
                                                    setState(() {
                                                      _selectedSupplierId = null;
                                                      _selectedSupplier = null;
                                                      supplierCtl.clear();
                                                    });
                                                  },
                                                  icon:
                                                      const Icon(Icons.close_rounded),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  SizedBox(
                                    width: wide ? (c.maxWidth - 12) / 2 : c.maxWidth,
                                    child: TextFormField(
                                      readOnly: true,
                                      controller: receivedAtCtl,
                                      decoration: _dec('วันรับเข้า',
                                          icon: Icons.schedule_rounded),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 12),
                          LayoutBuilder(
                            builder: (context, c) {
                              final wide = c.maxWidth >= 720;
                              final w = wide ? (c.maxWidth - 24) / 3 : c.maxWidth;
                              return Wrap(
                                runSpacing: 12,
                                spacing: 12,
                                children: [
                                  SizedBox(
                                    width: w,
                                    child: TextFormField(
                                      controller: dnCtl,
                                      decoration:
                                          _dec('เลขใบส่งของ (Delivery Note No.)'),
                                    ),
                                  ),
                                  SizedBox(
                                    width: w,
                                    child: TextFormField(
                                      controller: invoiceCtl,
                                      decoration: _dec(
                                          'เลขบิลกำกับภาษี (Invoice No.)'),
                                    ),
                                  ),
                                  SizedBox(
                                    width: w,
                                    child: TextFormField(
                                      controller: poCtl,
                                      decoration: _dec('เลข PO (ถ้ามี)'),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: noteCtl,
                            minLines: 2,
                            maxLines: 4,
                            decoration: _dec(
                                'หมายเหตุเอกสาร/การรับเข้า (ใช้ร่วมทั้งบิล)'),
                          ),
                          const SizedBox(height: 14),
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                  color: Colors.black.withOpacity(0.08)),
                              color: Colors.white,
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.attachment_rounded),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'แนบรูปหลักฐาน (ใช้ร่วมทั้งบิล)',
                                        style: TextStyle(
                                            fontWeight: FontWeight.w700),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        evidenceFileName == null
                                            ? 'แนบใบส่งของ/ใบกำกับภาษีได้ (ถ่ายจากมือถือ)'
                                            : 'ไฟล์ที่เลือก: $evidenceFileName',
                                        style: TextStyle(
                                            color:
                                                Colors.black.withOpacity(0.55)),
                                      ),
                                    ],
                                  ),
                                ),
                                OutlinedButton(
                                  onPressed: () {
                                    setState(() => evidenceFileName =
                                        'evidence_${DateTime.now().millisecondsSinceEpoch}.jpg');
                                    _toast(
                                        'TODO: ผูก image_picker + อัปโหลด Storage');
                                  },
                                  child: const Text('สำรวจ'),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 14),

                // ===== Item Entry Card =====
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: Colors.black.withOpacity(0.06)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Form(
                      key: _itemKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('เพิ่มรายการรับเข้า',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 12),

                          TextFormField(
                            controller: _drugSearchCtl,
                            decoration: _dec('ค้นหายา (ชื่อ / รหัส / ยี่ห้อ)',
                                    icon: Icons.search_rounded)
                                .copyWith(
                              suffixIcon: _drugQuery.isEmpty
                                  ? null
                                  : IconButton(
                                      tooltip: 'ล้างคำค้น',
                                      icon: const Icon(Icons.close_rounded),
                                      onPressed: () => _drugSearchCtl.clear(),
                                    ),
                            ),
                          ),
                          const SizedBox(height: 10),

                          DropdownButtonFormField<String>(
                            isExpanded: true,
                            itemHeight: 64,
                            value: selectedOk
                                ? selectedDrugId
                                : (filtered.isNotEmpty
                                    ? filtered.first['id'].toString()
                                    : null),
                            decoration: _dec('เลือกยา'),
                            selectedItemBuilder: (context) {
                              return filtered.map((d) {
                                final name = (d['generic_name'] ?? '').toString();
                                final code = (d['code'] ?? '').toString();
                                return Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    '$name ($code)',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700),
                                  ),
                                );
                              }).toList();
                            },
                            items: filtered.map((d) {
                              final name = (d['generic_name'] ?? '').toString();
                              final code = (d['code'] ?? '').toString();
                              final brand = (d['brand_name'] ?? '').toString();

                              return DropdownMenuItem(
                                value: d['id'].toString(),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w700),
                                    ),
                                    Text(
                                      'Code: $code${brand.isNotEmpty ? ' • $brand' : ''}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.black.withOpacity(0.55)),
                                    ),
                                  ],
                                ),
                              );
                            }).toList(),
                            onChanged: (v) => setState(() => selectedDrugId = v),
                          ),

                          if (_drugQuery.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Row(
                                children: [
                                  Icon(Icons.filter_alt_rounded,
                                      size: 18,
                                      color: Colors.black.withOpacity(0.55)),
                                  const SizedBox(width: 6),
                                  Text(
                                    'พบ ${filtered.length} รายการ',
                                    style: TextStyle(
                                      color: Colors.black.withOpacity(0.55),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                          const SizedBox(height: 12),

                          if (drug != null)
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: cs.primary.withOpacity(0.06),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: cs.primary.withOpacity(0.18),
                                ),
                              ),
                              child: Wrap(
                                spacing: 10,
                                runSpacing: 8,
                                children: [
                                  _infoChip('หน่วยฐาน: $baseUnit'),
                                  _infoChip('หน่วยบรรจุ: $packUnit'),
                                  _infoChip(
                                    packToBase == null || packToBase <= 0
                                        ? 'อัตราแปลง: ยังไม่ตั้ง'
                                        : '1 $packUnit = ${_fmtNumCompact(packToBase)} $baseUnit',
                                  ),
                                ],
                              ),
                            ),

                          const SizedBox(height: 12),

                          LayoutBuilder(
                            builder: (context, c) {
                              final wide = c.maxWidth >= 720;
                              return Wrap(
                                runSpacing: 12,
                                spacing: 12,
                                children: [
                                  SizedBox(
                                    width: wide ? (c.maxWidth - 12) / 2 : c.maxWidth,
                                    child: TextFormField(
                                      controller: lotCtl,
                                      decoration: _dec('เลขล็อต (Lot No.)'),
                                      validator: (v) => (v ?? '').trim().isEmpty
                                          ? 'กรุณากรอกเลขล็อต'
                                          : null,
                                    ),
                                  ),
                                  SizedBox(
                                    width: wide ? (c.maxWidth - 12) / 2 : c.maxWidth,
                                    child: InkWell(
                                      onTap: _pickExpDate,
                                      borderRadius: BorderRadius.circular(12),
                                      child: InputDecorator(
                                        decoration: _dec('วันหมดอายุ (Exp Date)'),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                expDate == null
                                                    ? 'วว/ดด/ปปปป'
                                                    : _fmtDate(expDate!),
                                                style: TextStyle(
                                                  color: expDate == null
                                                      ? Colors.black
                                                          .withOpacity(0.45)
                                                      : Colors.black,
                                                ),
                                              ),
                                            ),
                                            const Icon(
                                                Icons.calendar_month_rounded),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),

                          const SizedBox(height: 12),

                          LayoutBuilder(
                            builder: (context, c) {
                              final wide = c.maxWidth >= 720;
                              final w = wide ? (c.maxWidth - 24) / 3 : c.maxWidth;
                              return Wrap(
                                runSpacing: 12,
                                spacing: 12,
                                children: [
                                  SizedBox(
                                    width: w,
                                    child: TextFormField(
                                      controller: qtyCtl,
                                      keyboardType: TextInputType.number,
                                      decoration:
                                          _dec('จำนวนที่รับเข้า ($unitLabel)'),
                                      validator: (v) {
                                        final n = int.tryParse((v ?? '').trim());
                                        if (n == null || n <= 0) {
                                          return 'กรุณากรอกจำนวนเป็นเลข > 0';
                                        }
                                        return null;
                                      },
                                    ),
                                  ),
                                  SizedBox(
                                    width: w,
                                    child: DropdownButtonFormField<bool>(
                                      value: isPackInput,
                                      decoration: _dec('หน่วยที่รับเข้า'),
                                      items: [
                                        DropdownMenuItem(
                                            value: false,
                                            child: Text('$baseUnit (หน่วยฐาน)')),
                                        DropdownMenuItem(
                                            value: true,
                                            child: Text('$packUnit (หน่วยบรรจุ)')),
                                      ],
                                      onChanged: (v) =>
                                          setState(() => isPackInput = v ?? false),
                                    ),
                                  ),
                                  SizedBox(
                                    width: w,
                                    child: InputDecorator(
                                      decoration: _dec('ระบบแปลงเป็นหน่วยฐานให้'),
                                      child: Text(
                                        isPackInput
                                            ? 'pack_to_base: ${packToBase ?? '-'} → ฐาน: $baseUnit'
                                            : 'to_base: 1 → ฐาน: $baseUnit',
                                        style: TextStyle(
                                            color: Colors.black.withOpacity(0.70)),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),

                          const SizedBox(height: 12),

                          InputDecorator(
                            decoration: _dec('ราคาอิงจาก'),
                            child: SegmentedButton<_PriceInputMode>(
                              segments: [
                                ButtonSegment<_PriceInputMode>(
                                  value: _PriceInputMode.base,
                                  label: Text('หน่วยฐาน ($baseUnit)'),
                                  icon: const Icon(Icons.calculate_rounded),
                                ),
                                ButtonSegment<_PriceInputMode>(
                                  value: _PriceInputMode.pack,
                                  label: Text('หน่วยบรรจุ ($packUnit)'),
                                  icon: const Icon(Icons.inventory_2_rounded),
                                ),
                              ],
                              selected: {_priceInputMode},
                              onSelectionChanged: (v) {
                                if (v.isEmpty) return;
                                setState(() => _priceInputMode = v.first);
                              },
                            ),
                          ),

                          const SizedBox(height: 12),

                          LayoutBuilder(
                            builder: (context, c) {
                              final wide = c.maxWidth >= 720;
                              return Wrap(
                                runSpacing: 12,
                                spacing: 12,
                                children: [
                                  SizedBox(
                                    width: wide ? (c.maxWidth - 12) / 2 : c.maxWidth,
                                    child: TextFormField(
                                      controller: costPerBaseCtl,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                              decimal: true),
                                      decoration: _dec(
                                        _priceInputMode == _PriceInputMode.base
                                            ? 'ราคาทุน/หน่วยฐาน (บาท/$baseUnit)'
                                            : 'ราคาทุน/หน่วยบรรจุ (บาท/$packUnit)',
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: wide ? (c.maxWidth - 12) / 2 : c.maxWidth,
                                    child: TextFormField(
                                      controller: sellPerBaseCtl,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                              decimal: true),
                                      decoration: _dec(
                                        _priceInputMode == _PriceInputMode.base
                                            ? 'ราคาขาย/หน่วยฐาน (บาท/$baseUnit)'
                                            : 'ราคาขาย/หน่วยบรรจุ (บาท/$packUnit)',
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),

                          const SizedBox(height: 12),

                          if (_priceInputMode == _PriceInputMode.pack &&
                              (packToBase == null || packToBase <= 0))
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.red.withOpacity(0.08),
                                borderRadius: BorderRadius.circular(12),
                                border:
                                    Border.all(color: Colors.red.withOpacity(0.22)),
                              ),
                              child: const Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(Icons.error_outline_rounded,
                                      color: Colors.red),
                                  SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'ยานี้ยังไม่ได้ตั้งค่าหน่วยบรรจุ/pack_to_base จึงยังไม่สามารถกรอกราคาแบบหน่วยบรรจุได้',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: Colors.red,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.green.withOpacity(0.08),
                                borderRadius: BorderRadius.circular(12),
                                border:
                                    Border.all(color: Colors.green.withOpacity(0.22)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Preview ราคาที่จะเก็บจริง',
                                    style: TextStyle(fontWeight: FontWeight.w800),
                                  ),
                                  const SizedBox(height: 8),
                                  if (_priceInputMode == _PriceInputMode.pack &&
                                      packToBase != null &&
                                      packToBase > 0)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 6),
                                      child: Text(
                                        'อัตราแปลง: 1 $packUnit = ${_fmtNumCompact(packToBase)} $baseUnit',
                                        style: TextStyle(
                                          color: Colors.black.withOpacity(0.70),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  Text(
                                    'ทุนต่อหน่วยฐาน: ${priceResult.costPerBase == null ? '-' : '${_fmtMoney(priceResult.costPerBase!, digits: 4)} บาท / $baseUnit'}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'ขายต่อหน่วยฐาน: ${priceResult.sellPerBase == null ? '-' : '${_fmtMoney(priceResult.sellPerBase!, digits: 4)} บาท / $baseUnit'}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 6),
                                  /*Text(
                                    'ระบบจะบันทึกลงฐานข้อมูลเป็น cost_per_base และ sell_per_base',
                                    style: TextStyle(
                                      color: Colors.black.withOpacity(0.60),
                                    ),
                                  ),*/
                                ],
                              ),
                            ),

                          const SizedBox(height: 14),

                          Row(
                            children: [
                              Expanded(
                                child: SizedBox(
                                  height: 52,
                                  child: FilledButton.icon(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: cs.primary,
                                      elevation: 2,
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(14)),
                                    ),
                                    onPressed: saving ? null : _addOrUpdateItem,
                                    icon: Icon(editingIndex == null
                                        ? Icons.add_rounded
                                        : Icons.save_rounded),
                                    label: Text(editingIndex == null
                                        ? 'เพิ่มรายการ'
                                        : 'อัปเดตรายการ'),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              SizedBox(
                                height: 52,
                                child: OutlinedButton.icon(
                                  onPressed: saving
                                      ? null
                                      : () => setState(_resetItemDraft),
                                  icon: const Icon(Icons.refresh_rounded),
                                  label: const Text('ล้าง'),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 14),

                // ===== Cart / Items =====
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: Colors.black.withOpacity(0.06)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: cs.primary.withOpacity(0.10),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                    color: cs.primary.withOpacity(0.25)),
                              ),
                              child: Text(
                                'ตะกร้า: ${items.length} รายการ',
                                style: TextStyle(
                                    fontWeight: FontWeight.w700, color: cs.primary),
                              ),
                            ),
                            const Spacer(),
                            TextButton.icon(
                              onPressed: items.isEmpty
                                  ? null
                                  : () {
                                      setState(() {
                                        items.clear();
                                        _resetItemDraft();
                                      });
                                    },
                              icon: const Icon(Icons.delete_sweep_rounded),
                              label: const Text('ล้างตะกร้า'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        if (items.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            child: Text('ตะกร้าว่าง — เพิ่มรายการก่อน',
                                style: TextStyle(
                                    color: Colors.black.withOpacity(0.55))),
                          )
                        else
                          Column(
                            children: [
                              for (int i = 0; i < items.length; i++)
                                _ItemTile(
                                  index: i,
                                  item: items[i],
                                  onEdit: () => _startEditItem(i),
                                  onDelete: () => _removeItem(i),
                                ),
                            ],
                          ),
                        const SizedBox(height: 14),
                        SizedBox(
                          height: 56,
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: saving ? null : _onSavePressed,
                            icon: saving
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.check_rounded),
                            label: const Text('บันทึกรับยาเข้า (ทั้งหมด)'),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            const Icon(Icons.lightbulb_outline_rounded, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Tip: ถ้ามียาหลายรายการจาก Supplier เดียวกัน ให้กรอกเอกสารครั้งเดียว แล้วเพิ่มรายการรับยาเข้าเรื่อย ๆ',
                                style: TextStyle(
                                    color: Colors.black.withOpacity(0.55)),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _fmtNumCompact(num v) {
    if (v % 1 == 0) return v.toInt().toString();
    return v.toStringAsFixed(2);
  }

  Widget _infoChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.black.withOpacity(0.08)),
      ),
      child: Text(
        text,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
    );
  }
}

enum _InputUnitKind { base, pack }

enum _DuplicateDecision { merge, editExisting, cancel }

enum _PriceInputMode { base, pack }

class _ComputedPriceResult {
  final bool ok;
  final String baseUnitName;
  final String priceRefUnitName;
  final String packUnitName;
  final double? packToBase;
  final double? costInputValue;
  final double? sellInputValue;
  final double? costPerBase;
  final double? sellPerBase;
  final String? errorMessage;

  const _ComputedPriceResult({
    required this.ok,
    required this.baseUnitName,
    required this.priceRefUnitName,
    required this.packUnitName,
    required this.packToBase,
    this.costInputValue,
    this.sellInputValue,
    this.costPerBase,
    this.sellPerBase,
    this.errorMessage,
  });
}

class _StockInItemDraft {
  final String drugId;
  final String drugName;
  final String drugCode;

  final String lotNo;
  final DateTime expDate;

  final int inputQty;
  final String inputUnitName;
  final _InputUnitKind inputUnitKind;

  final double toBase;
  final double baseQty;

  final double? costInputValue;
  final double? sellInputValue;
  final _PriceInputMode priceInputMode;

  final double? costPerBase;
  final double? sellPerBase;

  final String baseUnitName;
  final String packUnitNameForPrice;

  _StockInItemDraft({
    required this.drugId,
    required this.drugName,
    required this.drugCode,
    required this.lotNo,
    required this.expDate,
    required this.inputQty,
    required this.inputUnitName,
    required this.inputUnitKind,
    required this.toBase,
    required this.baseQty,
    required this.costInputValue,
    required this.sellInputValue,
    required this.priceInputMode,
    required this.costPerBase,
    required this.sellPerBase,
    required this.baseUnitName,
    required this.packUnitNameForPrice,
  });

  _StockInItemDraft copyWith({
    String? drugId,
    String? drugName,
    String? drugCode,
    String? lotNo,
    DateTime? expDate,
    int? inputQty,
    String? inputUnitName,
    _InputUnitKind? inputUnitKind,
    double? toBase,
    double? baseQty,
    double? costInputValue,
    double? sellInputValue,
    _PriceInputMode? priceInputMode,
    double? costPerBase,
    double? sellPerBase,
    String? baseUnitName,
    String? packUnitNameForPrice,
    bool clearCostInputValue = false,
    bool clearSellInputValue = false,
    bool clearCostPerBase = false,
    bool clearSellPerBase = false,
  }) {
    return _StockInItemDraft(
      drugId: drugId ?? this.drugId,
      drugName: drugName ?? this.drugName,
      drugCode: drugCode ?? this.drugCode,
      lotNo: lotNo ?? this.lotNo,
      expDate: expDate ?? this.expDate,
      inputQty: inputQty ?? this.inputQty,
      inputUnitName: inputUnitName ?? this.inputUnitName,
      inputUnitKind: inputUnitKind ?? this.inputUnitKind,
      toBase: toBase ?? this.toBase,
      baseQty: baseQty ?? this.baseQty,
      costInputValue: clearCostInputValue
          ? null
          : (costInputValue ?? this.costInputValue),
      sellInputValue: clearSellInputValue
          ? null
          : (sellInputValue ?? this.sellInputValue),
      priceInputMode: priceInputMode ?? this.priceInputMode,
      costPerBase:
          clearCostPerBase ? null : (costPerBase ?? this.costPerBase),
      sellPerBase:
          clearSellPerBase ? null : (sellPerBase ?? this.sellPerBase),
      baseUnitName: baseUnitName ?? this.baseUnitName,
      packUnitNameForPrice: packUnitNameForPrice ?? this.packUnitNameForPrice,
    );
  }
}

class _ItemTile extends StatelessWidget {
  final int index;
  final _StockInItemDraft item;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _ItemTile({
    required this.index,
    required this.item,
    required this.onEdit,
    required this.onDelete,
  });

  String _fmtDate(DateTime d) {
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }

  String _fmtNum(num v, {int digits = 2}) {
    if (digits == 0) return v.toStringAsFixed(0);
    return v.toStringAsFixed(digits);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final priceModeLabel =
        item.priceInputMode == _PriceInputMode.base ? item.baseUnitName : item.packUnitNameForPrice;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.black.withOpacity(0.08)),
        color: Colors.white,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: cs.primary.withOpacity(0.10),
            child: Text(
              '${index + 1}',
              style: TextStyle(fontWeight: FontWeight.w800, color: cs.primary),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${item.drugName} (${item.drugCode})',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  children: [
                    _pill('Lot: ${item.lotNo}'),
                    _pill('EXP: ${_fmtDate(item.expDate)}'),
                    _pill('รับเข้า: ${item.inputQty} ${item.inputUnitName}'),
                    _pill('ฐาน: ${item.baseQty.toStringAsFixed(2)} ${item.baseUnitName}'),
                  ],
                ),
                const SizedBox(height: 8),
                if (item.costInputValue != null || item.sellInputValue != null)
                  Wrap(
                    spacing: 12,
                    runSpacing: 6,
                    children: [
                      if (item.costInputValue != null)
                        _sub(
                          'ทุนที่กรอก: ${_fmtNum(item.costInputValue!)} / $priceModeLabel',
                        ),
                      if (item.sellInputValue != null)
                        _sub(
                          'ขายที่กรอก: ${_fmtNum(item.sellInputValue!)} / $priceModeLabel',
                        ),
                    ],
                  ),
                if (item.costPerBase != null || item.sellPerBase != null) ...[
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 12,
                    runSpacing: 6,
                    children: [
                      if (item.costPerBase != null)
                        _sub('ทุน/ฐาน: ${_fmtNum(item.costPerBase!, digits: 4)}'),
                      if (item.sellPerBase != null)
                        _sub('ขาย/ฐาน: ${_fmtNum(item.sellPerBase!, digits: 4)}'),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            children: [
              IconButton(
                  tooltip: 'แก้ไข',
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_rounded)),
              IconButton(
                  tooltip: 'ลบ',
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_rounded)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pill(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.04),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.black.withOpacity(0.06)),
      ),
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
    );
  }

  Widget _sub(String text) {
    return Text(
      text,
      style: TextStyle(
          color: Colors.black.withOpacity(0.65), fontWeight: FontWeight.w600),
    );
  }
}