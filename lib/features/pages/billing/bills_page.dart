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

  List<Map<String, dynamic>> stockIn = [];
  List<Map<String, dynamic>> stockOut = [];

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    load();
  }

  Future<void> load() async {
    final inRows = await sb.from('stock_in_receipts').select('''
      id,
      supplier_name,
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
        drugs(generic_name,brand_name,base_unit)
      )
    ''').order('received_at', ascending: false);

    final outRows = await sb.from('stock_out_receipts').select('''
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
        drugs(generic_name,brand_name,base_unit)
      )
    ''').order('sold_at', ascending: false);

    stockIn = List<Map<String, dynamic>>.from(inRows);
    stockOut = List<Map<String, dynamic>>.from(outRows);

    setState(() {
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("บิลการทำรายการ"),
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: "บิลรับยาเข้า"),
            Tab(text: "บิลจ่ายยาออก"),
          ],
        ),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tab,
              children: [
                _stockInBills(),
                _stockOutBills(),
              ],
            ),
    );
  }

  // =============================
  // STOCK IN BILL
  // =============================

  Widget _stockInBills() {
    return ListView.builder(
      itemCount: stockIn.length,
      itemBuilder: (c, i) {
        final r = stockIn[i];
        final items = r['stock_in_items'] ?? [];

        return Card(
          margin: const EdgeInsets.all(12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "ใบรับสินค้า",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 6),
                Text("Supplier : ${r['supplier_name'] ?? '-'}"),
                Text("Invoice : ${r['invoice_no'] ?? '-'}"),
                Text("PO : ${r['po_no'] ?? '-'}"),
                Text("วันที่รับ : ${r['received_at']}"),
                const Divider(height: 20),

                const Text(
                  "รายการสินค้า",
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),

                const SizedBox(height: 8),

                ...items.map<Widget>((it) {
                  final d = it['drugs'] ?? {};

                  final name =
                      "${d['generic_name']} (${d['brand_name'] ?? ''})";

                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(flex: 3, child: Text(name)),
                        Expanded(
                            child: Text(
                                "${it['base_qty']} ${d['base_unit']}")),
                        Expanded(child: Text("Lot ${it['lot_no']}")),
                        Expanded(child: Text("EXP ${it['exp_date']}")),
                        Expanded(child: Text("Cost ${it['cost_per_base']}")),
                      ],
                    ),
                  );
                }).toList(),

                if (r['note'] != null) ...[
                  const SizedBox(height: 10),
                  Text("Note : ${r['note']}"),
                ]
              ],
            ),
          ),
        );
      },
    );
  }

  // =============================
  // STOCK OUT BILL
  // =============================

  Widget _stockOutBills() {
    return ListView.builder(
      itemCount: stockOut.length,
      itemBuilder: (c, i) {
        final r = stockOut[i];
        final items = r['stock_out_items'] ?? [];

        num total = 0;
        for (final it in items) {
          total += it['line_total'] ?? 0;
        }

        return Card(
          margin: const EdgeInsets.all(12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "ใบจ่ายยา",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 6),
                Text("ผู้ป่วย : ${r['patient_name'] ?? '-'}"),
                Text("วันที่จ่ายยา : ${r['sold_at']}"),

                const Divider(height: 20),

                ...items.map<Widget>((it) {
                  final d = it['drugs'] ?? {};
                  final name =
                      "${d['generic_name']} (${d['brand_name'] ?? ''})";

                  return Row(
                    children: [
                      Expanded(flex: 3, child: Text(name)),
                      Expanded(
                          child: Text(
                              "${it['qty_base']} ${d['base_unit']}")),
                      Expanded(child: Text("${it['sell_per_base']}")),
                      Expanded(child: Text("${it['line_total']}")),
                    ],
                  );
                }).toList(),

                const Divider(height: 20),

                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    "รวม ${total.toStringAsFixed(2)} บาท",
                    style: const TextStyle(
                        fontWeight: FontWeight.w900, fontSize: 16),
                  ),
                )
              ],
            ),
          ),
        );
      },
    );
  }
}