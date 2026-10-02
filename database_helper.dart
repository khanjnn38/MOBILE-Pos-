import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseHelper {
  static const _databaseName = "ElectroHisab.db";
  static const _databaseVersion = 3; // Migration v1 -> v2 -> v3

  DatabaseHelper._privateConstructor();
  static final DatabaseHelper instance = DatabaseHelper._privateConstructor();

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    String path = join(await getDatabasesPath(), _databaseName);
    return await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future _onCreate(Database db, int version) async {
    // 1. Products Table (Electrical & Home Appliances)
    await db.execute('''
      CREATE TABLE products (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        category TEXT NOT NULL,
        brand TEXT,
        model TEXT,
        barcode TEXT,
        serial_number TEXT,
        unit TEXT DEFAULT 'Piece',
        size TEXT,
        color TEXT,
        blade_quantity INTEGER,
        capacity_kg REAL,
        machine_type TEXT,
        wattage TEXT,
        light_type TEXT,
        color_temperature TEXT,
        ampere_rating TEXT,
        pole_type TEXT,
        specification TEXT,
        cable_type TEXT,
        cable_size TEXT,
        roll_length_meters REAL,
        purchase_price REAL NOT NULL,
        sale_price REAL NOT NULL,
        quantity REAL NOT NULL,
        min_stock_alert REAL DEFAULT 2,
        warranty_duration TEXT,
        warranty_expiry_date TEXT,
        notes TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    // 2. Sales Table
    await db.execute('''
      CREATE TABLE sales (
        id TEXT PRIMARY KEY,
        receipt_number TEXT UNIQUE NOT NULL,
        customer_id TEXT,
        customer_name TEXT NOT NULL,
        customer_phone TEXT,
        subtotal REAL NOT NULL,
        discount REAL DEFAULT 0,
        total_amount REAL NOT NULL,
        paid_amount REAL NOT NULL,
        remaining_amount REAL NOT NULL,
        payment_method TEXT NOT NULL,
        notes TEXT,
        created_at TEXT NOT NULL
      )
    ''');

    // 3. Sale Items Table
    await db.execute('''
      CREATE TABLE sale_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sale_id TEXT NOT NULL,
        product_id TEXT NOT NULL,
        product_name TEXT NOT NULL,
        brand TEXT,
        serial_number TEXT,
        unit TEXT DEFAULT 'Piece',
        spec_summary TEXT,
        unit_cost_price REAL NOT NULL,
        unit_sale_price REAL NOT NULL,
        quantity INTEGER NOT NULL,
        total_price REAL NOT NULL,
        warranty TEXT,
        FOREIGN KEY (sale_id) REFERENCES sales (id) ON DELETE CASCADE
      )
    ''');

    // 4. Customers Table (Khata)
    await db.execute('''
      CREATE TABLE customers (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        phone TEXT,
        address TEXT,
        balance REAL DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');

    // 5. Suppliers Table
    await db.execute('''
      CREATE TABLE suppliers (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        phone TEXT,
        market_address TEXT,
        balance REAL DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');

    // 6. Purchases Table
    await db.execute('''
      CREATE TABLE purchases (
        id TEXT PRIMARY KEY,
        invoice_number TEXT NOT NULL,
        supplier_id TEXT NOT NULL,
        supplier_name TEXT NOT NULL,
        total_amount REAL NOT NULL,
        paid_amount REAL NOT NULL,
        remaining_amount REAL NOT NULL,
        payment_method TEXT NOT NULL,
        date TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');

    // 7. Ledger Transactions Table
    await db.execute('''
      CREATE TABLE ledger (
        id TEXT PRIMARY KEY,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        entity_name TEXT NOT NULL,
        type TEXT NOT NULL,
        reference_id TEXT,
        debit REAL NOT NULL,
        credit REAL NOT NULL,
        running_balance REAL NOT NULL,
        description TEXT NOT NULL,
        date TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');

    // 8. Expenses Table
    await db.execute('''
      CREATE TABLE expenses (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        category TEXT NOT NULL,
        amount REAL NOT NULL,
        payment_method TEXT NOT NULL,
        date TEXT NOT NULL,
        notes TEXT,
        created_at TEXT NOT NULL
      )
    ''');

    // 9. Stock Movement Audit Trail Table
    await db.execute('''
      CREATE TABLE stock_movements (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL,
        product_name TEXT NOT NULL,
        type TEXT NOT NULL,
        quantity_delta INTEGER NOT NULL,
        new_stock_level INTEGER NOT NULL,
        reference_number TEXT,
        reason TEXT,
        created_at TEXT NOT NULL
      )
    ''');

    // 10. Sale Returns Table
    await db.execute('''
      CREATE TABLE sale_returns (
        id TEXT PRIMARY KEY,
        sale_id TEXT NOT NULL,
        receipt_number TEXT NOT NULL,
        customer_id TEXT,
        customer_name TEXT NOT NULL,
        total_refund REAL NOT NULL,
        refund_method TEXT NOT NULL,
        reason TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');

    // Create Indexes for instant lookups
    await db.execute('CREATE INDEX idx_products_imei ON products (imei_or_serial)');
    await db.execute('CREATE INDEX idx_products_barcode ON products (barcode)');
    await db.execute('CREATE INDEX idx_sales_receipt ON sales (receipt_number)');
  }

  // Database Migration (v1 -> v2 -> v3)
  Future _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      try {
        await db.execute("ALTER TABLE products ADD COLUMN pta_status TEXT DEFAULT 'PTA Approved'");
      } catch (_) {}
    }
    if (oldVersion < 3) {
      try {
        await db.execute("ALTER TABLE products ADD COLUMN brand TEXT");
        await db.execute("ALTER TABLE products ADD COLUMN model TEXT");
        await db.execute("ALTER TABLE products ADD COLUMN warranty_expiry_date TEXT");
        await db.execute('''
          CREATE TABLE IF NOT EXISTS stock_movements (
            id TEXT PRIMARY KEY,
            product_id TEXT NOT NULL,
            product_name TEXT NOT NULL,
            type TEXT NOT NULL,
            quantity_delta INTEGER NOT NULL,
            new_stock_level INTEGER NOT NULL,
            reference_number TEXT,
            reason TEXT,
            created_at TEXT NOT NULL
          )
        ''');
      } catch (_) {}
    }
  }

  // Atomic Stock Adjustment Transaction
  Future<void> adjustStock(String productId, int quantityDelta, String reason) async {
    final db = await database;
    await db.transaction((txn) async {
      final List<Map<String, dynamic>> res = await txn.query(
        'products',
        columns: ['quantity', 'name'],
        where: 'id = ?',
        whereArgs: [productId],
      );
      if (res.isNotEmpty) {
        final currentQty = res.first['quantity'] as int;
        final name = res.first['name'] as String;
        final newQty = currentQty + quantityDelta;
        if (newQty < 0) {
          throw Exception("Cannot reduce stock below zero");
        }
        await txn.update(
          'products',
          {'quantity': newQty, 'updated_at': DateTime.now().toIso8601String()},
          where: 'id = ?',
          whereArgs: [productId],
        );
        await txn.insert('stock_movements', {
          'id': 'sm-' + DateTime.now().millisecondsSinceEpoch.toString(),
          'product_id': productId,
          'product_name': name,
          'type': quantityDelta > 0 ? 'restock' : 'sale_deduction',
          'quantity_delta': quantityDelta,
          'new_stock_level': newQty,
          'reason': reason,
          'created_at': DateTime.now().toIso8601String(),
        });
      }
    });
  }
}
