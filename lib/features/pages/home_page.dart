import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:phamory/core/theme.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase_guard.dart';
import '../auth/auth_gate.dart';
import 'about_page.dart';
import 'expiry_calendar_page.dart';
import 'profile_page.dart';
import 'security_page.dart';
import 'partners/manufacturers_page.dart';
import 'partners/suppliers_page.dart';
import '../stock/stock_in_page.dart';
import '../stock/stock_out_page.dart';
import 'package:fl_chart/fl_chart.dart';
import 'billing/bills_page.dart';
// ✅ เพิ่ม: หน้าดูรายการยาทั้งหมด (active + inactive)
import 'all_drugs_page.dart';

// ✅ เพิ่ม: หน้า "ผู้ป่วย" (ตามโครงสร้างไฟล์ของคุณ)
import '../../core/patients/patient_home_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  SupabaseClient? _sb;

  bool _loading = true;
  String? _error;

  // ✅ Scroll to sections (keep for future)
  final ScrollController _scrollCtl = ScrollController();
  final GlobalKey _manuKey = GlobalKey();
  final GlobalKey _suppKey = GlobalKey();

  // ===== Profile header =====
  String? _shopName;
  String? _displayName;
  String? _logoUrl;

  // ===== Dashboard numbers =====
  int _drugCount = 0;
  int _lotCount = 0;

  int _expiredCount = 0;
  int _nearExpireCount = 0;
  int _lowStockCount = 0;
  int _outStockCount = 0;

  num _onHandBaseTotal = 0;

  Map<String, num> _onHandByBaseUnit = {};

  // ===== Financial =====
  int _days = 30;
  num _sales = 0;
  num _costEst = 0;
  num _profitEst = 0;

  // ===== Chart / Top =====
  List<_ChartPoint> _salesSeries = [];
  List<_TopDrug> _top5 = [];

  int _topMode = 0; // 0=daily, 1=monthly
  List<_TopDrug> _top10Daily = [];
  List<_TopDrug> _top10Monthly = [];

  // ===== Manufacturers & Suppliers =====
  List<Map<String, dynamic>> _manufacturers = [];
  List<Map<String, dynamic>> _suppliers = [];

  final TextEditingController _mSearchCtl = TextEditingController();
  final TextEditingController _sSearchCtl = TextEditingController();
  String _mQ = '';
  String _sQ = '';

  // ===== Alert details =====
  bool _loadingAlerts = false;
  List<_DrugAlertGroup> _expiredGroups = [];
  List<_DrugAlertGroup> _nearExpireGroups = [];
  List<_DrugAlertGroup> _lowStockGroups = [];
  List<_DrugAlertGroup> _outStockGroups = [];


  // ===== Color =====
  static const Color _inColor = Color(0xFF16A34A); // ✅ Green
  static const Color _outColor = Color(0xFFEF4444); // ✅ Red
  static const Color _brandBlue = Color(0xFF2158B6);

  @override
  void initState() {
    super.initState();
    _sb = getSupabaseClientOrNull();
    if (_sb == null) {
      setState(() {
        _loading = false;
        _error = 'ยังไม่ได้ตั้งค่า Supabase หรือยังไม่ได้ล็อกอิน';
      });
      return;
    }

    _mSearchCtl.addListener(() {
      setState(() => _mQ = _mSearchCtl.text.trim().toLowerCase());
    });
    _sSearchCtl.addListener(() {
      setState(() => _sQ = _sSearchCtl.text.trim().toLowerCase());
    });

    _bootstrap();
  }

  @override
  void dispose() {
    _mSearchCtl.dispose();
    _sSearchCtl.dispose();
    _scrollCtl.dispose();
    super.dispose();
  }

  String _ownerId() {
    final u = _sb!.auth.currentUser;
    if (u == null) throw Exception('ยังไม่ได้ล็อกอิน');
    return u.id;
  }

  // =========================
  // Profile header (logo/name)
  // =========================
  Future<void> _loadProfileHeader() async {
    final sb = _sb!;
    final uid = _ownerId();

    try {
      final row = await sb
          .from('profiles')
          .select('shop_name, display_name, logo_url')
          .eq('id', uid)
          .maybeSingle();

      _shopName = (row?['shop_name'] ?? '').toString().trim();
      _displayName = (row?['display_name'] ?? '').toString().trim();
      _logoUrl = (row?['logo_url'] ?? '').toString().trim();

      if ((_shopName ?? '').isEmpty) _shopName = null;
      if ((_displayName ?? '').isEmpty) _displayName = null;
      if ((_logoUrl ?? '').isEmpty) _logoUrl = null;
    } catch (_) {
      _shopName = null;
      _displayName = null;
      _logoUrl = null;
    }
  }

  ImageProvider? _homeLogoProvider() {
    final url = (_logoUrl ?? '').trim();
    if (url.isEmpty) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.isAbsolute) return null;
    return NetworkImage(url);
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await Future.wait([
        _loadProfileHeader(),
        _loadInventoryStats(),
        _loadFinance(days: _days),
        _loadSalesSeries(days: _days),
        _loadTopSellers(days: _days),
        _loadTop10Daily(),
        _loadTop10Monthly(),
        _loadManufacturers(),
        _loadSuppliers(),
        _loadAlertDetails(),
      ]);
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // =========================
  // Inventory / Finance
  // =========================
  Future<void> _loadInventoryStats() async {
    final sb = _sb!;
    final ownerId = _ownerId();

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final todayStr = _dateOnly(today);

    // count drugs
    final drugsRows = await sb.from('drugs').select('id').eq('owner_id', ownerId);
    _drugCount = (drugsRows as List).length;

    // lots (only count lots with qty>0)
    final lotsRows = await sb
        .from('drug_lots')
        .select('id, exp_date, qty_on_hand_base')
        .eq('owner_id', ownerId);

    int lotCount = 0;
    int expired = 0;
    int nearExpire = 0;
    num onHandTotal = 0;

    for (final r in (lotsRows as List)) {
      final qty = (r['qty_on_hand_base'] as num?) ?? 0;
      if (qty <= 0) continue;

      lotCount++;
      onHandTotal += qty;

      final exp = (r['exp_date'] ?? '').toString();
      if (exp.compareTo(todayStr) < 0) {
        expired++;
      } else {
        final diff = _daysBetween(today, _parseDate(exp));
        if (diff >= 0 && diff <= 90) nearExpire++;
      }
    }

    _lotCount = lotCount;
    _expiredCount = expired;
    _nearExpireCount = nearExpire;
    _onHandBaseTotal = onHandTotal;

    try {
      final sumRows = await sb
          .from('v_drug_stock_summary')
          .select('drug_id, on_hand_base, stock_status')
          .eq('owner_id', ownerId);

      final onHandMap = <String, num>{};
      int low = 0;
      int out = 0;

      for (final r in (sumRows as List)) {
        final id = (r['drug_id'] ?? '').toString();
        if (id.isEmpty) continue;

        final onHand = (r['on_hand_base'] as num?) ?? 0;
        onHandMap[id] = onHand;

        final st = (r['stock_status'] ?? '').toString();
        if (st == 'low') low++;
        if (st == 'out') out++;
      }

      final drugRows =
          await sb.from('drugs').select('id, base_unit').eq('owner_id', ownerId);

      final byUnit = <String, num>{};
      for (final d in (drugRows as List)) {
        final id = (d['id'] ?? '').toString();
        if (id.isEmpty) continue;

        final unit = (d['base_unit'] ?? '').toString().trim();
        if (unit.isEmpty) continue;

        final qty = onHandMap[id] ?? 0;
        byUnit[unit] = (byUnit[unit] ?? 0) + qty;
      }

      _lowStockCount = low;
      _outStockCount = out;
      _onHandByBaseUnit = byUnit;
    } catch (_) {
      _lowStockCount = 0;
      _outStockCount = 0;
      _onHandByBaseUnit = {};
    }
  }

  Future<void> _loadFinance({required int days}) async {
    final sb = _sb!;
    final ownerId = _ownerId();
    final from = DateTime.now().subtract(Duration(days: days));
    final fromIso = from.toIso8601String();

    num sales = 0;
    try {
      final outRows = await sb
          .from('stock_out_items')
          .select('line_total, created_at')
          .eq('owner_id', ownerId)
          .gte('created_at', fromIso);

      for (final r in (outRows as List)) {
        final v = r['line_total'];
        if (v is num) sales += v;
      }
    } catch (_) {}

    num costEst = 0;

    final costMap = <String, num>{};
    try {
      final inRows = await sb
          .from('stock_in_items')
          .select('drug_id, lot_no, exp_date, cost_per_base, created_at')
          .eq('owner_id', ownerId)
          .not('cost_per_base', 'is', null)
          .order('created_at', ascending: false);

      for (final r in (inRows as List)) {
        final drugId = (r['drug_id'] ?? '').toString();
        final lotNo = (r['lot_no'] ?? '').toString();
        final exp = (r['exp_date'] ?? '').toString();
        final c = r['cost_per_base'];
        if (drugId.isEmpty || lotNo.isEmpty || exp.isEmpty) continue;
        if (c is! num) continue;

        final k = '$drugId|$lotNo|$exp';
        costMap.putIfAbsent(k, () => c);
      }
    } catch (_) {}

    try {
      final soldRows = await sb
          .from('stock_out_items')
          .select('drug_id, lot_no, exp_date, qty_base, created_at')
          .eq('owner_id', ownerId)
          .gte('created_at', fromIso);

      for (final r in (soldRows as List)) {
        final drugId = (r['drug_id'] ?? '').toString();
        final lotNo = (r['lot_no'] ?? '').toString();
        final exp = (r['exp_date'] ?? '').toString();
        final qty = (r['qty_base'] as num?) ?? 0;
        if (qty <= 0) continue;

        final k = '$drugId|$lotNo|$exp';
        final c = costMap[k];
        if (c != null) costEst += (c * qty);
      }
    } catch (_) {}

    _sales = sales;
    _costEst = costEst;
    _profitEst = _sales - _costEst;
  }

  Future<void> _loadSalesSeries({required int days}) async {
    final sb = _sb!;
    final ownerId = _ownerId();
    final end = DateTime.now();
    final start =
        DateTime(end.year, end.month, end.day).subtract(Duration(days: days - 1));
    final startIso = start.toIso8601String();

    final daySales = <String, num>{};
    for (int i = 0; i < days; i++) {
      final d = start.add(Duration(days: i));
      daySales[_dateOnly(d)] = 0;
    }

    try {
      final rows = await sb
          .from('stock_out_items')
          .select('created_at, line_total')
          .eq('owner_id', ownerId)
          .gte('created_at', startIso);

      for (final r in (rows as List)) {
        final created = (r['created_at'] ?? '').toString();
        if (created.length < 10) continue;
        final dayKey = created.substring(0, 10);
        final lt = r['line_total'];
        if (lt is num && daySales.containsKey(dayKey)) {
          daySales[dayKey] = (daySales[dayKey] ?? 0) + lt;
        }
      }
    } catch (_) {}

    final pts = <_ChartPoint>[];
    final keys = daySales.keys.toList()..sort();
    for (int i = 0; i < keys.length; i++) {
      pts.add(_ChartPoint(
        i.toDouble(),
        (daySales[keys[i]] ?? 0).toDouble(),
        label: keys[i],
      ));
    }

    _salesSeries = pts;
  }

  Future<void> _loadTopSellers({required int days}) async {
    final sb = _sb!;
    final ownerId = _ownerId();
    final from = DateTime.now().subtract(Duration(days: days));
    final fromIso = from.toIso8601String();

    final map = <String, _TopDrugAgg>{};

    try {
      final rows = await sb
          .from('stock_out_items')
          .select(
              'drug_id, qty_base, line_total, created_at, drugs(generic_name, brand_name, base_unit)')
          .eq('owner_id', ownerId)
          .gte('created_at', fromIso);

      for (final r in (rows as List)) {
        final drugId = (r['drug_id'] ?? '').toString();
        if (drugId.isEmpty) continue;

        final qty = (r['qty_base'] as num?) ?? 0;
        final lt = (r['line_total'] as num?) ?? 0;

        final d = (r['drugs'] as Map?) ?? {};
        final g = (d['generic_name'] ?? '-').toString();
        final b = (d['brand_name'] ?? '').toString();
        final unit = (d['base_unit'] ?? '').toString();

        final name = b.trim().isNotEmpty ? '$g ($b)' : g;

        final agg = map.putIfAbsent(
          drugId,
          () => _TopDrugAgg(drugId: drugId, name: name, baseUnit: unit),
        );
        agg.qtyBase += qty;
        agg.sales += lt;
      }
    } catch (_) {}

    final list = map.values.toList()..sort((a, b) => b.sales.compareTo(a.sales));

    _top5 = list.take(5).map((a) {
      return _TopDrug(
        drugId: a.drugId,
        name: a.name,
        baseUnit: a.baseUnit,
        qtyBase: a.qtyBase,
        sales: a.sales,
      );
    }).toList();
  }

  // ✅ Top 10 รายวัน (วันนี้)
  Future<void> _loadTop10Daily() async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final startIso = start.toIso8601String();

    _top10Daily = await _loadTopRange(fromIso: startIso, label: 'daily', limit: 10);
  }

  Future<void> _loadTop10Monthly() async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, 1);
    final startIso = start.toIso8601String();

    _top10Monthly = await _loadTopRange(fromIso: startIso, label: 'monthly', limit: 10);
  }

  Future<List<_TopDrug>> _loadTopRange({
    required String fromIso,
    required String label,
    required int limit,
  }) async {
    final sb = _sb!;
    final ownerId = _ownerId();
    final map = <String, _TopDrugAgg>{};

    try {
      final rows = await sb
          .from('stock_out_items')
          .select(
              'drug_id, qty_base, line_total, created_at, drugs(generic_name, brand_name, base_unit)')
          .eq('owner_id', ownerId)
          .gte('created_at', fromIso);

      for (final r in (rows as List)) {
        final drugId = (r['drug_id'] ?? '').toString();
        if (drugId.isEmpty) continue;

        final qty = (r['qty_base'] as num?) ?? 0;
        final lt = (r['line_total'] as num?) ?? 0;

        final d = (r['drugs'] as Map?) ?? {};
        final g = (d['generic_name'] ?? '-').toString();
        final b = (d['brand_name'] ?? '').toString();
        final unit = (d['base_unit'] ?? '').toString();

        final name = b.trim().isNotEmpty ? '$g ($b)' : g;

        final agg = map.putIfAbsent(
          drugId,
          () => _TopDrugAgg(drugId: drugId, name: name, baseUnit: unit),
        );
        agg.qtyBase += qty;
        agg.sales += lt;
      }
    } catch (_) {}

    final list = map.values.toList()..sort((a, b) => b.sales.compareTo(a.sales));
    return list.take(limit).map((a) {
      return _TopDrug(
        drugId: a.drugId,
        name: a.name,
        baseUnit: a.baseUnit,
        qtyBase: a.qtyBase,
        sales: a.sales,
      );
    }).toList();
  }

  // =========================
  // Alert Details
  // =========================
  Future<void> _loadAlertDetails() async {
    if (_loadingAlerts) return;
    _loadingAlerts = true;

    final sb = _sb!;
    final ownerId = _ownerId();

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    try {
      // ---------- (A) Expired/NearExpire + LowStock (มีล็อต > 0) ----------
      final limitEnd = today.add(const Duration(days: 365));

      final rows = await sb
          .from('drug_lots')
          .select('''
            id, drug_id, lot_no, exp_date, qty_on_hand_base,
            drugs(code, generic_name, brand_name, base_unit, expiry_alert_days, reorder_point)
          ''')
          .eq('owner_id', ownerId)
          .gt('qty_on_hand_base', 0)
          .lte('exp_date', _dateOnly(limitEnd))
          .order('exp_date', ascending: true);

      final lots = (rows as List).map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        final d = (m['drugs'] as Map?) ?? {};

        return _LotRow(
          lotId: (m['id'] ?? '').toString(),
          drugId: (m['drug_id'] ?? '').toString(),
          lotNo: (m['lot_no'] ?? '').toString(),
          expDate: _parseDate((m['exp_date'] ?? '').toString()),
          qtyBase: (m['qty_on_hand_base'] as num?) ?? 0,
          code: (d['code'] ?? '').toString(),
          genericName: (d['generic_name'] ?? '-').toString(),
          brandName: (d['brand_name'] ?? '').toString(),
          baseUnit: (d['base_unit'] ?? '').toString(),
          expiryAlertDays: (d['expiry_alert_days'] as num?)?.toInt() ?? 90,
          reorderPoint: (d['reorder_point'] as num?) ?? 0,
        );
      }).where((l) => l.drugId.isNotEmpty).toList();

      final expiredMap = <String, _DrugAlertGroup>{};
      final nearMap = <String, _DrugAlertGroup>{};

      final sumBase = <String, num>{};
      final infoMap = <String, _DrugInfo>{};

      for (final l in lots) {
        sumBase[l.drugId] = (sumBase[l.drugId] ?? 0) + l.qtyBase;

        infoMap.putIfAbsent(
          l.drugId,
          () => _DrugInfo(
            drugId: l.drugId,
            code: l.code,
            name: l.brandName.trim().isNotEmpty
                ? '${l.genericName} (${l.brandName})'
                : l.genericName,
            baseUnit: l.baseUnit,
            reorderPoint: l.reorderPoint,
            expiryAlertDays: l.expiryAlertDays,
          ),
        );

        final exp = DateTime(l.expDate.year, l.expDate.month, l.expDate.day);

        if (exp.isBefore(today)) {
          expiredMap.putIfAbsent(
            l.drugId,
            () => _DrugAlertGroup(info: infoMap[l.drugId]!, lots: []),
          );
          expiredMap[l.drugId]!.lots.add(l);
          continue;
        }

        final warnDays = math.max(0, l.expiryAlertDays);
        final warnEnd = today.add(Duration(days: warnDays));
        if (!exp.isAfter(warnEnd)) {
          nearMap.putIfAbsent(
            l.drugId,
            () => _DrugAlertGroup(info: infoMap[l.drugId]!, lots: []),
          );
          nearMap[l.drugId]!.lots.add(l);
        }
      }

      final lowGroups = <_DrugAlertGroup>[];
      for (final entry in sumBase.entries) {
        final drugId = entry.key;
        final total = entry.value;
        final info = infoMap[drugId];
        if (info == null) continue;

        final rp = info.reorderPoint;

        if (rp > 0 && total > 0 && total <= rp) {
          final drugLots = lots.where((x) => x.drugId == drugId).toList()
            ..sort((a, b) => a.expDate.compareTo(b.expDate));
          lowGroups.add(_DrugAlertGroup(info: info, lots: drugLots, totalBase: total));
        }
      }

      final expiredGroups = expiredMap.values.toList()
        ..sort((a, b) => a.nextExpDate.compareTo(b.nextExpDate));
      final nearGroups = nearMap.values.toList()
        ..sort((a, b) => a.nextExpDate.compareTo(b.nextExpDate));
      lowGroups.sort((a, b) => (a.totalBase ?? 0).compareTo(b.totalBase ?? 0));

      _expiredGroups = expiredGroups;
      _nearExpireGroups = nearGroups;
      _lowStockGroups = lowGroups;

      // ---------- (B) Out of stock (ยอดรวม = 0) จาก v_drug_stock_summary ----------
      // ---------- (B) Out of stock (ยอดรวม = 0) จาก v_drug_stock_summary ----------
// ✅ 2-step: เอา drug_id ที่ out ก่อน แล้วค่อยไปดึงชื่อจากตาราง drugs (กันปัญหา embed view)
try {
  final sum = await sb
      .from('v_drug_stock_summary')
      .select('drug_id, stock_status, on_hand_base')
      .eq('owner_id', ownerId);

  final outIds = <String>[];
  for (final r in (sum as List)) {
    final st = (r['stock_status'] ?? '').toString();
    if (st != 'out') continue;

    final drugId = (r['drug_id'] ?? '').toString();
    if (drugId.isEmpty) continue;

    outIds.add(drugId);
  }

  if (outIds.isEmpty) {
    _outStockGroups = [];
  } else {
    // ดึงข้อมูลยาเพื่อโชว์ชื่อรายการ
    final drugRows = await sb
        .from('drugs')
        .select('id, code, generic_name, brand_name, base_unit, reorder_point, expiry_alert_days')
        .eq('owner_id', ownerId)
        .inFilter('id', outIds);

    final byId = <String, Map<String, dynamic>>{};
    for (final d in (drugRows as List)) {
      final m = Map<String, dynamic>.from(d as Map);
      final id = (m['id'] ?? '').toString();
      if (id.isNotEmpty) byId[id] = m;
    }

    final outGroups = <_DrugAlertGroup>[];
    for (final id in outIds) {
      final d = byId[id];
      if (d == null) continue;

      final code = (d['code'] ?? '').toString();
      final g = (d['generic_name'] ?? '-').toString();
      final b = (d['brand_name'] ?? '').toString();
      final baseUnit = (d['base_unit'] ?? '').toString();
      final rp = (d['reorder_point'] as num?) ?? 0;
      final ead = (d['expiry_alert_days'] as num?)?.toInt() ?? 90;

      final name = b.trim().isNotEmpty ? '$g ($b)' : g;

      outGroups.add(
        _DrugAlertGroup(
          info: _DrugInfo(
            drugId: id,
            code: code,
            name: name,
            baseUnit: baseUnit,
            reorderPoint: rp,
            expiryAlertDays: ead,
          ),
          lots: const [], // out stock ไม่มีล็อตคงเหลือ
          totalBase: 0,
        ),
      );
    }

    outGroups.sort((a, b) => a.info.name.compareTo(b.info.name));
    _outStockGroups = outGroups;
  }
} catch (e) {
  debugPrint('load outStock groups error: $e');
  _outStockGroups = [];
}
    } catch (e) {
      debugPrint('loadAlertDetails error: $e');
      _expiredGroups = [];
      _nearExpireGroups = [];
      _lowStockGroups = [];
      _outStockGroups = [];
    } finally {
      _loadingAlerts = false;
    }
  }

  void _openAlertSheet(_AlertType type) {
    List<_DrugAlertGroup> groups;
    String title;
    IconData icon;
    Color tone;

    switch (type) {
      case _AlertType.expired:
        groups = _expiredGroups;
        title = 'ล็อตหมดอายุ';
        icon = Icons.error_outline_rounded;
        tone = Colors.red;
        break;
      case _AlertType.nearExpire:
        groups = _nearExpireGroups;
        title = 'ล็อตใกล้หมดอายุ';
        icon = Icons.schedule_rounded;
        tone = Colors.orange;
        break;
      case _AlertType.lowStock:
        groups = _lowStockGroups;
        title = 'ยาสต็อกต่ำ';
        icon = Icons.inventory_2_rounded;
        tone = Colors.deepOrange;
        break;
      case _AlertType.outStock:
        groups = _outStockGroups;
        title = 'ยาไม่มีสต็อก';
        icon = Icons.remove_shopping_cart_rounded;
        tone = Colors.redAccent;
        break;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: const Color(0xFFF4F7FB),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;

        Widget headerChip(String text) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: tone.withOpacity(0.12),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: tone.withOpacity(0.22)),
            ),
            child: Text(
              text,
              style: TextStyle(fontWeight: FontWeight.w900, color: tone, fontSize: 12),
            ),
          );
        }

        String fmtDate(DateTime d) => _dateOnly(d);
        int daysTo(DateTime d) {
          final today = DateTime.now();
          final a = DateTime(today.year, today.month, today.day);
          final b = DateTime(d.year, d.month, d.day);
          return b.difference(a).inDays;
        }

        String qty(num v) {
          if (v % 1 == 0) return v.toStringAsFixed(0);
          return v.toStringAsFixed(2);
        }

        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 14,
              right: 14,
              top: 8,
              bottom: 14 + MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.black.withOpacity(0.06)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: tone.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(icon, color: tone),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w900, fontSize: 16)),
                            const SizedBox(height: 4),
                            Text(
                              '${groups.length} รายการ',
                              style: TextStyle(
                                  color: Colors.black.withOpacity(0.6),
                                  fontWeight: FontWeight.w700),
                            ),
                          ],
                        ),
                      ),
                      headerChip(
                        (type == _AlertType.lowStock || type == _AlertType.outStock)
                            ? 'STOCK'
                            : 'EXP',
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'ไปหน้าปฏิทินหมดอายุ',
                        onPressed: () async {
                          Navigator.pop(ctx);
                          await Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const ExpiryCalendarPage()),
                          );
                          if (mounted) _bootstrap();
                        },
                        icon: Icon(Icons.calendar_month_rounded, color: cs.primary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: groups.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 28),
                            child: Text(
                              'ยังไม่มีรายการในหมวดนี้',
                              style: TextStyle(
                                  color: Colors.black.withOpacity(0.55),
                                  fontWeight: FontWeight.w700),
                            ),
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: groups.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 10),
                          itemBuilder: (_, i) {
                            final g = groups[i];

                            final rp = g.info.reorderPoint;
                            final total = g.totalBase;

                            final lots = [...g.lots]
                              ..sort((a, b) => a.expDate.compareTo(b.expDate));

                            return Container(
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
                                padding: const EdgeInsets.all(12),
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
                                                g.info.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(fontWeight: FontWeight.w900),
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                [
                                                  if (g.info.code.trim().isNotEmpty) 'รหัส ${g.info.code}',
                                                  if (g.info.baseUnit.trim().isNotEmpty) 'หน่วย ${g.info.baseUnit}',
                                                ].join(' • '),
                                                style: TextStyle(
                                                  color: Colors.black.withOpacity(0.60),
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 13,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        if ((type == _AlertType.lowStock || type == _AlertType.outStock) &&
                                            total != null)
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                            decoration: BoxDecoration(
                                              color: tone.withOpacity(0.10),
                                              borderRadius: BorderRadius.circular(999),
                                              border: Border.all(color: tone.withOpacity(0.22)),
                                            ),
                                            child: Text(
                                              type == _AlertType.outStock
                                                  ? 'คงเหลือ 0'
                                                  : 'คงเหลือ ${qty(total)}',
                                              style: TextStyle(
                                                fontWeight: FontWeight.w900,
                                                color: tone,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                    if ((type == _AlertType.lowStock || type == _AlertType.outStock) &&
                                        rp > 0) ...[
                                      const SizedBox(height: 8),
                                      Text(
                                        'จุดสั่งซื้อ (reorder_point): ${qty(rp)} ${g.info.baseUnit}',
                                        style: TextStyle(
                                            color: Colors.black.withOpacity(0.55),
                                            fontWeight: FontWeight.w700),
                                      ),
                                    ],
                                    if (type == _AlertType.outStock) ...[
                                      const SizedBox(height: 10),
                                      Container(
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFF4F7FB),
                                          borderRadius: BorderRadius.circular(14),
                                          border: Border.all(color: Colors.black.withOpacity(0.06)),
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(Icons.info_outline_rounded,
                                                color: Colors.black.withOpacity(0.55)),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                'ไม่พบสต็อกคงเหลือ (ยอดรวมเป็น 0)',
                                                style: TextStyle(
                                                  fontWeight: FontWeight.w800,
                                                  color: Colors.black.withOpacity(0.65),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                    if (type != _AlertType.outStock) ...[
                                      const SizedBox(height: 10),
                                      Container(
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFF4F7FB),
                                          borderRadius: BorderRadius.circular(14),
                                          border: Border.all(color: Colors.black.withOpacity(0.06)),
                                        ),
                                        child: Column(
                                          children: List.generate(lots.length, (j) {
                                            final l = lots[j];
                                            final dLeft = daysTo(l.expDate);
                                            final badgeText = (type == _AlertType.lowStock)
                                                ? 'ล็อต ${l.lotNo}'
                                                : (dLeft < 0 ? 'หมดอายุ' : 'อีก $dLeft วัน');

                                            final badgeColor = type == _AlertType.expired
                                                ? Colors.red
                                                : (type == _AlertType.nearExpire
                                                    ? Colors.orange
                                                    : cs.primary);

                                            return Padding(
                                              padding: EdgeInsets.only(bottom: j == lots.length - 1 ? 0 : 8),
                                              child: Row(
                                                children: [
                                                  Expanded(
                                                    child: Text(
                                                      'ล็อต: ${l.lotNo} • หมดอายุ: ${fmtDate(l.expDate)}',
                                                      style: const TextStyle(
                                                          fontWeight: FontWeight.w800, height: 1.2),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                                    decoration: BoxDecoration(
                                                      color: badgeColor.withOpacity(0.10),
                                                      borderRadius: BorderRadius.circular(999),
                                                      border: Border.all(color: badgeColor.withOpacity(0.22)),
                                                    ),
                                                    child: Text(
                                                      badgeText,
                                                      style: TextStyle(
                                                        fontWeight: FontWeight.w900,
                                                        color: badgeColor,
                                                        fontSize: 12,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                                    decoration: BoxDecoration(
                                                      color: cs.primary.withOpacity(0.08),
                                                      borderRadius: BorderRadius.circular(999),
                                                      border: Border.all(color: cs.primary.withOpacity(0.18)),
                                                    ),
                                                    child: Text(
                                                      '${qty(l.qtyBase)} ${g.info.baseUnit}',
                                                      style: TextStyle(
                                                          fontWeight: FontWeight.w900,
                                                          color: cs.primary,
                                                          fontSize: 12),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            );
                                          }),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('ปิด'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // =========================
  // Manufacturers & Suppliers (load)
  // =========================
  Future<void> _loadManufacturers() async {
    final sb = _sb!;
    final ownerId = _ownerId();

    final rows = await sb
        .from('manufacturers')
        .select('id, name, code, country, address, phone, fda_number, created_at')
        .eq('owner_id', ownerId)
        .order('name', ascending: true);

    _manufacturers =
        (rows as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> _loadSuppliers() async {
    final sb = _sb!;
    final ownerId = _ownerId();

    final rows = await sb
        .from('suppliers')
        .select('''
          id, name, code, phone, address, note,
          is_default, is_active,
          company_name, contact_name, delivery_area,
          line_id, email, company_reg_no, drug_license_no,
          created_at, updated_at
        ''')
        .eq('owner_id', ownerId)
        .order('is_default', ascending: false)
        .order('name', ascending: true);

    _suppliers =
        (rows as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  // =========================
  // Helpers
  // =========================
  String _dateOnly(DateTime d) {
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }

  DateTime _parseDate(String ymd) {
    final parts = ymd.split('-');
    if (parts.length != 3) return DateTime.now();
    return DateTime(
      int.tryParse(parts[0]) ?? 2000,
      int.tryParse(parts[1]) ?? 1,
      int.tryParse(parts[2]) ?? 1,
    );
  }

  int _daysBetween(DateTime a, DateTime b) {
    final aa = DateTime(a.year, a.month, a.day);
    final bb = DateTime(b.year, b.month, b.day);
    return bb.difference(aa).inDays;
  }

  String _money(num v) => v.toStringAsFixed(2);
  int _pct(int part, int total) => ((part * 100) / total).round();
  String _fmtQty(num v) => (v % 1 == 0) ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  Widget _onHandByUnitChips(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_onHandByBaseUnit.isEmpty) {
      return Text('คงเหลือแยกหน่วย: -', style: TextStyle(color: Colors.black.withOpacity(0.55)));
    }

    final entries = _onHandByBaseUnit.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final chips = <Widget>[];
    for (final e in entries) {
      if (e.value <= 0) continue;
      chips.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: cs.primary.withOpacity(0.08),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: cs.primary.withOpacity(0.18)),
          ),
          child: Text(
            '${e.key}: ${_fmtQty(e.value)}',
            style: TextStyle(fontWeight: FontWeight.w900, color: cs.primary),
          ),
        ),
      );
    }

    if (chips.isEmpty) {
      return Text('คงเหลือแยกหน่วย: -', style: TextStyle(color: Colors.black.withOpacity(0.55)));
    }

    return Wrap(spacing: 8, runSpacing: 8, children: chips);
  }

  Widget _drawerSectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: FontWeight.w900,
          color: Colors.black.withOpacity(0.55),
        ),
      ),
    );
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('ออกจากระบบ', style: TextStyle(fontWeight: FontWeight.w900)),
          content: const Text('ต้องการออกจากระบบใช่ไหม?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('ยกเลิก'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('ออกจากระบบ'),
            ),
          ],
        );
      },
    );

    if (ok != true) return;

    try {
      await _sb?.auth.signOut();
    } catch (_) {}

    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AuthGate()),
      (r) => false,
    );
  }

  Widget _buildDrawer(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final user = _sb?.auth.currentUser;

    final logoProvider = _homeLogoProvider();
    final headerTitle =
        (_shopName?.isNotEmpty == true) ? _shopName! : (user?.email ?? 'ผู้ใช้');

    Future<void> go(Widget page) async {
      Navigator.pop(context);
      final res = await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
      if (mounted) _bootstrap();
      if (res == true && mounted) _bootstrap();
    }

    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [cs.primary, cs.primary.withOpacity(0.78)],
                ),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: Colors.white.withOpacity(0.18),
                    backgroundImage: logoProvider,
                    onBackgroundImageError: logoProvider == null
                        ? null
                        : (_, __) {
                            if (mounted) setState(() => _logoUrl = null);
                          },
                    child: logoProvider == null
                        ? const Icon(Icons.store_rounded, color: Colors.white)
                        : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          headerTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        Text(
                          user?.email ?? 'PharmaStock • Menu',
                          style: TextStyle(color: Colors.white.withOpacity(0.85)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  _drawerSectionTitle('โปรไฟล์ & ระบบ'),
                  ListTile(
                    leading: const Icon(Icons.person_rounded),
                    title: const Text('โปรไฟล์'),
                    subtitle: const Text('ชื่อร้าน • ชื่อผู้ใช้ • เบอร์ • โลโก้'),
                    onTap: () => go(const ProfilePage()),
                  ),
                  ListTile(
                    leading: const Icon(Icons.security_rounded),
                    title: const Text('ความปลอดภัย'),
                    subtitle: const Text('เปลี่ยนอีเมล / เปลี่ยนรหัสผ่าน'),
                    onTap: () => go(const SecurityPage()),
                  ),
                  ListTile(
                    leading: const Icon(Icons.info_outline_rounded),
                    title: const Text('เกี่ยวกับแอป'),
                    subtitle: const Text('เวอร์ชัน • ผู้พัฒนา • ช่องทางติดต่อ'),
                    onTap: () => go(const AboutPage()),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
              child: ListTile(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                leading: const Icon(Icons.logout_rounded, color: Colors.red),
                title: const Text('ออกจากระบบ',
                    style: TextStyle(color: Colors.red, fontWeight: FontWeight.w900)),
                onTap: _logout,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // =========================
  // UI
  // =========================
  @override
  Widget build(BuildContext context) {
    if (_sb == null) {
      return const SupabaseGuard(
        child: SizedBox.shrink(),
        message: '',
      );
    }

    final cs = Theme.of(context).colorScheme;

    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Text('เกิดข้อผิดพลาด: $_error'),
          ),
        ),
      );
    }

    final totalLotForStatus =
        (_expiredCount + _nearExpireCount + (_lotCount - _expiredCount - _nearExpireCount))
            .clamp(1, 1 << 30);
    final okLots = (_lotCount - _expiredCount - _nearExpireCount).clamp(0, 1 << 30);

    final heroTitle = (_shopName?.trim().isNotEmpty == true) ? _shopName!.trim() : 'PharmaStock';
    final heroSubtitle =
        (_displayName?.trim().isNotEmpty == true) ? _displayName!.trim() : 'Dashboard';

    Widget actionPill({
      required IconData icon,
      required String label,
      required VoidCallback onTap,
    }) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.16),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white.withOpacity(0.18)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.10),
                  blurRadius: 12,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white.withOpacity(0.95), size: 18),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.95),
                    fontWeight: FontWeight.w900,
                    fontSize: 12,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      drawer: _buildDrawer(context),
      backgroundColor: const Color(0xFFF4F7FB),
      body: RefreshIndicator(
        onRefresh: _bootstrap,
        child: ListView(
          controller: _scrollCtl,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            // ================= HERO (soft + glass) =================
            ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color.lerp(cs.primary, Colors.white, 0.10)!,
                      Color.lerp(cs.primary, Colors.black, 0.06)!.withOpacity(0.92),
                      Color.lerp(cs.primary, Colors.white, 0.22)!.withOpacity(0.85),
                    ],
                  ),
                ),
                child: Stack(
                  children: [
                    Positioned(
                      right: -60,
                      top: -50,
                      child: Container(
                        width: 180,
                        height: 180,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withOpacity(0.10),
                        ),
                      ),
                    ),
                    Positioned(
                      left: -70,
                      bottom: -80,
                      child: Container(
                        width: 220,
                        height: 220,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withOpacity(0.08),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 40,
                      top: 30,
                      child: Container(
                        width: 90,
                        height: 90,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black.withOpacity(0.05),
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white.withOpacity(0.16)),
                        boxShadow: [
                          BoxShadow(
                            color: cs.primary.withOpacity(0.16),
                            blurRadius: 18,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Builder(
                                builder: (ctx) => IconButton(
                                  tooltip: 'เมนู',
                                  onPressed: () => Scaffold.of(ctx).openDrawer(),
                                  icon: Icon(Icons.menu_rounded, color: Colors.white.withOpacity(0.95)),
                                ),
                              ),
                              const Spacer(),
                              IconButton(
                                tooltip: 'รีเฟรช',
                                onPressed: _bootstrap,
                                icon: Icon(Icons.refresh_rounded, color: Colors.white.withOpacity(0.95)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Center(
                            child: Text(
                              heroTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.2,
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Center(
                            child: Text(
                              heroSubtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.84),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Center(
                            child: Container(
                              width: 140,
                              height: 1,
                              color: Colors.white.withOpacity(0.18),
                            ),
                          ),
                          const SizedBox(height: 12),

                          // ✅ เพิ่ม "ผู้ป่วย" เชื่อมกับ patient_home_page.dart
                          Center(
                            child: Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 11,
                              runSpacing: 10,
                              children: [
                                // ✅ ข้อมูลยา
                                actionPill(
                                  icon: Icons.medication_rounded,
                                  label: 'ข้อมูลยา',
                                  onTap: () async {
                                    await Navigator.of(context).push(
                                      MaterialPageRoute(builder: (_) => const AllDrugsPage()),
                                    );
                                    if (mounted) _bootstrap();
                                  },
                                ),

                                // ✅ NEW: ผู้ป่วย (ไปหน้า PatientHomePage)
                                actionPill(
                                  icon: Icons.people_rounded,
                                  label: 'ผู้ป่วย',
                                  onTap: () async {
                                    await Navigator.of(context).push(
                                      MaterialPageRoute(builder: (_) => const PatientsPage()),
                                    );
                                    if (mounted) _bootstrap();
                                  },
                                ),

                                actionPill(
  icon: Icons.receipt_long_rounded,
  label: 'บิล',
  onTap: () async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const BillsPage()),
    );
    if (mounted) _bootstrap();
  },
),

                                actionPill(
                                  icon: Icons.domain_rounded,
                                  label: 'ผู้ผลิต',
                                  onTap: () async {
                                    await Navigator.of(context).push(
                                      MaterialPageRoute(builder: (_) => const ManufacturersPage()),
                                    );
                                    if (mounted) _bootstrap();
                                  },
                                ),
                                actionPill(
                                  icon: Icons.store_rounded,
                                  label: 'Supplier',
                                  onTap: () async {
                                    await Navigator.of(context).push(
                                      MaterialPageRoute(builder: (_) => const SuppliersPage()),
                                    );
                                    if (mounted) _bootstrap();
                                  },
                                ),
                                actionPill(
                                  icon: Icons.calendar_month_rounded,
                                  label: 'ปฏิทินหมดอายุ',
                                  onTap: () async {
                                    await Navigator.of(context).push(
                                      MaterialPageRoute(builder: (_) => const ExpiryCalendarPage()),
                                    );
                                    if (mounted) _bootstrap();
                                  },
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),
           Column(
            children: [

              Row(
                children: [
                  Expanded(
                    child: _actionCard(
                      icon: Icons.download_rounded,
                      title: 'รับยาเข้า',
                      subtitle: 'เพิ่มล็อตยา + วันหมดอายุ + จำนวน\nรองรับ',
                      color: Colors.green,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const StockInPage(),
                          ),
                        );
                      },
                    ),
                  ),

                  const SizedBox(width: 12),

                  Expanded(
                    child: _actionCard(
                      icon: Icons.outbox_rounded,
                      title: 'จ่ายยาออก',
                      subtitle: 'ตัดล็อตอัตโนมัติแบบ FEFO + เก็บประวัติใบเสร็จ',
                      color: Colors.red,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const StockOutPage(),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),

const SizedBox(height: 14),

            if (_expiredCount > 0 || _nearExpireCount > 0)
              _panelNoFuzz(
                title: 'แจ้งเตือน: วันหมดอายุ',
                icon: Icons.schedule_rounded,
                child: Column(
                  children: [
                    if (_expiredCount > 0)
                      _alertRow(
                        Icons.error_outline_rounded,
                        'ล็อตหมดอายุ $_expiredCount รายการ',
                        Colors.red,
                        onTap: () => _openAlertSheet(_AlertType.expired),
                      ),
                    if (_nearExpireCount > 0)
                      _alertRow(
                        Icons.schedule_rounded,
                        'ล็อตใกล้หมดอายุ $_nearExpireCount รายการ',
                        Colors.orange,
                        onTap: () => _openAlertSheet(_AlertType.nearExpire),
                      ),
                  ],
                ),
              ),

            if (_expiredCount > 0 || _nearExpireCount > 0) const SizedBox(height: 12),

            if (_lowStockCount > 0 || _outStockCount > 0)
              _panelNoFuzz(
                title: 'แจ้งเตือน: สต็อกสินค้า',
                icon: Icons.inventory_2_rounded,
                child: Column(
                  children: [
                    if (_lowStockCount > 0)
                      _alertRow(
                        Icons.inventory_2_rounded,
                        'ยาสต็อกต่ำ $_lowStockCount รายการ',
                        Colors.deepOrange,
                        onTap: () => _openAlertSheet(_AlertType.lowStock),
                      ),
                    if (_outStockCount > 0)
                      _alertRow(
                        Icons.remove_shopping_cart_rounded,
                        'ยาไม่มีสต็อก $_outStockCount รายการ',
                        Colors.redAccent,
                        onTap: () => _openAlertSheet(_AlertType.outStock),
                      ),
                  ],
                ),
              ),
              /*const SizedBox(height: 16),

              if (_lowStockCount > 0 || _outStockCount > 0)
                _panelNoFuzz(
                  title: 'แจ้งเตือน: สต็อกสินค้า',
                  icon: Icons.inventory_2_rounded,
                  child: Column(
                    children: [
                      if (_lowStockCount > 0)
                        _alertRow(
                          Icons.inventory_2_rounded,
                          'ยาสต็อกต่ำ $_lowStockCount รายการ',
                          Colors.deepOrange,
                          onTap: () => _openAlertSheet(_AlertType.lowStock),
                        ),
                      if (_outStockCount > 0)
                        _alertRow(
                          Icons.remove_shopping_cart_rounded,
                          'ยาไม่มีสต็อก $_outStockCount รายการ',
                          Colors.redAccent,
                          onTap: () => _openAlertSheet(_AlertType.outStock),
                        ),
                    ],
                  ),
                ),*/
            ],


            
          ),

            const SizedBox(height: 12),

            LayoutBuilder(
              builder: (context, c) {
                final wide = c.maxWidth >= 760;

                if (!wide) {
                  return Column(
                    children: [
                      _statCardNoFuzz(
                        title: 'ยาในระบบ',
                        value: '$_drugCount',
                        sub: 'จำนวนรายการยา (master)',
                        icon: Icons.medication_rounded,
                        tone: cs.primary,
                      ),
                      const SizedBox(height: 12),

                      _statCardNoFuzz(
                        title: 'กำไรโดยประมาณ',
                        value: '${_money(_profitEst)} ฿',
                        sub: 'ช่วง $_days วันล่าสุด',
                        icon: Icons.savings_rounded,
                        tone: _profitEst >= 0 ? Colors.green : Colors.red,
                      ),
                      const SizedBox(height: 12),

                      _statCardNoFuzz(
                        title: 'ล็อตที่มีของ',
                        value: '$_lotCount',
                        sub: 'นับเฉพาะล็อตคงเหลือ > 0',
                        icon: Icons.inventory_2_rounded,
                        tone: Colors.indigo,
                      ),
                      const SizedBox(height: 12),

                      _panelNoFuzz(
                        title: 'ภาพรวมล็อต (ปกติ/ใกล้หมด/หมดอายุ)',
                        icon: Icons.pie_chart_rounded,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'คงเหลือรวม (หน่วยฐาน): ${_onHandBaseTotal.toStringAsFixed(2)} • ยาสต็อกต่ำ: $_lowStockCount • ยาไม่มีสต็อก: $_outStockCount',
                              style: TextStyle(color: Colors.black.withOpacity(0.55)),
                            ),
                            const SizedBox(height: 10),
                            _onHandByUnitChips(context),
                            const SizedBox(height: 12),
                            _lotPieChart(
                              ok: okLots,
                              near: _nearExpireCount,
                              expired: _expiredCount,
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 10,
                              runSpacing: 8,
                              children: [
                                _legendDot('ปกติ', Colors.green, '${_pct(okLots, totalLotForStatus)}%'),
                                _legendDot('ใกล้หมด', Colors.orange,
                                    '${_pct(_nearExpireCount, totalLotForStatus)}%'),
                                _legendDot('หมดอายุ', Colors.red,
                                    '${_pct(_expiredCount, totalLotForStatus)}%'),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                }

                final w = (c.maxWidth - 12) / 2;
                return IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: w,
                        child: Column(
                          children: [
                            _statCardNoFuzz(
                              title: 'ยาในระบบ',
                              value: '$_drugCount',
                              sub: 'จำนวนรายการยา (master)',
                              icon: Icons.medication_rounded,
                              tone: cs.primary,
                            ),
                            const SizedBox(height: 12),

                            _statCardNoFuzz(
                              title: 'กำไรโดยประมาณ',
                              value: '${_money(_profitEst)} ฿',
                              sub: 'ช่วง $_days วันล่าสุด',
                              icon: Icons.savings_rounded,
                              tone: _profitEst >= 0 ? Colors.green : Colors.red,
                            ),
                            const SizedBox(height: 12),

                            _statCardNoFuzz(
                              title: 'ล็อตที่มีของ',
                              value: '$_lotCount',
                              sub: 'นับเฉพาะล็อตคงเหลือ > 0',
                              icon: Icons.inventory_2_rounded,
                              tone: Colors.indigo,
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(width: 12),

                      Expanded(
                        child: _panelNoFuzz(
                          title: 'ภาพรวมล็อต (ปกติ/ใกล้หมด/หมดอายุ)',
                          icon: Icons.pie_chart_rounded,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'คงเหลือรวม (หน่วยฐาน): ${_onHandBaseTotal.toStringAsFixed(2)} • ยาสต็อกต่ำ: $_lowStockCount • ยาไม่มีสต็อก: $_outStockCount',
                                style: TextStyle(color: Colors.black.withOpacity(0.55)),
                              ),
                              const SizedBox(height: 10),
                              _onHandByUnitChips(context),
                              const SizedBox(height: 12),
                              _statusBar(
                                ok: okLots,
                                near: _nearExpireCount,
                                expired: _expiredCount,
                                total: totalLotForStatus,
                              ),

                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 10,
                                runSpacing: 8,
                                children: [
                                  _legendDot('ปกติ', Colors.green, '${_pct(okLots, totalLotForStatus)}%'),
                                  _legendDot('ใกล้หมด', Colors.orange,
                                      '${_pct(_nearExpireCount, totalLotForStatus)}%'),
                                  _legendDot('หมดอายุ', Colors.red,
                                      '${_pct(_expiredCount, totalLotForStatus)}%'),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),

            const SizedBox(height: 12),


            _panelNoFuzz(
              title: '📊 กราฟเส้นยอดขาย',
              icon: Icons.show_chart_rounded,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _daysChip(7),
                  const SizedBox(width: 8),
                  _daysChip(30),
                  const SizedBox(width: 8),
                  _daysChip(90),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'ยอดขายรวมช่วง $_days วัน: ${_money(_sales)} ฿',
                    style: TextStyle(color: Colors.black.withOpacity(0.65), fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 180,
                    width: double.infinity,
                    child: _salesSeries.isEmpty
                        ? Center(
                            child: Text('ยังไม่มีข้อมูลยอดขาย',
                                style: TextStyle(color: Colors.black.withOpacity(0.55))))
                        : _LineChart(points: _salesSeries),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            _panelNoFuzz(
              title: '🏆 Top 10 สินค้าขายดี',
              icon: Icons.stars_rounded,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ChoiceChip(
                    label: const Text('รายวัน'),
                    selected: _topMode == 0,
                    onSelected: (_) => setState(() => _topMode = 0),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('รายเดือน'),
                    selected: _topMode == 1,
                    onSelected: (_) => setState(() => _topMode = 1),
                  ),
                ],
              ),
              child: Builder(builder: (_) {
                final list = _topMode == 0 ? _top10Daily : _top10Monthly;
                final subtitle = _topMode == 0 ? 'วันนี้' : 'เดือนนี้';

                if (list.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text('ยังไม่มีข้อมูลการขาย ($subtitle)',
                        style: TextStyle(color: Colors.black.withOpacity(0.55))),
                  );
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('สรุป $subtitle',
                        style: TextStyle(
                            color: Colors.black.withOpacity(0.65),
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 10),
                    Column(
                      children: List.generate(list.length, (i) {
                        final t = list[i];
                        return _topRowNoFuzz(rank: i + 1, t: t);
                      }),
                    ),
                  ],
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  // =========================
  Widget _panelNoFuzz({
    required String title,
    required IconData icon,
    required Widget child,
    Widget? trailing,
  }) {
    final cs = Theme.of(context).colorScheme;

    return Material(
      color: Colors.transparent,
      child: Container(
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
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(
              children: [
                Icon(icon, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w900),
                  ),
                ),
                if (trailing != null) trailing,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ]),
        ),
      ),
    );
  }

  Widget _alertRow(IconData icon, String text, Color c, {VoidCallback? onTap}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Row(
            children: [
              Icon(icon, color: c, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(text, style: TextStyle(color: c, fontWeight: FontWeight.w800))),
              if (onTap != null) Icon(Icons.chevron_right_rounded, color: c.withOpacity(0.85)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _daysChip(int d) {
    final on = _days == d;
    return ChoiceChip(
      label: Text('$d วัน'),
      selected: on,
      onSelected: (v) async {
        setState(() => _days = d);
        setState(() => _loading = true);

        await Future.wait([
          _loadFinance(days: d),
          _loadSalesSeries(days: d),
          _loadTopSellers(days: d),
        ]);

        if (mounted) setState(() => _loading = false);
      },
    );
  }

  Widget _statCardNoFuzz({
    required String title,
    required String value,
    required String sub,
    required IconData icon,
    required Color tone,
  }) {
    return Container(
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
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: tone.withOpacity(0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: tone),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
                const SizedBox(height: 6),
                Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                const SizedBox(height: 2),
                Text(sub, style: TextStyle(color: Colors.black.withOpacity(0.55))),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusBar({required int ok, required int near, required int expired, required int total}) {
    double wOk = ok / total;
    double wNear = near / total;
    double wExp = expired / total;

    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: Row(
        children: [
          Expanded(flex: (wOk * 1000).round().clamp(1, 1000), child: Container(height: 12, color: Colors.green)),
          Expanded(flex: (wNear * 1000).round().clamp(1, 1000), child: Container(height: 12, color: Colors.orange)),
          Expanded(flex: (wExp * 1000).round().clamp(1, 1000), child: Container(height: 12, color: Colors.red)),
        ],
      ),
    );
  }

  Widget _legendDot(String label, Color c, String pct) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text('$label ($pct)', style: TextStyle(color: Colors.black.withOpacity(0.70), fontWeight: FontWeight.w700)),
      ],
    );
  }

  Widget _topRowNoFuzz({required int rank, required _TopDrug t}) {
    final cs = Theme.of(context).colorScheme;
    final badge = rank == 1
        ? Colors.amber
        : (rank == 2 ? Colors.grey : (rank == 3 ? Colors.brown : cs.primary.withOpacity(0.6)));

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.black.withOpacity(0.06)),
        color: Colors.white,
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
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: badge.withOpacity(0.15), borderRadius: BorderRadius.circular(12)),
            alignment: Alignment.center,
            child: Text(
              '$rank',
              style: TextStyle(fontWeight: FontWeight.w900, color: badge),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900)),
              const SizedBox(height: 4),
              Text(
                'ขาย ${t.qtyBase.toStringAsFixed(0)} ${t.baseUnit} • ยอดขาย ${_money(t.sales)} ฿',
                style: TextStyle(color: Colors.black.withOpacity(0.60), fontWeight: FontWeight.w700, fontSize: 13),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

// =========================
// Chart
// =========================
class _ChartPoint {
  final double x;
  final double y;
  final String label;
  const _ChartPoint(this.x, this.y, {required this.label});
}

class _LineChart extends StatelessWidget {
  final List<_ChartPoint> points;
  const _LineChart({required this.points});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _LineChartPainter(points: points, color: PharmaColors.green),
      child: const SizedBox.expand(),
    );
  }
}

class _LineChartPainter extends CustomPainter {
  final List<_ChartPoint> points;
  final Color color;
  _LineChartPainter({required this.points, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    const padding = 14.0;
    final w = size.width;
    final h = size.height;

    final plotRect = Rect.fromLTWH(padding, padding, w - padding * 2, h - padding * 2);

    final minX = points.first.x;
    final maxX = points.last.x;

    double minY = points.map((p) => p.y).reduce(math.min);
    double maxY = points.map((p) => p.y).reduce(math.max);
    if (minY == maxY) maxY = minY + 1;

    final gridPaint = Paint()
      ..color = Colors.black.withOpacity(0.06)
      ..strokeWidth = 1;

    for (int i = 0; i <= 4; i++) {
      final yy = plotRect.top + (plotRect.height * i / 4);
      canvas.drawLine(Offset(plotRect.left, yy), Offset(plotRect.right, yy), gridPaint);
    }

    final borderPaint = Paint()
      ..color = Colors.black.withOpacity(0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRRect(RRect.fromRectAndRadius(plotRect, const Radius.circular(12)), borderPaint);

    Offset mapPoint(_ChartPoint p) {
      final dx = (p.x - minX) / (maxX - minX == 0 ? 1 : (maxX - minX));
      final dy = (p.y - minY) / (maxY - minY);
      final x = plotRect.left + dx * plotRect.width;
      final y = plotRect.bottom - dy * plotRect.height;
      return Offset(x, y);
    }

    final path = Path();
    final mapped = points.map(mapPoint).toList();
    path.moveTo(mapped.first.dx, mapped.first.dy);
    for (int i = 1; i < mapped.length; i++) {
      path.lineTo(mapped[i].dx, mapped[i].dy);
    }

    final area = Path.from(path)
      ..lineTo(mapped.last.dx, plotRect.bottom)
      ..lineTo(mapped.first.dx, plotRect.bottom)
      ..close();

    canvas.drawPath(area, Paint()..color = color.withOpacity(0.10));

    final linePaint = Paint()
      ..color = color.withOpacity(0.90)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    canvas.drawPath(path, linePaint);

    final dotPaint = Paint()..color = color;
    for (final pt in mapped) {
      canvas.drawCircle(pt, 3.4, dotPaint);
      canvas.drawCircle(pt, 6.2, Paint()..color = color.withOpacity(0.08));
    }
  }

  @override
  bool shouldRepaint(covariant _LineChartPainter oldDelegate) {
    return oldDelegate.points != points || oldDelegate.color != color;
  }
}

// =========================
// Alert Models
// =========================
enum _AlertType { expired, nearExpire, lowStock, outStock }

class _DrugInfo {
  final String drugId;
  final String code;
  final String name;
  final String baseUnit;
  final num reorderPoint;
  final int expiryAlertDays;

  const _DrugInfo({
    required this.drugId,
    required this.code,
    required this.name,
    required this.baseUnit,
    required this.reorderPoint,
    required this.expiryAlertDays,
  });
}

class _LotRow {
  final String lotId;
  final String drugId;
  final String lotNo;
  final DateTime expDate;
  final num qtyBase;

  final String code;
  final String genericName;
  final String brandName;
  final String baseUnit;
  final int expiryAlertDays;
  final num reorderPoint;

  const _LotRow({
    required this.lotId,
    required this.drugId,
    required this.lotNo,
    required this.expDate,
    required this.qtyBase,
    required this.code,
    required this.genericName,
    required this.brandName,
    required this.baseUnit,
    required this.expiryAlertDays,
    required this.reorderPoint,
  });
}

class _DrugAlertGroup {
  final _DrugInfo info;
  final List<_LotRow> lots;
  final num? totalBase;

  _DrugAlertGroup({required this.info, required this.lots, this.totalBase});

  DateTime get nextExpDate {
    if (lots.isEmpty) return DateTime(2100);
    final tmp = [...lots]..sort((a, b) => a.expDate.compareTo(b.expDate));
    return tmp.first.expDate;
  }
}

// =========================
// Top Models
// =========================
class _TopDrugAgg {
  final String drugId;
  final String name;
  final String baseUnit;
  num qtyBase = 0;
  num sales = 0;
  _TopDrugAgg({required this.drugId, required this.name, required this.baseUnit});
}

class _TopDrug {
  final String drugId;
  final String name;
  final String baseUnit;
  final num qtyBase;
  final num sales;
  _TopDrug({
    required this.drugId,
    required this.name,
    required this.baseUnit,
    required this.qtyBase,
    required this.sales,
  });
}

class _StockActionCard extends StatelessWidget {
  final Color accent;
  final Color iconBg;
  final IconData icon;
  final String title;
  final String subtitle;
  final String buttonText;
  final VoidCallback onPressed;

  const _StockActionCard({
    required this.accent,
    required this.iconBg,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.buttonText,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.65),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE6EEF7)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 50,
            height: 35,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: accent.withOpacity(0.20)),
            ),
            child: Icon(icon, color: accent),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w900)),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  style: TextStyle(
                      color: Colors.black.withOpacity(0.6), height: 1.35),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  height: 40,
                  child: ElevatedButton.icon(
                    onPressed: onPressed,
                    icon: const Icon(Icons.arrow_forward_rounded),
                    label: Text(buttonText),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(999)),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      elevation: 0,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

//card
Widget _actionCard({
  required IconData icon,
  required String title,
  required String subtitle,
  required Color color,
  required VoidCallback onTap,
}) {

  return Card(
    elevation: 2,
    color: color, // สีพื้นหลังสว่าง
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
    ),
    child: InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [

            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: color.withOpacity(0.25),
                borderRadius: BorderRadius.circular(14),

                 border: Border.all(
                  color: Colors.white70, // สีขอบ
                  width: 2.5,
                ),
              
              ),
              child: Icon(
                icon,
                color: Colors.white,
                size: 28,
              ),
            ),

            const SizedBox(width: 14),

            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                     color: Colors.white,
                    ),
                  ),

                  const SizedBox(height: 4),

                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
            ),

            const Icon(
              Icons.arrow_forward_ios_rounded,
              size: 18,
              color: Colors.white,
            ),
          ],
        ),
      ),
    ),
  );
}

//Pie Chart
// Pie Chart ล็อตยา
Widget _lotPieChart({
  required int ok,
  required int near,
  required int expired,
}) {
  final total = ok + near + expired;

  int _pct(int part, int total) {
    if (total == 0) return 0;
    return ((part / total) * 100).round();
  }
  
  if (total == 0) {
    return const SizedBox(
      height: 160,
      child: Center(
        child: Text('ไม่มีข้อมูลล็อต'),
      ),
    );
  }

  return SizedBox(
    height: 180,
    child: Stack(
      alignment: Alignment.center,
      children: [
        PieChart(
          PieChartData(
            sectionsSpace: 2,
            centerSpaceRadius: 40,
            startDegreeOffset: -90,
            sections: [
              PieChartSectionData(
                value: ok.toDouble(),
                color: Colors.green,
                title: '${_pct(ok, total)}%',
                radius: 50,
                titleStyle: const TextStyle(
                  fontSize: 12,
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              PieChartSectionData(
                value: near.toDouble(),
                color: Colors.orange,
                title: '${_pct(near, total)}%',
                radius: 50,
                titleStyle: const TextStyle(
                  fontSize: 12,
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              PieChartSectionData(
                value: expired.toDouble(),
                color: Colors.red,
                title: '${_pct(expired, total)}%',
                radius: 50,
                titleStyle: const TextStyle(
                  fontSize: 12,
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          swapAnimationDuration: const Duration(milliseconds: 500),
        ),

        /// ตัวเลขตรงกลาง
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'ล็อตทั้งหมด',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            Text(
              '$total',
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ],
    ),
  );
}