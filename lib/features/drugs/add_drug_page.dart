import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'repository/drugs_repository.dart';

class AddDrugPage extends StatefulWidget {
  final String? drugId; // ✅ ถ้ามี = edit
  const AddDrugPage({super.key, this.drugId});

  @override
  State<AddDrugPage> createState() => _AddDrugPageState();
}

class _AddDrugPageState extends State<AddDrugPage> {
  bool get _isEdit => widget.drugId != null;
  bool _loadingEdit = false;

  final _formKey = GlobalKey<FormState>();

  late final DrugsRepository repo = DrugsRepository(Supabase.instance.client);
  final SupabaseClient _supabase = Supabase.instance.client;

  static const String _manufacturersTable = 'manufacturers';

  // master
  final _code = TextEditingController(text: '');
  final _generic = TextEditingController();
  final _brand = TextEditingController();
  final _dosageForm = TextEditingController();
  final _strength = TextEditingController();

  String _baseUnit = 'เม็ด';
  List<String> _baseUnits = [
  'เม็ด',
  'แคปซูล',
  'มล.',
  'กรัม',
  'ขวด',
  'หลอด',
  'ซอง',
  'ชิ้น',
];

  final _packUnit = TextEditingController();
  // ⭐ รายการหน่วยบรรจุ

  final _packToBase = TextEditingController();

  final _category = TextEditingController();

  // 🌟 ผู้ผลิต
  Map<String, dynamic>? _selectedManufacturer;
  List<Map<String, dynamic>> _manufacturersList = [];
  bool _isLoadingManufacturers = false;

  // ✅ ทำให้ search ใน bottom sheet ไม่ reset
  final TextEditingController _makerSearchCtl = TextEditingController();

  String _status = 'active';
  final _reorderPoint = TextEditingController(text: '0');
  final _expiryAlertDays = TextEditingController(text: '90');

  final _exampleText = TextEditingController();
  final _autoDispenseLabel = TextEditingController();

  // dispense units
  final _unitName = TextEditingController();
  final _unitToBase = TextEditingController();
  final List<_DispenseUnitDraft> _units = [];

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _applyBaseUnitAsDefault();

    Future.microtask(() async {
      await _loadManufacturers();
      if (_isEdit) {
        await _loadForEdit();
      }
    });
  }

  // ===== helpers =====
  String _requireUid() {
    final uid = _supabase.auth.currentUser?.id;
    if (uid == null) throw Exception('กรุณาเข้าสู่ระบบใหม่');
    return uid;
  }

  String _norm(String? s) => (s ?? '').trim().toLowerCase();

  bool _sameText(dynamic dbValue, String formValue) {
    return _norm(dbValue?.toString()) == _norm(formValue);
  }

  bool _sameNum(dynamic dbValue, num? formValue) {
    if (formValue == null) return false;
    if (dbValue == null) return false;
    final a = num.tryParse(dbValue.toString());
    if (a == null) return false;
    return a == formValue;
  }

  Future<bool> _hasColumn(String table, String column) async {
    try {
      final rows = await _supabase
          .from('information_schema.columns')
          .select('column_name')
          .eq('table_schema', 'public')
          .eq('table_name', table)
          .eq('column_name', column)
          .limit(1);
      return (rows as List).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> _loadManufacturers() async {
    if (!mounted) return;
    setState(() => _isLoadingManufacturers = true);

    try {
      final uid = _requireUid();
      final hasIsActive = await _hasColumn(_manufacturersTable, 'is_active');

      var q = _supabase
          .from(_manufacturersTable)
          .select('id, name, country, address, phone, fda_number')
          .eq('owner_id', uid);

      if (hasIsActive) {
        q = q.or('is_active.is.null,is_active.eq.true');
      }

      final response = await q.order('name', ascending: true);

      if (!mounted) return;
      setState(() {
        _manufacturersList = List<Map<String, dynamic>>.from(response);
      });
    } catch (e) {
      debugPrint('Error loading manufacturers: $e');
      if (mounted) {
        setState(() {
          _manufacturersList = [];
        });
      }
    } finally {
      if (mounted) setState(() => _isLoadingManufacturers = false);
    }
  }
  

  Future<void> _loadForEdit() async {
    if (!mounted) return;
    setState(() => _loadingEdit = true);

    try {
      final drugId = widget.drugId!;
      final drug = await repo.getDrugById(drugId);
      if (drug == null) throw Exception('ไม่พบข้อมูลยา');

      _code.text = (drug['code'] ?? '').toString();
      _generic.text = (drug['generic_name'] ?? '').toString();
      _brand.text = (drug['brand_name'] ?? '').toString();
      _dosageForm.text = (drug['dosage_form'] ?? '').toString();
      _strength.text = (drug['strength'] ?? '').toString();

      _baseUnit = (drug['base_unit'] ?? 'เม็ด').toString();
      _packUnit.text = (drug['pack_unit'] ?? '').toString();
      _packToBase.text = (drug['pack_to_base'] ?? '').toString();

      _category.text = (drug['category'] ?? '').toString();

      // 🌟 ตั้งค่าผู้ผลิตจากชื่อ
      final mName = (drug['manufacturer'] ?? '').toString().trim();
      if (mName.isNotEmpty) {
        Map<String, dynamic>? found;
        try {
          found = _manufacturersList
              .firstWhere((m) => (m['name'] ?? '').toString() == mName);
        } catch (_) {
          found = null;
        }
        _selectedManufacturer = found ?? {'name': mName};
      }

      _status = (drug['status'] ?? 'active').toString();
      _reorderPoint.text = (drug['reorder_point'] ?? 0).toString();
      _expiryAlertDays.text = (drug['expire_warn_days'] ?? 90).toString();

      _exampleText.text = (drug['example_text'] ?? '').toString();
      _autoDispenseLabel.text = (drug['auto_dispense_label'] ?? '').toString();

      final rows = await repo.listDispenseUnits(drugId, onlyActive: false);

      final baseName = _baseUnit.trim();
      final temp = <_DispenseUnitDraft>[];

      temp.add(_DispenseUnitDraft(
        unitName: baseName.isEmpty ? 'หน่วยฐาน' : baseName,
        toBase: 1,
        isDefault: true,
        isBaseUnit: true,
        isActive: true,
      ));

      for (final r in rows) {
        final name = (r['unit_name'] ?? '').toString().trim();
        if (name.isEmpty) continue;

        final toBase = (r['to_base'] is num) ? (r['to_base'] as num) : 1;
        final isDefault = r['is_default'] == true;
        final isActive =
            (r['is_active'] == null) ? true : (r['is_active'] == true);

        final isBase = name.toLowerCase() == baseName.toLowerCase();
        if (isBase) {
          temp[0] = temp[0].copyWith(
            isDefault: isDefault,
            isActive: true,
            toBase: 1,
          );
        } else {
          temp.add(_DispenseUnitDraft(
            unitName: name,
            toBase: toBase,
            isDefault: isDefault,
            isBaseUnit: false,
            isActive: isActive,
          ));
        }
      }

      int defaultIndex = temp.indexWhere((u) => u.isDefault);
      if (defaultIndex < 0) defaultIndex = 0;
      for (int i = 0; i < temp.length; i++) {
        temp[i] = temp[i].copyWith(isDefault: i == defaultIndex);
      }
      temp[defaultIndex] = temp[defaultIndex].copyWith(isActive: true);

      if (!mounted) return;
      setState(() {
        _units
          ..clear()
          ..addAll(temp);
      });

      if (_autoDispenseLabel.text.trim().isEmpty) {
        _autoDispenseLabel.text = _baseUnit;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('โหลดข้อมูลไม่สำเร็จ: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingEdit = false);
    }
  }

  @override
  void dispose() {
    _code.dispose();
    _generic.dispose();
    _brand.dispose();
    _dosageForm.dispose();
    _strength.dispose();
    _packUnit.dispose();
    _packToBase.dispose();
    _category.dispose();
    _reorderPoint.dispose();
    _expiryAlertDays.dispose();
    _exampleText.dispose();
    _autoDispenseLabel.dispose();
    _unitName.dispose();
    _unitToBase.dispose();
    _makerSearchCtl.dispose();
    super.dispose();
  }

  void _applyBaseUnitAsDefault() {
    setState(() {
      _units.removeWhere((u) => u.isBaseUnit);
      _units.insert(
        0,
        _DispenseUnitDraft(
          unitName: _baseUnit,
          toBase: 1,
          isDefault: true,
          isBaseUnit: true,
          isActive: true,
        ),
      );

      if (_autoDispenseLabel.text.trim().isEmpty) {
        _autoDispenseLabel.text = _baseUnit;
      }

      if (!_units.any((u) => u.isDefault)) {
        _setDefaultUnit(0);
      }

      _units[0] = _units[0].copyWith(isActive: true, toBase: 1);
    });
  }

  num? _tryNum(String v) {
    final t = v.trim();
    if (t.isEmpty) return null;
    return num.tryParse(t);
  }

  int? _tryInt(String v) {
    final t = v.trim();
    if (t.isEmpty) return null;
    return int.tryParse(t);
  }

  String? _req(String? v, String msg) =>
      (v ?? '').trim().isEmpty ? msg : null;

  Future<void> _showLoading() async {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
  }

  void _closeLoading() {
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).maybePop();
  }

  void _setDefaultUnit(int index) {
    setState(() {
      for (var i = 0; i < _units.length; i++) {
        _units[i] = _units[i].copyWith(isDefault: i == index);
      }
      _units[index] = _units[index].copyWith(isActive: true);
    });
  }

  void _toggleUnitActive(int index, bool v) {
    setState(() {
      final u = _units[index];

      if (u.isBaseUnit) {
        _units[index] = u.copyWith(isActive: true);
        return;
      }

      if (!v && u.isDefault) {
        _units[index] = u.copyWith(isActive: false, isDefault: false);
        _setDefaultUnit(_units.indexWhere((x) => x.isBaseUnit));
        return;
      }

      _units[index] = u.copyWith(isActive: v);
    });
  }

  void _removeUnit(int index) {
    setState(() {
      final isBase = _units[index].isBaseUnit;
      final wasDefault = _units[index].isDefault;

      _units.removeAt(index);

      if (isBase) {
        _applyBaseUnitAsDefault();
        return;
      }

      if (wasDefault && _units.isNotEmpty) {
        final baseIndex = _units.indexWhere((u) => u.isBaseUnit);
        if (baseIndex >= 0) _setDefaultUnit(baseIndex);
      }
    });
  }

  void _addUnitFromInputs() {
    final name = _unitName.text.trim();
    final toBase = _tryNum(_unitToBase.text) ?? 0;

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('กรุณากรอกชื่อหน่วยจ่าย')),
      );
      return;
    }
    if (toBase <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('อัตราเทียบต้องมากกว่า 0')),
      );
      return;
    }

    final dup =
        _units.any((u) => u.unitName.toLowerCase() == name.toLowerCase());
    if (dup) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('หน่วยนี้ถูกเพิ่มแล้ว')),
      );
      return;
    }

    setState(() {
      _units.add(
        _DispenseUnitDraft(
          unitName: name,
          toBase: toBase,
          isDefault: false,
          isBaseUnit: false,
          isActive: true,
        ),
      );
      _unitName.clear();
      _unitToBase.clear();
    });
  }

  void _addPopularSet() {
    final pUnit = _packUnit.text.trim();
    final pToBase = _tryNum(_packToBase.text);

    setState(() {
      if (_units.indexWhere((u) => u.isBaseUnit) == -1) {
        _applyBaseUnitAsDefault();
      }

      if (pUnit.isNotEmpty && (pToBase ?? 0) > 0) {
        final dup =
            _units.any((u) => u.unitName.toLowerCase() == pUnit.toLowerCase());
        if (!dup) {
          _units.add(
            _DispenseUnitDraft(
              unitName: pUnit,
              toBase: pToBase!,
              isDefault: false,
              isActive: true,
            ),
          );
        }
      }

      if (!_units.any((u) => u.isDefault)) {
        final baseIndex = _units.indexWhere((u) => u.isBaseUnit);
        if (baseIndex >= 0) _setDefaultUnit(baseIndex);
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('เพิ่มชุดยอดนิยมแล้ว (ใช้ pack→base ถ้ามี)')),
    );
  }

  String _hintConversionText() {
    final pUnit = _packUnit.text.trim();
    final pToBase = _tryNum(_packToBase.text);
    if (pUnit.isEmpty || (pToBase ?? 0) <= 0) return '';
    return '1 $pUnit = $pToBase $_baseUnit';
  }

  String _makerSubtitle(Map<String, dynamic> m) {
    final country = (m['country'] ?? '').toString().trim();
    final phone = (m['phone'] ?? '').toString().trim();
    final fda = (m['fda_number'] ?? '').toString().trim();
    final parts = <String>[];
    if (country.isNotEmpty) parts.add(country);
    if (phone.isNotEmpty) parts.add('โทร $phone');
    if (fda.isNotEmpty) parts.add('อย. $fda');
    return parts.isEmpty ? '-' : parts.join(' • ');
  }

  Future<List<Map<String, dynamic>>> _findDuplicateDrugs() async {
    final uid = _requireUid();

    final generic = _generic.text.trim();
    final brand = _brand.text.trim();
    final dosageForm = _dosageForm.text.trim();
    final strength = _strength.text.trim();
    final manufacturer =
        (_selectedManufacturer?['name'] ?? '').toString().trim();
    final category = _category.text.trim();
    final exampleText = _exampleText.text.trim();
    final autoDispenseLabel = _autoDispenseLabel.text.trim();
    final baseUnit = _baseUnit.trim();
    final packUnit = _packUnit.text.trim();
    final packToBase = _tryNum(_packToBase.text);

    final response = await _supabase
        .from('drugs')
        .select('''
          id,
          code,
          generic_name,
          brand_name,
          dosage_form,
          strength,
          manufacturer,
          category,
          example_text,
          auto_dispense_label,
          base_unit,
          pack_unit,
          pack_to_base,
          status
        ''')
        .eq('owner_id', uid)
        .eq('generic_name', generic)
        .eq('brand_name', brand)
        .eq('dosage_form', dosageForm)
        .eq('strength', strength)
        .eq('manufacturer', manufacturer)
        .eq('base_unit', baseUnit)
        .eq('pack_unit', packUnit);

    final rows = List<Map<String, dynamic>>.from(response);

    final matched = rows.where((r) {
      final samePackToBase = _sameNum(r['pack_to_base'], packToBase);
      final sameCategory = _sameText(r['category'], category);
      final sameExample = _sameText(r['example_text'], exampleText);
      final sameAuto = _sameText(r['auto_dispense_label'], autoDispenseLabel);

      return samePackToBase && sameCategory && sameExample && sameAuto;
    }).toList();

    if (_isEdit && widget.drugId != null) {
      matched.removeWhere((r) => r['id']?.toString() == widget.drugId);
    }

    return matched;
  }

  Future<bool> _confirmDuplicateDrugs(List<Map<String, dynamic>> items) async {
    if (!mounted) return false;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          title: Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                color: Colors.orange.shade700,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'พบรายการยาที่อาจซ้ำ',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'มียาในระบบที่มีข้อมูลตรงกันกับที่คุณกำลังเพิ่มอยู่แล้ว',
                    style: TextStyle(height: 1.5),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'รายการที่พบ:',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  ...items.map(
                    (e) => Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.orange.shade200),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${(e['generic_name'] ?? '').toString()}'
                            ' / ${(e['brand_name'] ?? '').toString()}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'รูปแบบ: ${(e['dosage_form'] ?? '-').toString()}'
                            ' • ความแรง: ${(e['strength'] ?? '-').toString()}',
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'ผู้ผลิต: ${(e['manufacturer'] ?? '-').toString()}',
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'หน่วย: ${(e['pack_unit'] ?? '-').toString()}'
                            ' / ${(e['base_unit'] ?? '-').toString()}'
                            ' • pack_to_base: ${(e['pack_to_base'] ?? '-').toString()}',
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'รหัสยา: ${(e['code'] ?? '-').toString()}'
                            ' • สถานะ: ${(e['status'] ?? '-').toString()}',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'คุณยืนยันจะเพิ่มรายการใหม่นี้ต่อหรือไม่?',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('กลับไปแก้ไข'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              icon: const Icon(Icons.add_circle_outline_rounded),
              label: const Text('ยืนยันเพิ่มต่อ'),
            ),
          ],
        );
      },
    );

    return result == true;
  }

  // ✅ FIX: Bottom Sheet เลือกผู้ผลิต (search ไม่พัง)
  void _showManufacturerPicker() {
    _makerSearchCtl.text = '';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final searchQuery = _makerSearchCtl.text.trim().toLowerCase();

            final filteredList = _manufacturersList.where((m) {
              if (searchQuery.isEmpty) return true;
              final name = (m['name'] ?? '').toString().toLowerCase();
              final country = (m['country'] ?? '').toString().toLowerCase();
              final phone = (m['phone'] ?? '').toString().toLowerCase();
              final fda = (m['fda_number'] ?? '').toString().toLowerCase();
              return name.contains(searchQuery) ||
                  country.contains(searchQuery) ||
                  phone.contains(searchQuery) ||
                  fda.contains(searchQuery);
            }).toList();

            return Container(
              height: MediaQuery.of(context).size.height * 0.78,
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
                          'เลือกบริษัทผู้ผลิต',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(context),
                        )
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      controller: _makerSearchCtl,
                      decoration: InputDecoration(
                        hintText: 'ค้นหา: ชื่อ/ประเทศ/โทร/เลข อย.',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _makerSearchCtl.text.trim().isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close_rounded),
                                onPressed: () {
                                  _makerSearchCtl.clear();
                                  setModalState(() {});
                                },
                              ),
                        filled: true,
                        fillColor: Colors.grey.shade100,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onChanged: (_) => setModalState(() {}),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _isLoadingManufacturers
                        ? const Center(child: CircularProgressIndicator())
                        : filteredList.isEmpty
                            ? Center(
                                child: Text(
                                  'ไม่พบรายชื่อ\nกรุณากดเพิ่มผู้ผลิตใหม่',
                                  textAlign: TextAlign.center,
                                  style:
                                      TextStyle(color: Colors.grey.shade500),
                                ),
                              )
                            : ListView.separated(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8),
                                itemCount: filteredList.length,
                                separatorBuilder: (_, __) =>
                                    const Divider(height: 1),
                                itemBuilder: (context, index) {
                                  final m = filteredList[index];
                                  return ListTile(
                                    leading: CircleAvatar(
                                      backgroundColor: Theme.of(context)
                                          .colorScheme
                                          .primary
                                          .withOpacity(0.1),
                                      child: Icon(
                                        Icons.domain_rounded,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                      ),
                                    ),
                                    title: Text(
                                      (m['name'] ?? '').toString(),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    subtitle: Text(_makerSubtitle(m)),
                                    onTap: () {
                                      setState(() {
                                        _selectedManufacturer = m;
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
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () {
                          Navigator.pop(context);
                          _showAddManufacturerDialog();
                        },
                        icon: const Icon(Icons.add_business_rounded),
                        label: const Text(
                          'เพิ่มบริษัทผู้ผลิตใหม่',
                          style: TextStyle(fontSize: 16),
                        ),
                      ),
                    ),
                  )
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showAddManufacturerDialog() {
    final formKey = GlobalKey<FormState>();
    final mName = TextEditingController();
    final mCountry = TextEditingController(text: 'ประเทศไทย');

    final mAddress = TextEditingController();
    final mPhone = TextEditingController();
    final mFda = TextEditingController();

    bool isSavingMaker = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: Row(
                children: [
                  Icon(
                    Icons.add_business_rounded,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'เพิ่มผู้ผลิตใหม่',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: mName,
                        decoration:
                            _customInputDecoration('ชื่อบริษัท / องค์กร *'),
                        validator: (v) =>
                            (v ?? '').trim().isEmpty ? 'กรุณากรอกชื่อ' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: mCountry,
                        decoration: _customInputDecoration('ประเทศ'),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: mAddress,
                        maxLines: 2,
                        decoration: _customInputDecoration('ที่อยู่บริษัท'),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: mPhone,
                        decoration: _customInputDecoration('เบอร์ติดต่อ'),
                        keyboardType: TextInputType.phone,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: mFda,
                        decoration: _customInputDecoration('เลขทะเบียน อย.'),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed:
                      isSavingMaker ? null : () => Navigator.pop(context),
                  child: const Text(
                    'ยกเลิก',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                FilledButton(
                  onPressed: isSavingMaker
                      ? null
                      : () async {
                          if (!formKey.currentState!.validate()) return;

                          setDialogState(() => isSavingMaker = true);
                          try {
                            final uid = _requireUid();

                            final payload = <String, dynamic>{
                              'owner_id': uid,
                              'name': mName.text.trim(),
                              'country': mCountry.text.trim().isEmpty
                                  ? null
                                  : mCountry.text.trim(),
                              'address': mAddress.text.trim().isEmpty
                                  ? null
                                  : mAddress.text.trim(),
                              'phone': mPhone.text.trim().isEmpty
                                  ? null
                                  : mPhone.text.trim(),
                              'fda_number': mFda.text.trim().isEmpty
                                  ? null
                                  : mFda.text.trim(),
                            };

                            final response = await _supabase
                                .from(_manufacturersTable)
                                .insert(payload)
                                .select(
                                    'id, name, country, address, phone, fda_number')
                                .single();

                            await _loadManufacturers();

                            if (!mounted) return;
                            setState(() {
                              _selectedManufacturer = response;
                            });

                            if (mounted) Navigator.pop(context);

                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('เพิ่มผู้ผลิตเรียบร้อยแล้ว'),
                              ),
                            );
                          } catch (e) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('เกิดข้อผิดพลาด: $e')),
                            );
                          } finally {
                            setDialogState(() => isSavingMaker = false);
                          }
                        },
                  child: isSavingMaker
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
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

  // ✅ เพิ่มเช็ค “กรอกครบ” ก่อนบันทึก
  bool _validateBeforeSubmit() {
    // 1) validate ฟอร์ม
    final ok = _formKey.currentState?.validate() ?? false;
    if (!ok) return false;

    // 2) เช็คผู้ผลิต (บังคับ)
    final mName = (_selectedManufacturer?['name'] ?? '').toString().trim();
    if (mName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('กรุณาเลือก “บริษัทผู้ผลิต”')),
      );
      return false;
    }

    // 3) เช็ค pack & conversion ให้ครบและถูกต้อง
    final pUnit = _packUnit.text.trim();
    final pToBase = _tryNum(_packToBase.text) ?? 0;
    if (pUnit.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('กรุณากรอก “หน่วยบรรจุ (Pack)”')),
      );
      return false;
    }
    if (pToBase <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('กรุณากรอก “1 หน่วยบรรจุ = กี่หน่วยฐาน” ให้มากกว่า 0'),
        ),
      );
      return false;
    }

    // 4) เช็คหน่วยจ่าย
    if (_units.isEmpty || !_units.any((u) => u.isDefault)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('กรุณามีหน่วยจ่ายอย่างน้อย 1 หน่วย และตั้งค่า Default'),
        ),
      );
      return false;
    }
    if (!_units.any((u) => u.isActive)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('ต้องมีอย่างน้อย 1 หน่วยที่ “เปิดใช้งาน”'),
        ),
      );
      return false;
    }

    return true;
  }
  

  Future<void> _submit() async {
    if (_saving) return;

    // ✅ ใช้ตัว validate ใหม่
    if (!_validateBeforeSubmit()) return;

    // ✅ เช็กซ้ำเฉพาะตอน "เพิ่มยาใหม่"
    if (!_isEdit) {
      try {
        final duplicateItems = await _findDuplicateDrugs();
        if (duplicateItems.isNotEmpty) {
          final confirmed = await _confirmDuplicateDrugs(duplicateItems);
          if (!confirmed) return;
        }
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('ตรวจสอบรายการซ้ำไม่สำเร็จ: $e')),
        );
        return;
      }
    }

    setState(() => _saving = true);
    await _showLoading();

    try {
      final code = _code.text.trim().isEmpty ? null : _code.text.trim();
      final packToBase = _tryNum(_packToBase.text)!; // ✅ ตอนนี้บังคับแล้ว
      final reorderPoint = _tryNum(_reorderPoint.text) ?? 0;
      final expiryDays = _tryInt(_expiryAlertDays.text) ?? 90;

      final manufacturerNameToSave =
          (_selectedManufacturer?['name'] ?? '').toString().trim();

      final units = _units.map((u) {
        return DispenseUnitInput(
          unitName: u.unitName,
          toBase: u.toBase,
          isDefault: u.isDefault,
          isActive: u.isActive,
        );
      }).toList();

      if (_isEdit) {
        await repo.updateDrugWithUnits(
          drugId: widget.drugId!,
          code: code,
          genericName: _generic.text.trim(),
          brandName: _brand.text.trim(),
          dosageForm: _dosageForm.text.trim(),
          strength: _strength.text.trim(),
          baseUnit: _baseUnit,
          packUnit: _packUnit.text.trim(),
          packToBase: packToBase,
          category: _category.text.trim(),
          manufacturer: manufacturerNameToSave,
          status: _status,
          reorderPoint: reorderPoint,
          expiryAlertDays: expiryDays,
          exampleText: _exampleText.text.trim(),
          autoDispenseLabel: _autoDispenseLabel.text.trim(),
          units: units,
        );
      } else {
        await repo.addDrugWithUnits(
          code: code,
          genericName: _generic.text.trim(),
          brandName: _brand.text.trim(),
          dosageForm: _dosageForm.text.trim(),
          strength: _strength.text.trim(),
          baseUnit: _baseUnit,
          packUnit: _packUnit.text.trim(),
          packToBase: packToBase,
          category: _category.text.trim(),
          manufacturer: manufacturerNameToSave,
          status: _status,
          reorderPoint: reorderPoint,
          expiryAlertDays: expiryDays,
          exampleText: _exampleText.text.trim(),
          autoDispenseLabel: _autoDispenseLabel.text.trim(),
          units: units,
        );
      }

      _closeLoading();
      if (!mounted) return;

      final msg = _isEdit ? 'แก้ไขข้อมูลยาเรียบร้อยแล้ว' : 'เพิ่มยาเรียบร้อยแล้ว';
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(child: Text(msg)),
              ],
            ),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );

      await Future.delayed(const Duration(milliseconds: 900));
      Navigator.of(context).pop(true);
    } catch (e) {
      _closeLoading();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('บันทึกไม่สำเร็จ: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  InputDecoration _customInputDecoration(
    String label, {
    String? helperText,
    String? hintText,
  }) {
    return InputDecoration(
      labelText: label,
      helperText: helperText,
      hintText: hintText,
      filled: true,
      fillColor: Colors.grey.shade50,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
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
        borderSide: BorderSide(
          color: Theme.of(context).colorScheme.primary,
          width: 2,
        ),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Theme.of(context).colorScheme.error),
      ),
    );
  }

  Widget _buildSectionHeader(IconData icon, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              icon,
              color: Theme.of(context).colorScheme.primary,
              size: 24,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard({required Widget child}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: child,
      ),
    );
  }

  Widget _twoCol(
    BuildContext context, {
    required Widget left,
    required Widget right,
    int rightFlex = 1,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: left),
        const SizedBox(width: 16),
        Expanded(flex: rightFlex, child: right),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingEdit) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final cs = Theme.of(context).colorScheme;
    final hint = _hintConversionText();

    final selected = _selectedManufacturer;
    final selectedName = selected?['name']?.toString();
    final selectedCountry = selected?['country']?.toString();
    final selectedPhone = selected?['phone']?.toString();
    final selectedAddress = selected?['address']?.toString();
    final selectedFda = selected?['fda_number']?.toString();

    String selectedDetailText() {
      final parts = <String>[];
      if ((selectedCountry ?? '').trim().isNotEmpty) {
        parts.add(selectedCountry!.trim());
      }
      if ((selectedPhone ?? '').trim().isNotEmpty) {
        parts.add('โทร ${selectedPhone!.trim()}');
      }
      if ((selectedFda ?? '').trim().isNotEmpty) {
        parts.add('อย. ${selectedFda!.trim()}');
      }
      if ((selectedAddress ?? '').trim().isNotEmpty) {
        parts.add(selectedAddress!.trim());
      }
      return parts.isEmpty ? '' : parts.join('\n');
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: AppBar(
        title: Text(
          _isEdit ? 'แก้ไขข้อมูลยา' : 'เพิ่มยาใหม่',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        backgroundColor: cs.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: Form(
              key: _formKey,
              child: ListView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                children: [
                  // 📦 Card 1: ข้อมูลพื้นฐาน
                  _buildCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildSectionHeader(
                          Icons.medication_rounded,
                          'ข้อมูลพื้นฐานของยา',
                        ),
                        TextFormField(
                          controller: _code,
                          decoration: _customInputDecoration(
                            'รหัสยา (ปล่อยว่างได้ เพื่อให้ระบบสร้าง MED-000x)',
                          ),
                        ),
                        const SizedBox(height: 16),
                        _twoCol(
                          context,
                          left: TextFormField(
                            controller: _generic,
                            decoration: _customInputDecoration(
                              'ชื่อสามัญ (Generic) * เช่น Paracetamol',
                            ),
                            validator: (v) => _req(v, 'กรุณากรอกชื่อสามัญ'),
                          ),
                          right: TextFormField(
                            controller: _brand,
                            decoration: _customInputDecoration(
                              'ชื่อการค้า (Brand) *',
                            ),
                            validator: (v) => _req(v, 'กรุณากรอกชื่อการค้า'),
                          ),
                        ),
                        const SizedBox(height: 16),
                        _twoCol(
                          context,
                          left: TextFormField(
                            controller: _dosageForm,
                            decoration: _customInputDecoration(
                              'รูปแบบยา * เช่น เม็ด/แคปซูล/น้ำ',
                            ),
                            validator: (v) => _req(v, 'กรุณากรอกรูปแบบยา'),
                          ),
                          right: TextFormField(
                            controller: _strength,
                            decoration: _customInputDecoration(
                              'ความแรง * เช่น 500 mg',
                            ),
                            validator: (v) => _req(v, 'กรุณากรอกความแรง'),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // 📦 Card 2: หน่วยและการบรรจุ
                  _buildCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildSectionHeader(
                          Icons.inventory_2_rounded,
                          'หน่วยและการบรรจุ',
                        ),
                        _twoCol(
  context,
  left: DropdownButtonFormField<String>(
    value: _baseUnit.isEmpty ? null : _baseUnit,
    decoration: _customInputDecoration('หน่วยฐาน (Base) *'),
    items: [
      ...[
        'เม็ด',
        'แคปซูล',
        'มล.',
        'กรัม',
        'ขวด',
        'หลอด',
        'ซอง',
        'ชิ้น',
        _baseUnit, // ⭐ รองรับหน่วยที่ผู้ใช้เพิ่ม
      ].toSet().map(
        (u) => DropdownMenuItem(
          value: u,
          child: Text(u),
        ),
      ),
      const DropdownMenuItem(
        value: '__add_new__',
        child: Row(
          children: [
            Icon(Icons.add, size: 18),
            SizedBox(width: 6),
            Text('เพิ่มหน่วยใหม่'),
          ],
        ),
      ),
    ],
    onChanged: (v) async {
      if (v == '__add_new__') {
        final ctl = TextEditingController();

        final result = await showDialog<String>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('เพิ่มหน่วยฐานใหม่'),
              content: TextField(
                controller: ctl,
                decoration: const InputDecoration(
                  labelText: 'ชื่อหน่วย เช่น Ampoule / Vial',
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('ยกเลิก'),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.pop(context, ctl.text.trim());
                  },
                  child: const Text('เพิ่ม'),
                ),
              ],
            );
          },
        );

        if (result != null && result.isNotEmpty) {
          setState(() {
            _baseUnit = result;
          });

          _applyBaseUnitAsDefault();
        }

        return;
      }

      setState(() {
        _baseUnit = v ?? 'เม็ด';
      });

      _applyBaseUnitAsDefault();
    },
  ),



                          right: TextFormField(
                            controller: _packUnit,
                            decoration: _customInputDecoration(
                              'หน่วยบรรจุ (Pack) * เช่น แผง/กล่อง',
                            ),
                            validator: (v) => _req(v, 'กรุณากรอกหน่วยบรรจุ'),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _packToBase,
                          keyboardType: TextInputType.number,
                          decoration: _customInputDecoration(
                            '1 หน่วยบรรจุ = กี่หน่วยฐาน * (เช่น 1 แผง = 10 เม็ด)',
                            helperText: hint.isEmpty ? null : hint,
                          ),
                          validator: (v) {
                            final t = (v ?? '').trim();
                            if (t.isEmpty) return 'กรุณากรอกจำนวนเทียบหน่วย';
                            final n = num.tryParse(t);
                            if (n == null || n <= 0) {
                              return 'กรุณากรอกเป็นตัวเลข > 0';
                            }
                            return null;
                          },
                        ),
                      ],
                    ),
                  ),

                  // 📦 Card 3: หน่วยจ่าย
                  _buildCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildSectionHeader(
                          Icons.rule_folder_rounded,
                          'หน่วยรับเข้า / จ่ายออก',
                        ),
                        Text(
                          '✅ ติ๊กเปิด/ปิดใช้งานหน่วยได้\n✅ ค่าเริ่มต้น (Default) เลือกได้ 1 หน่วย (ต้องเปิดใช้งานอยู่)',
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: cs.primary.withOpacity(0.05),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: cs.primary.withOpacity(0.1),
                            ),
                          ),
                          child: Column(
                            children: [
                              _twoCol(
                                context,
                                left: TextField(
                                  controller: _unitName,
                                  decoration:
                                      _customInputDecoration('ชื่อหน่วยใหม่'),
                                ),
                                right: TextField(
                                  controller: _unitToBase,
                                  keyboardType: TextInputType.number,
                                  decoration: _customInputDecoration(
                                    '1 หน่วยนี้ = กี่ $_baseUnit',
                                    hintText: 'เช่น 10',
                                  ),
                                ),
                                rightFlex: 2,
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: FilledButton.tonalIcon(
                                      onPressed: _addUnitFromInputs,
                                      icon: const Icon(Icons.add_rounded),
                                      label: const Text('เพิ่มหน่วยจ่าย'),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: _addPopularSet,
                                      icon: const Icon(
                                        Icons.auto_awesome_rounded,
                                      ),
                                      label: const Text('ดึงชุดยอดนิยม'),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        if (_units.isNotEmpty)
                          Column(
                            children: List.generate(_units.length, (i) {
                              final u = _units[i];
                              return _UnitRow(
                                unit: u,
                                baseUnit: _baseUnit,
                                onToggleActive: (v) => _toggleUnitActive(i, v),
                                onMakeDefault: () => _setDefaultUnit(i),
                                onRemove: () => _removeUnit(i),
                              );
                            }),
                          ),
                        const SizedBox(height: 16),
                        _hintCard(context),
                      ],
                    ),
                  ),

                  // 📦 Card 4: ข้อมูลเพิ่มเติม & สต็อก
                  _buildCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildSectionHeader(
                          Icons.assignment_rounded,
                          'ข้อมูลเพิ่มเติม & สต็อก',
                        ),
                        TextFormField(
                          controller: _category,
                          decoration: _customInputDecoration(
                            'หมวดหมู่ยา * เช่น แก้ปวด',
                          ),
                          validator: (v) => _req(v, 'กรุณากรอกหมวดหมู่ยา'),
                        ),
                        const SizedBox(height: 16),

                        // ผู้ผลิต (บังคับ)
                        InkWell(
                          onTap: _showManufacturerPicker,
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: selected == null
                                  ? Colors.grey.shade50
                                  : cs.primary.withOpacity(0.05),
                              border: Border.all(
                                color: selected == null
                                    ? Colors.grey.shade300
                                    : cs.primary.withOpacity(0.3),
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: selected == null
                                        ? Colors.grey.shade200
                                        : Colors.white,
                                    shape: BoxShape.circle,
                                    boxShadow: selected != null
                                        ? [
                                            BoxShadow(
                                              color:
                                                  cs.primary.withOpacity(0.1),
                                              blurRadius: 4,
                                            ),
                                          ]
                                        : [],
                                  ),
                                  child: Icon(
                                    Icons.domain_rounded,
                                    color: selected == null
                                        ? Colors.grey.shade500
                                        : cs.primary,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        selected != null
                                            ? (selectedName ?? '')
                                            : 'คลิกเพื่อเลือกบริษัทผู้ผลิต *',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: selected != null
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                          color: selected != null
                                              ? Colors.black87
                                              : Colors.grey.shade600,
                                        ),
                                      ),
                                      if (selected != null) ...[
                                        const SizedBox(height: 6),
                                        Text(
                                          selectedDetailText(),
                                          style: TextStyle(
                                            color: Colors.grey.shade700,
                                            fontSize: 13,
                                            height: 1.3,
                                          ),
                                        ),
                                      ]
                                    ],
                                  ),
                                ),
                                if (selected != null)
                                  IconButton(
                                    icon: const Icon(
                                      Icons.close_rounded,
                                      color: Colors.grey,
                                      size: 20,
                                    ),
                                    onPressed: () => setState(
                                      () => _selectedManufacturer = null,
                                    ),
                                  )
                                else
                                  Icon(
                                    Icons.chevron_right_rounded,
                                    color: Colors.grey.shade400,
                                  ),
                              ],
                            ),
                          ),
                        ),

                        const SizedBox(height: 16),
                        _twoCol(
                          context,
                          left: DropdownButtonFormField<String>(
                            value: _status,
                            decoration:
                                _customInputDecoration('สถานะการใช้งาน *'),
                            items: const [
                              DropdownMenuItem(
                                value: 'active',
                                child: Text('เปิดใช้งาน'),
                              ),
                              DropdownMenuItem(
                                value: 'inactive',
                                child: Text('ปิดใช้งาน'),
                              ),
                            ],
                            onChanged: (v) =>
                                setState(() => _status = v ?? 'active'),
                          ),
                          right: const SizedBox.shrink(),
                        ),
                        const SizedBox(height: 16),
                        _twoCol(
                          context,
                          left: TextFormField(
                            controller: _reorderPoint,
                            keyboardType: TextInputType.number,
                            decoration: _customInputDecoration(
                              'เตือนสต็อกต่ำ (หน่วยฐาน) *',
                            ),
                            validator: (v) {
                              final t = (v ?? '').trim();
                              if (t.isEmpty) {
                                return 'กรุณากรอกค่าเตือนสต็อกต่ำ';
                              }
                              final n = num.tryParse(t);
                              if (n == null || n < 0) {
                                return 'กรุณากรอกตัวเลข ≥ 0';
                              }
                              return null;
                            },
                          ),
                          right: TextFormField(
                            controller: _expiryAlertDays,
                            keyboardType: TextInputType.number,
                            decoration: _customInputDecoration(
                              'เตือนก่อนหมดอายุ (วัน) *',
                            ),
                            validator: (v) {
                              final t = (v ?? '').trim();
                              if (t.isEmpty) {
                                return 'กรุณากรอกจำนวนวันเตือนหมดอายุ';
                              }
                              final n = int.tryParse(t);
                              if (n == null || n < 0) {
                                return 'กรุณากรอกตัวเลข ≥ 0';
                              }
                              return null;
                            },
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _exampleText,
                          decoration: _customInputDecoration(
                            'ตัวอย่าง / คำแนะนำวิธีใช้ *',
                          ),
                          validator: (v) => _req(v, 'กรุณากรอกคำแนะนำวิธีใช้'),
                          maxLines: 2,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _autoDispenseLabel,
                          decoration: _customInputDecoration(
                            'ตั้งชื่อหน่วยจ่ายอัตโนมัติ (Auto dispense label) *',
                          ),
                          validator: (v) =>
                              _req(v, 'กรุณากรอก Auto dispense label'),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),

                  SizedBox(
                    height: 56,
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      onPressed: _saving ? null : _submit,
                      child: _saving
                          ? const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                ),
                                SizedBox(width: 12),
                                Text('กำลังบันทึกข้อมูล...'),
                              ],
                            )
                          : const Text('บันทึกข้อมูลยา'),
                    ),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _hintCard(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.amber.shade50,
        border: Border.all(color: Colors.amber.shade200),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lightbulb_outline, color: Colors.amber.shade700),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'คำแนะนำ:\n'
              '• หน่วยที่เปิดใช้งาน จะปรากฏในหน้า รับเข้า/จ่ายออก\n'
              '• หน่วยฐานจะถูกล็อกเป็นค่าพื้นฐาน (ปิดหรือลบไม่ได้)',
              style: TextStyle(
                color: Colors.amber.shade900,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ===== models/widgets =====

class _DispenseUnitDraft {
  final String unitName;
  final num toBase;
  final bool isDefault;
  final bool isBaseUnit;
  final bool isActive;

  _DispenseUnitDraft({
    required this.unitName,
    required this.toBase,
    required this.isDefault,
    this.isBaseUnit = false,
    required this.isActive,
  });

  _DispenseUnitDraft copyWith({
    String? unitName,
    num? toBase,
    bool? isDefault,
    bool? isBaseUnit,
    bool? isActive,
  }) {
    return _DispenseUnitDraft(
      unitName: unitName ?? this.unitName,
      toBase: toBase ?? this.toBase,
      isDefault: isDefault ?? this.isDefault,
      isBaseUnit: isBaseUnit ?? this.isBaseUnit,
      isActive: isActive ?? this.isActive,
    );
  }
}

class _UnitRow extends StatelessWidget {
  final _DispenseUnitDraft unit;
  final String baseUnit;
  final ValueChanged<bool> onToggleActive;
  final VoidCallback onMakeDefault;
  final VoidCallback onRemove;

  const _UnitRow({
    required this.unit,
    required this.baseUnit,
    required this.onToggleActive,
    required this.onMakeDefault,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Switch(
              value: unit.isActive,
              onChanged: unit.isBaseUnit ? null : onToggleActive,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    unit.unitName,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  Text(
                    unit.isBaseUnit
                        ? 'หน่วยฐาน (Base Unit)'
                        : '1 ${unit.unitName} = ${unit.toBase} $baseUnit',
                    style: TextStyle(
                      color: Colors.grey.shade600,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            if (unit.isActive)
              ChoiceChip(
                label: const Text('Default'),
                selected: unit.isDefault,
                onSelected: (val) {
                  if (val) onMakeDefault();
                },
                selectedColor:
                    Theme.of(context).colorScheme.primaryContainer,
              ),
            const SizedBox(width: 8),
            if (!unit.isBaseUnit)
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                onPressed: onRemove,
              ),
          ],
        ),
      ),
    );
  }
}