import 'package:supabase_flutter/supabase_flutter.dart';

class DrugsRepository {
  final SupabaseClient client;
  DrugsRepository(this.client);

  String get _requireUid {
    final uid = client.auth.currentUser?.id;
    if (uid == null) throw Exception('User not signed in');
    return uid;
  }

  String? get _uid => client.auth.currentUser?.id;

  String _dateOnly(DateTime d) => d.toIso8601String().substring(0, 10);

  String? _nullIfEmpty(String? s) {
    final t = (s ?? '').trim();
    return t.isEmpty ? null : t;
  }

  // ===============================
  // เพิ่มยา + หน่วยจ่าย (รองรับ is_active)
  // ===============================
  Future<String> addDrugWithUnits({
    String? code,
    required String genericName,
    String? brandName,
    String? dosageForm,
    String? strength,
    required String baseUnit,
    String? packUnit,
    num? packToBase,
    String? exampleText,
    String? autoDispenseLabel,
    String? category,
    String? manufacturer,
    required String status, // 'active'|'inactive'
    num reorderPoint = 0,
    int expiryAlertDays = 90,
    required List<DispenseUnitInput> units,
  }) async {
    final uid = _requireUid;

    final normalizedUnits = _normalizeUnits(units, baseUnit.trim());

    final drugInsert = <String, dynamic>{
      'owner_id': uid,
      if (_nullIfEmpty(code) != null) 'code': _nullIfEmpty(code),

      'generic_name': genericName.trim(),
      'brand_name': _nullIfEmpty(brandName),
      'dosage_form': _nullIfEmpty(dosageForm),
      'strength': _nullIfEmpty(strength),

      'base_unit': baseUnit.trim(),
      'pack_unit': _nullIfEmpty(packUnit),
      if (packToBase != null && packToBase > 0) 'pack_to_base': packToBase,

      'example_text': _nullIfEmpty(exampleText),
      'auto_dispense_label': _nullIfEmpty(autoDispenseLabel),

      'category': _nullIfEmpty(category),
      'manufacturer': _nullIfEmpty(manufacturer),

      'status': status,
      'is_active': status == 'active',
      'reorder_point': reorderPoint,

      // ใช้ field นี้ตาม schema ที่เธอใช้จริง
      'expire_warn_days': expiryAlertDays,
    };

    final drugRow =
        await client.from('drugs').insert(drugInsert).select('id, code').single();

    final drugId = (drugRow['id'] ?? '').toString();

    final unitsPayload = normalizedUnits.map((u) {
      return {
        'owner_id': uid,
        'drug_id': drugId,
        'unit_name': u.unitName.trim(),
        'to_base': u.toBase,
        'is_default': u.isDefault,
        'is_active': u.isActive,
      };
    }).toList();

    await client.from('drug_dispense_units').insert(unitsPayload);

    return drugId;
  }

  List<DispenseUnitInput> _normalizeUnits(
    List<DispenseUnitInput> units,
    String baseUnit,
  ) {
    var u = units;

    // ต้องมีอย่างน้อย 1 หน่วย
    if (u.isEmpty) {
      u = [
        DispenseUnitInput(
          unitName: baseUnit,
          toBase: 1,
          isDefault: true,
          isActive: true,
        )
      ];
    }

    // ต้องมี default 1 ตัว
    final hasDefault = u.any((x) => x.isDefault);
    if (!hasDefault) {
      u = [
        u.first.copyWith(isDefault: true),
        ...u.skip(1).map((x) => x.copyWith(isDefault: false)),
      ];
    } else {
      bool used = false;
      u = u.map((x) {
        if (x.isDefault) {
          if (!used) {
            used = true;
            return x.copyWith(isDefault: true);
          }
          return x.copyWith(isDefault: false);
        }
        return x.copyWith(isDefault: false);
      }).toList();
    }

    // base unit ต้อง active เสมอ + to_base = 1
    u = u.map((x) {
      if (x.unitName.trim().toLowerCase() == baseUnit.toLowerCase()) {
        return x.copyWith(isActive: true, toBase: 1);
      }
      return x;
    }).toList();

    // default ต้อง active เสมอ
    final idxDefault = u.indexWhere((x) => x.isDefault);
    if (idxDefault >= 0 && !u[idxDefault].isActive) {
      u[idxDefault] = u[idxDefault].copyWith(isActive: true);
    }

    // กันซ้ำ unit_name (case-insensitive) — เก็บตัวแรก
    final seen = <String>{};
    final out = <DispenseUnitInput>[];
    for (final x in u) {
      final k = x.unitName.trim().toLowerCase();
      if (k.isEmpty) continue;
      if (seen.add(k)) out.add(x);
    }

    // ถ้าหลังกรองเหลือว่าง → คืน base unit
    if (out.isEmpty) {
      return [
        DispenseUnitInput(
          unitName: baseUnit,
          toBase: 1,
          isDefault: true,
          isActive: true,
        )
      ];
    }

    return out;
  }

  // ===============================
  // ดึงรายการยา
  // ===============================
  Future<List<Map<String, dynamic>>> listDrugs() async {
    final uid = _uid;
    if (uid == null) return [];

    final res = await client
        .from('drugs')
        .select()
        .eq('owner_id', uid)
        .order('generic_name', ascending: true);

    return List<Map<String, dynamic>>.from(res);
  }

  Future<Map<String, dynamic>?> getDrugById(String drugId) async {
    final uid = _uid;
    if (uid == null) return null;

    final row = await client
        .from('drugs')
        .select()
        .eq('owner_id', uid)
        .eq('id', drugId)
        .maybeSingle();

    return row == null ? null : Map<String, dynamic>.from(row);
  }

  // ===============================
  // ดึงหน่วยจ่ายของยา
  // ===============================
  Future<List<Map<String, dynamic>>> listDispenseUnits(
    String drugId, {
    bool onlyActive = false,
  }) async {
    final uid = _uid;
    if (uid == null) return [];

    var q = client
        .from('drug_dispense_units')
        .select('id, unit_name, to_base, is_default, is_active')
        .eq('owner_id', uid)
        .eq('drug_id', drugId);

    if (onlyActive) {
      q = q.eq('is_active', true);
    }

    final res = await q
        .order('is_default', ascending: false)
        .order('to_base', ascending: true);

    return List<Map<String, dynamic>>.from(res);
  }

  // ===============================
  // ลบยา (ปลอดภัย) ✅ ใช้ RPC: เช็คสต็อก + ประวัติ
  // ===============================
  Future<void> deleteDrug(String id) async {
    _requireUid; // ensure signed in
    await client.rpc('delete_drug_safe', params: {'p_drug_id': id});
  }

  // ===============================
  // ปิด/เปิดการใช้งานยา (แนะนำเมื่อ "ลบไม่ได้")
  // ===============================
  Future<void> setDrugActive(String drugId, bool active) async {
    final uid = _requireUid;

    await client
        .from('drugs')
        .update({
          'is_active': active,
          'status': active ? 'active' : 'inactive',
          'updated_at': DateTime.now().toIso8601String(),
        })
        .eq('owner_id', uid)
        .eq('id', drugId);
  }

  // ===============================
  // STOCK IN (เดี่ยว) ✅ FIX: ใช้ qty_on_hand_base เป็นหลัก
  // ===============================
  Future<void> stockIn({
    required String drugId,
    required String lotNo,
    required DateTime expDate,
    required num inputQty,
    required bool isPackInput,
  }) async {
    final uid = _requireUid;

    final lot = lotNo.trim();
    if (lot.isEmpty) throw Exception('Lot No. ว่างไม่ได้');
    if (inputQty <= 0) throw Exception('จำนวนรับเข้าต้องมากกว่า 0');

    final drug = await client
        .from('drugs')
        .select('pack_to_base')
        .eq('owner_id', uid)
        .eq('id', drugId)
        .single();

    final packToBase = (drug['pack_to_base'] as num?)?.toDouble();

    if (isPackInput) {
      if (packToBase == null || packToBase <= 0) {
        throw Exception('ยานี้ยังไม่มี pack_to_base ที่ถูกต้อง');
      }
    }

    final baseQty = isPackInput ? (inputQty * (packToBase ?? 1)) : inputQty;
    final exp = _dateOnly(expDate);

    final existing = await client
        .from('drug_lots')
        .select('id, qty_on_hand_base')
        .eq('owner_id', uid)
        .eq('drug_id', drugId)
        .eq('lot_no', lot)
        .eq('exp_date', exp)
        .maybeSingle();

    if (existing != null) {
      final newQty = (existing['qty_on_hand_base'] as num) + baseQty;
      await client.from('drug_lots').update({
        'qty_on_hand_base': newQty,
        'qty_on_hand': newQty, // sync legacy
      }).eq('id', existing['id']);
    } else {
      await client.from('drug_lots').insert({
        'owner_id': uid,
        'drug_id': drugId,
        'lot_no': lot,
        'exp_date': exp,
        'qty_on_hand_base': baseQty,
        'qty_on_hand': baseQty, // sync legacy
      });
    }
  }

  // ===============================
  // STOCK IN (หลายรายการ) ✅ FIX: อัปเดต qty_on_hand_base ด้วย
  // ===============================
  Future<String> commitStockIn({
    required StockInHeaderInput header,
    required List<StockInLineInput> lines,
  }) async {
    final uid = _requireUid;
    if (lines.isEmpty) throw Exception('ไม่มีรายการในตะกร้า');

    for (final l in lines) {
      if (l.lotNo.trim().isEmpty) throw Exception('มีรายการที่ Lot No. ว่าง');
      if (l.inputQty <= 0) throw Exception('มีรายการที่จำนวนรับเข้าไม่ถูกต้อง');
      if (l.toBase <= 0) throw Exception('มีรายการที่ toBase ไม่ถูกต้อง');
      if (l.baseQty <= 0) throw Exception('มีรายการที่ baseQty ไม่ถูกต้อง');
      if (l.inputUnit.trim().isEmpty) throw Exception('มีรายการที่ inputUnit ว่าง');
    }

    final receipt = await client.from('stock_in_receipts').insert({
      'owner_id': uid,
      'supplier_name': _nullIfEmpty(header.supplierName),
      'delivery_note_no': _nullIfEmpty(header.deliveryNoteNo),
      'invoice_no': _nullIfEmpty(header.invoiceNo),
      'po_no': _nullIfEmpty(header.poNo),
      'note': _nullIfEmpty(header.note),
      'received_at': header.receivedAt.toIso8601String(),
    }).select('id').single();

    final receiptId = (receipt['id'] ?? '').toString();

    final itemsPayload = lines.map((l) {
      final exp = _dateOnly(l.expDate);
      return {
        'owner_id': uid,
        'receipt_id': receiptId,
        'drug_id': l.drugId,
        'lot_no': l.lotNo.trim(),
        'exp_date': exp,
        'input_qty': l.inputQty,
        'input_unit': l.inputUnit.trim(),
        'to_base': l.toBase,
        'base_qty': l.baseQty,
        'cost_per_base': l.costPerBase,
        'sell_per_base': l.sellPerBase,
      };
    }).toList();

    await client.from('stock_in_items').insert(itemsPayload);

    // ✅ update lots
    for (final l in lines) {
      final exp = _dateOnly(l.expDate);
      final lot = l.lotNo.trim();

      final existing = await client
          .from('drug_lots')
          .select('id, qty_on_hand_base')
          .eq('owner_id', uid)
          .eq('drug_id', l.drugId)
          .eq('lot_no', lot)
          .eq('exp_date', exp)
          .maybeSingle();

      if (existing != null) {
        final newQty = (existing['qty_on_hand_base'] as num) + l.baseQty;
        await client.from('drug_lots').update({
          'qty_on_hand_base': newQty,
          'qty_on_hand': newQty,
        }).eq('id', existing['id']);
      } else {
        await client.from('drug_lots').insert({
          'owner_id': uid,
          'drug_id': l.drugId,
          'lot_no': lot,
          'exp_date': exp,
          'qty_on_hand_base': l.baseQty,
          'qty_on_hand': l.baseQty,
        });
      }
    }

    return receiptId;
  }

  Future<List<Map<String, dynamic>>> listDrugLots(String drugId) async {
    final uid = _uid;
    if (uid == null) return [];

    final res = await client
        .from('drug_lots')
        .select('id, drug_id, lot_no, exp_date, qty_on_hand_base, qty_on_hand')
        .eq('owner_id', uid)
        .eq('drug_id', drugId)
        .order('exp_date', ascending: true);

    return List<Map<String, dynamic>>.from(res);
  }

  Future<List<Map<String, dynamic>>> listDrugStockSummary() async {
    final uid = _uid;
    if (uid == null) return [];

    final res = await client
        .from('v_drug_stock_summary')
        .select('drug_id, on_hand_base, lot_count')
        .eq('owner_id', uid);

    return List<Map<String, dynamic>>.from(res);
  }

  Future<List<Map<String, dynamic>>> listDrugLotsAllFromView() async {
    final uid = _uid;
    if (uid == null) return [];

    final res = await client
        .from('v_drug_lots')
        .select('drug_id, lot_no, exp_date, lot_on_hand_base')
        .eq('owner_id', uid)
        .order('exp_date', ascending: true);

    return List<Map<String, dynamic>>.from(res);
  }

  // ===============================
  // แก้ไขยา + หน่วยจ่าย (Replace units) ✅ FIX: ใส่ is_active ตอน insert
  // ===============================
  Future<void> updateDrugWithUnits({
    required String drugId,
    String? code,
    required String genericName,
    String? brandName,
    String? dosageForm,
    String? strength,
    required String baseUnit,
    String? packUnit,
    num? packToBase,
    String? exampleText,
    String? autoDispenseLabel,
    String? category,
    String? manufacturer,
    /*String? barcode,*/
    required String status,
    num reorderPoint = 0,
    int expiryAlertDays = 90,
    required List<DispenseUnitInput> units,
  }) async {
    final uid = _requireUid;

    final normalizedUnits = _normalizeUnits(units, baseUnit.trim());

    final updatePayload = <String, dynamic>{
      if (_nullIfEmpty(code) != null) 'code': _nullIfEmpty(code),

      'generic_name': genericName.trim(),
      'brand_name': _nullIfEmpty(brandName),
      'dosage_form': _nullIfEmpty(dosageForm),
      'strength': _nullIfEmpty(strength),

      'base_unit': baseUnit.trim(),
      'pack_unit': _nullIfEmpty(packUnit),
      'pack_to_base': (packToBase != null && packToBase > 0) ? packToBase : null,

      'example_text': _nullIfEmpty(exampleText),
      'auto_dispense_label': _nullIfEmpty(autoDispenseLabel),

      'category': _nullIfEmpty(category),
      'manufacturer': _nullIfEmpty(manufacturer),

      /*'barcode': _nullIfEmpty(barcode),*/

      'status': status,
      'is_active': status == 'active',
      'reorder_point': reorderPoint,
      'expire_warn_days': expiryAlertDays,
    };

    await client
        .from('drugs')
        .update(updatePayload)
        .eq('owner_id', uid)
        .eq('id', drugId);

    await client
        .from('drug_dispense_units')
        .delete()
        .eq('owner_id', uid)
        .eq('drug_id', drugId);

    final unitsPayload = normalizedUnits.map((u) {
      return {
        'owner_id': uid,
        'drug_id': drugId,
        'unit_name': u.unitName.trim(),
        'to_base': u.toBase,
        'is_default': u.isDefault,
        'is_active': u.isActive,
      };
    }).toList();

    await client.from('drug_dispense_units').insert(unitsPayload);
  }
}

// ===============================
// INPUT MODELS
// ===============================

class DispenseUnitInput {
  final String unitName;
  final num toBase;
  final bool isDefault;
  final bool isActive;

  const DispenseUnitInput({
    required this.unitName,
    required this.toBase,
    required this.isDefault,
    this.isActive = true,
  });

  DispenseUnitInput copyWith({
    String? unitName,
    num? toBase,
    bool? isDefault,
    bool? isActive,
  }) {
    return DispenseUnitInput(
      unitName: unitName ?? this.unitName,
      toBase: toBase ?? this.toBase,
      isDefault: isDefault ?? this.isDefault,
      isActive: isActive ?? this.isActive,
    );
  }
}

class StockInHeaderInput {
  final String? supplierName;
  final String? deliveryNoteNo;
  final String? invoiceNo;
  final String? poNo;
  final String? note;
  final DateTime receivedAt;

  StockInHeaderInput({
    required this.receivedAt,
    this.supplierName,
    this.deliveryNoteNo,
    this.invoiceNo,
    this.poNo,
    this.note,
  });
}

class StockInLineInput {
  final String drugId;
  final String lotNo;
  final DateTime expDate;

  final num inputQty;
  final String inputUnit;
  final num toBase;
  final num baseQty;

  final num? costPerBase;
  final num? sellPerBase;

  StockInLineInput({
    required this.drugId,
    required this.lotNo,
    required this.expDate,
    required this.inputQty,
    required this.inputUnit,
    required this.toBase,
    required this.baseQty,
    this.costPerBase,
    this.sellPerBase,
  });
}