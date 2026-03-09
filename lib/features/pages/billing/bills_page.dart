import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class BillsPage extends StatefulWidget {
  const BillsPage({super.key});

  @override
  State<BillsPage> createState() => _BillsPageState();
}

class _BillsPageState extends State<BillsPage>
    with SingleTickerProviderStateMixin {
  final SupabaseClient sb = Supabase.instance.client;

  late TabController _tab;

  bool loading = true;
  String? errorText;

  Map<String, dynamic>? profile;

  List<Map<String, dynamic>> stockIn = [];
  List<Map<String, dynamic>> stockOut = [];

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    load();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      errorText = null;
    });

    try {
      final uid = sb.auth.currentUser?.id;
      if (uid == null) throw Exception('User not signed in');

      final results = await Future.wait([
        sb
            .from('profiles')
            .select('shop_name, full_name, display_name, phone')
            .eq('id', uid)
            .maybeSingle(),
        sb.from('stock_in_receipts').select('''
              id,
              supplier_name,
              delivery_note_no,
              invoice_no,
              po_no,
              note,
              received_at,
              stock_in_items(
                lot_no,
                exp_date,
                base_qty,
                cost_per_base,
                sell_per_base,
                drugs(generic_name, brand_name, base_unit)
              )
            ''').order('received_at', ascending: false),
        sb.from('stock_out_receipts').select('''
              id,
              patient_name,
              sold_at,
              note,
              stock_out_items(
                qty_base,
                sell_per_base,
                line_total,
                lot_no,
                exp_date,
                drugs(generic_name, brand_name, base_unit)
              )
            ''').order('sold_at', ascending: false),
      ]);

      profile = results[0] as Map<String, dynamic>?;
      stockIn = List<Map<String, dynamic>>.from(results[1] as List);
      stockOut = List<Map<String, dynamic>>.from(results[2] as List);

      if (!mounted) return;
      setState(() {
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        errorText = e.toString();
      });
    }
  }

  String _shopName() {
    final p = profile ?? {};
    return (p['shop_name']?.toString().trim().isNotEmpty ?? false)
        ? p['shop_name'].toString().trim()
        : ((p['display_name']?.toString().trim().isNotEmpty ?? false)
            ? p['display_name'].toString().trim()
            : ((p['full_name']?.toString().trim().isNotEmpty ?? false)
                ? p['full_name'].toString().trim()
                : 'ร้านขายยา'));
  }

  String _shopPhone() {
    final p = profile ?? {};
    return (p['phone'] ?? '').toString().trim();
  }

  String _dateOnly(dynamic value) {
    if (value == null) return '-';
    try {
      final dt = DateTime.parse(value.toString()).toLocal();
      final d = dt.day.toString().padLeft(2, '0');
      final m = dt.month.toString().padLeft(2, '0');
      final y = dt.year.toString();
      return '$d/$m/$y';
    } catch (_) {
      return value.toString();
    }
  }

  String _dateTime(dynamic value) {
    if (value == null) return '-';
    try {
      final dt = DateTime.parse(value.toString()).toLocal();
      final d = dt.day.toString().padLeft(2, '0');
      final m = dt.month.toString().padLeft(2, '0');
      final y = dt.year.toString();
      final hh = dt.hour.toString().padLeft(2, '0');
      final mm = dt.minute.toString().padLeft(2, '0');
      return '$d/$m/$y $hh:$mm';
    } catch (_) {
      return value.toString();
    }
  }

  String _money(num? value) {
    final n = value ?? 0;
    return n.toStringAsFixed(2);
  }

  num _toNum(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v;
    return num.tryParse(v.toString()) ?? 0;
  }

  String _shortReceiptNo(String prefix, String? id, dynamic date) {
    final d = _dateOnly(date);
    final datePart = d == '-'
        ? '00000000'
        : d.split('/').reversed.join('').substring(2); // yyyymmdd -> 260309

    final raw = (id ?? '').replaceAll('-', '');
    final tail = raw.length >= 4 ? raw.substring(raw.length - 4) : raw.padLeft(4, '0');

    return '$prefix-$datePart-$tail';
  }

  String _drugName(Map<String, dynamic> drug) {
    final generic = (drug['generic_name'] ?? '').toString().trim();
    final brand = (drug['brand_name'] ?? '').toString().trim();

    if (brand.isEmpty) return generic.isEmpty ? '-' : generic;
    if (generic.isEmpty) return brand;
    return '$generic ($brand)';
  }

  num _stockInLineAmount(Map<String, dynamic> item) {
    return _toNum(item['base_qty']) * _toNum(item['cost_per_base']);
  }

  num _stockOutLineAmount(Map<String, dynamic> item) {
    final line = _toNum(item['line_total']);
    if (line > 0) return line;
    return _toNum(item['qty_base']) * _toNum(item['sell_per_base']);
  }

  num _stockInTotal(List items) {
    num total = 0;
    for (final raw in items) {
      final it = Map<String, dynamic>.from(raw as Map);
      total += _stockInLineAmount(it);
    }
    return total;
  }

  num _stockOutTotal(List items) {
    num total = 0;
    for (final raw in items) {
      final it = Map<String, dynamic>.from(raw as Map);
      total += _stockOutLineAmount(it);
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('บิลการทำรายการ'),
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: 'บิลรับยาเข้า'),
            Tab(text: 'บิลจ่ายยาออก'),
          ],
        ),
        actions: [
          IconButton(
            onPressed: load,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'รีเฟรช',
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : errorText != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      errorText!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                )
              : TabBarView(
                  controller: _tab,
                  children: [
                    _stockInBills(),
                    _stockOutBills(),
                  ],
                ),
    );
  }

  Widget _stockInBills() {
    if (stockIn.isEmpty) {
      return const Center(child: Text('ยังไม่มีบิลรับยาเข้า'));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: stockIn.length,
      itemBuilder: (context, index) {
        final r = stockIn[index];
        final items = List<Map<String, dynamic>>.from(
          (r['stock_in_items'] as List? ?? []).map((e) => Map<String, dynamic>.from(e)),
        );
        final total = _stockInTotal(items);

        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: _billPaper(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _billHeader(
                  title: 'ใบรับสินค้า',
                  billNo: _shortReceiptNo(
                    'BIN',
                    r['id']?.toString(),
                    r['received_at'],
                  ),
                  trxDate: _dateOnly(r['received_at']),
                ),
                const SizedBox(height: 16),
                _infoBlock(
                  left: [
                    _kv('ร้าน/ผู้รับ', _shopName()),
                    _kv('โทรศัพท์', _shopPhone().isEmpty ? '-' : _shopPhone()),
                  ],
                  right: [
                    _kv('ผู้จำหน่าย', (r['supplier_name'] ?? '-').toString()),
                    _kv('วันที่รับ', _dateTime(r['received_at'])),
                  ],
                ),
                const SizedBox(height: 10),
                _infoBlock(
                  left: [
                    _kv('เลขที่ใบส่งของ', (r['delivery_note_no'] ?? '-').toString()),
                    _kv('เลขที่ Invoice', (r['invoice_no'] ?? '-').toString()),
                  ],
                  right: [
                    _kv('เลขที่ PO', (r['po_no'] ?? '-').toString()),
                    _kv('หมายเหตุ', (r['note'] ?? '-').toString()),
                  ],
                ),
                const SizedBox(height: 16),
                _stockInTable(items),
                const SizedBox(height: 14),
                _summaryBox(
                  rows: [
                    ['รวมเงิน', _money(total)],
                    ['เป็นเงินทั้งสิ้น', _money(total)],
                  ],
                ),
                const SizedBox(height: 24),
                _signatureRow(
                  leftTitle: 'ผู้รับสินค้า',
                  rightTitle: 'ผู้บันทึกรายการ',
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _stockOutBills() {
    if (stockOut.isEmpty) {
      return const Center(child: Text('ยังไม่มีบิลจ่ายยาออก'));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: stockOut.length,
      itemBuilder: (context, index) {
        final r = stockOut[index];
        final items = List<Map<String, dynamic>>.from(
          (r['stock_out_items'] as List? ?? []).map((e) => Map<String, dynamic>.from(e)),
        );
        final total = _stockOutTotal(items);

        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: _billPaper(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _billHeader(
                  title: 'ใบจ่ายยา / ใบเสร็จรับเงิน',
                  billNo: _shortReceiptNo(
                    'BOUT',
                    r['id']?.toString(),
                    r['sold_at'],
                  ),
                  trxDate: _dateOnly(r['sold_at']),
                ),
                const SizedBox(height: 16),
                _infoBlock(
                  left: [
                    _kv('ร้าน/ผู้ขาย', _shopName()),
                    _kv('โทรศัพท์', _shopPhone().isEmpty ? '-' : _shopPhone()),
                  ],
                  right: [
                    _kv('ชื่อลูกค้า/ผู้ป่วย', (r['patient_name'] ?? '-').toString()),
                    _kv('วันที่จ่ายยา', _dateTime(r['sold_at'])),
                  ],
                ),
                const SizedBox(height: 10),
                _infoBlock(
                  left: [
                    _kv('หมายเหตุ', (r['note'] ?? '-').toString()),
                  ],
                  right: const [],
                ),
                const SizedBox(height: 16),
                _stockOutTable(items),
                const SizedBox(height: 14),
                _summaryBox(
                  rows: [
                    ['รวมเงิน', _money(total)],
                    ['เป็นเงินทั้งสิ้น', _money(total)],
                  ],
                ),
                const SizedBox(height: 24),
                _signatureRow(
                  leftTitle: 'ผู้รับยา',
                  rightTitle: 'ผู้จ่ายยา',
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _billPaper({required Widget child}) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: Colors.black54, width: 1),
            borderRadius: BorderRadius.circular(6),
            boxShadow: const [
              BoxShadow(
                blurRadius: 8,
                offset: Offset(0, 2),
                color: Color(0x14000000),
              ),
            ],
          ),
          child: DefaultTextStyle(
            style: const TextStyle(
              color: Colors.black87,
              fontSize: 14,
              height: 1.35,
            ),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _billHeader({
    required String title,
    required String billNo,
    required String trxDate,
  }) {
    final printedAt = _dateOnly(DateTime.now().toIso8601String());

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            _shopName(),
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          flex: 2,
          child: Column(
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'เลขที่บิล $billNo',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('วันที่พิมพ์ $printedAt'),
              const SizedBox(height: 2),
              Text('วันที่ทำรายการ $trxDate'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _infoBlock({
    required List<Widget> left,
    required List<Widget> right,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: left,
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: right,
            ),
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: RichText(
        text: TextSpan(
          style: const TextStyle(color: Colors.black87, fontSize: 14),
          children: [
            TextSpan(
              text: '$k : ',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            TextSpan(text: v.isEmpty ? '-' : v),
          ],
        ),
      ),
    );
  }

  Widget _tableHeader(List<_Col> cols) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Colors.black87, width: 1),
          bottom: BorderSide(color: Colors.black87, width: 1),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: cols.map((c) {
          return Expanded(
            flex: c.flex,
            child: Text(
              c.title,
              textAlign: c.align,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 14,
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _tableRow(List<_Cell> cells, {bool last = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: last ? Colors.black87 : Colors.black12,
            width: last ? 1 : 0.8,
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: cells.map((c) {
          return Expanded(
            flex: c.flex,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                c.text,
                textAlign: c.align,
                style: const TextStyle(fontSize: 14),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _stockInTable(List<Map<String, dynamic>> items) {
    final cols = <_Col>[
      _Col('ลำดับ', 1, TextAlign.center),
      _Col('รายการ', 5, TextAlign.left),
      _Col('จำนวน', 2, TextAlign.right),
      _Col('หน่วย', 2, TextAlign.center),
      _Col('Lot', 2, TextAlign.center),
      _Col('EXP', 2, TextAlign.center),
      _Col('ราคา', 2, TextAlign.right),
      _Col('จำนวนเงิน', 2, TextAlign.right),
    ];

    return Column(
      children: [
        _tableHeader(cols),
        if (items.isEmpty)
          _tableRow(
            const [
              _Cell('-', 1, TextAlign.center),
              _Cell('ไม่มีรายการ', 17, TextAlign.center),
            ],
            last: true,
          )
        else
          ...List.generate(items.length, (index) {
            final it = items[index];
            final d = Map<String, dynamic>.from(it['drugs'] ?? {});
            final amount = _stockInLineAmount(it);

            return _tableRow(
              [
                _Cell('${index + 1}', 1, TextAlign.center),
                _Cell(_drugName(d), 5, TextAlign.left),
                _Cell(_toNum(it['base_qty']).toString(), 2, TextAlign.right),
                _Cell((d['base_unit'] ?? '-').toString(), 2, TextAlign.center),
                _Cell((it['lot_no'] ?? '-').toString(), 2, TextAlign.center),
                _Cell(_dateOnly(it['exp_date']), 2, TextAlign.center),
                _Cell(_money(_toNum(it['cost_per_base'])), 2, TextAlign.right),
                _Cell(_money(amount), 2, TextAlign.right),
              ],
              last: index == items.length - 1,
            );
          }),
      ],
    );
  }

  Widget _stockOutTable(List<Map<String, dynamic>> items) {
    final cols = <_Col>[
      _Col('ลำดับ', 1, TextAlign.center),
      _Col('รายการ', 7, TextAlign.left),
      _Col('จำนวน', 2, TextAlign.right),
      _Col('หน่วย', 2, TextAlign.center),
      _Col('ราคา', 2, TextAlign.right),
      _Col('จำนวนเงิน', 2, TextAlign.right),
    ];

    return Column(
      children: [
        _tableHeader(cols),
        if (items.isEmpty)
          _tableRow(
            const [
              _Cell('-', 1, TextAlign.center),
              _Cell('ไม่มีรายการ', 15, TextAlign.center),
            ],
            last: true,
          )
        else
          ...List.generate(items.length, (index) {
            final it = items[index];
            final d = Map<String, dynamic>.from(it['drugs'] ?? {});
            final amount = _stockOutLineAmount(it);

            return _tableRow(
              [
                _Cell('${index + 1}', 1, TextAlign.center),
                _Cell(_drugName(d), 7, TextAlign.left),
                _Cell(_toNum(it['qty_base']).toString(), 2, TextAlign.right),
                _Cell((d['base_unit'] ?? '-').toString(), 2, TextAlign.center),
                _Cell(_money(_toNum(it['sell_per_base'])), 2, TextAlign.right),
                _Cell(_money(amount), 2, TextAlign.right),
              ],
              last: index == items.length - 1,
            );
          }),
      ],
    );
  }

  Widget _summaryBox({required List<List<String>> rows}) {
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 330),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.black87),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            children: rows.map((r) {
              final isLast = r == rows.last;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        r[0],
                        style: TextStyle(
                          fontWeight: isLast ? FontWeight.w800 : FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '${r[1]} บาท',
                      style: TextStyle(
                        fontWeight: isLast ? FontWeight.w800 : FontWeight.w600,
                        fontSize: isLast ? 15 : 14,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  Widget _signatureRow({
    required String leftTitle,
    required String rightTitle,
  }) {
    return Row(
      children: [
        Expanded(child: _signatureBox(leftTitle)),
        const SizedBox(width: 24),
        Expanded(child: _signatureBox(rightTitle)),
      ],
    );
  }

  Widget _signatureBox(String title) {
    return Column(
      children: [
        const SizedBox(height: 20),
        Container(
          width: double.infinity,
          height: 1,
          color: Colors.black54,
        ),
        const SizedBox(height: 6),
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

class _Col {
  final String title;
  final int flex;
  final TextAlign align;

  _Col(this.title, this.flex, this.align);
}

class _Cell {
  final String text;
  final int flex;
  final TextAlign align;

  const _Cell(this.text, this.flex, this.align);
}