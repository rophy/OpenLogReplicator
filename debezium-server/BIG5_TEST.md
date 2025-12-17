# Testing Legacy Chinese (BIG5) Encoding with Debezium

This document describes how to test Debezium CDC behavior with legacy Big5-encoded Chinese characters stored in an Oracle US7ASCII database, and how to use the custom SMT to decode them.

## Background

Many legacy Oracle databases use `US7ASCII` character set but store multi-byte Chinese characters (Big5 or GB2312) directly as raw bytes. This was a common practice before Unicode adoption.

**Challenge:** CDC tools like Debezium assume a specific encoding when reading VARCHAR2 columns. When the actual encoding differs from what Debezium expects, the output appears garbled.

### How Oracle JDBC Handles High Bytes

Oracle JDBC converts bytes >= 0x80 (high bytes) to Unicode codepoints in the "halfwidth" range (0xFF00-0xFFFF). For example:

| Original Byte | Unicode Codepoint | Display |
|---------------|-------------------|---------|
| 0xB4 | U+FF34 (0xFF00 + 0xB4) | ﾴ |
| 0xFA | U+FF7A (0xFF00 + 0xFA) | ￺ |
| 0xA4 | U+FF24 (0xFF00 + 0xA4) | ﾤ |

This means the original bytes can be recovered by subtracting 0xFF00 from codepoints >= 0xFF00.

## Solution: Legacy Charset SMT

We've implemented a Single Message Transform (SMT) that automatically decodes legacy charset strings (BIG5, GB2312, GBK, etc.) to Unicode in the Debezium pipeline.

### How It Works

1. Oracle JDBC converts high bytes to Unicode halfwidth range (0xFFxx)
2. The SMT intercepts specified columns in matching tables
3. Recovers original bytes: `byte = codepoint - 0xFF00` for codepoints >= 0xFF00
4. Decodes recovered bytes using the specified source encoding
5. Outputs Unicode (UTF-8) strings for downstream consumers

### Building the SMT

```bash
cd smt
./build.sh
```

This creates `target/legacy-charset-smt-1.0.0.jar`.

### Configuration

The SMT is configured in `config/application.properties`:

```properties
# SMT Configuration (Legacy Charset Transform)
debezium.transforms=legacycharset
debezium.transforms.legacycharset.type=com.example.debezium.smt.LegacyCharsetTransform
debezium.transforms.legacycharset.encoding=BIG5
debezium.transforms.legacycharset.columns=NAME,DESCRIPTION
debezium.transforms.legacycharset.tables=.*\\.USR1\\.ADAM1,.*\\.USR1\\.CUSTOMERS
```

The JAR is mounted in `docker-compose.yaml`:

```yaml
debezium-server:
  volumes:
    - ./smt/target/legacy-charset-smt-1.0.0.jar:/debezium/lib/legacy-charset-smt-1.0.0.jar:ro
```

## Test Setup

### Prerequisites

- Running Oracle container with `ORACLE_CHARACTERSET=US7ASCII`
- Python 3 with `oracledb` package
- Debezium Server configured and running
- SMT JAR built

### Install Python Oracle Driver

```bash
pip install oracledb
```

## Test Files

| File | Description |
|------|-------------|
| `test-encoding.py` | Python script to insert UTF-8 and BIG5 encoded text |
| `test-big5.txt` | Sample Chinese text in UTF-8 |
| `test-big5-encoded.txt` | Same text encoded in BIG5 |
| `smt/` | Big5 Decoder SMT source code |

## Running the Test

### Step 1: Build the SMT

```bash
cd smt
./build.sh
cd ..
```

### Step 2: Start the Pipeline

```bash
docker compose up -d
```

### Step 3: Verify Big5 Test File

```bash
# View original UTF-8 text
cat test-big5.txt

# Convert BIG5 back to UTF-8 to verify encoding
iconv -f BIG5 -t UTF-8 test-big5-encoded.txt

# Compare byte sizes (BIG5 = 2 bytes/char, UTF-8 = 3 bytes/char for CJK)
wc -c test-big5.txt test-big5-encoded.txt
```

### Step 4: Run the Encoding Test Script

```bash
python3 test-encoding.py
```

This script:
1. Connects to Oracle on `localhost:1521/XEPDB1`
2. Inserts 3 rows with UTF-8 encoded Chinese (IDs 10-12)
3. Inserts 3 rows with BIG5 encoded Chinese (IDs 20-22)
4. Queries and displays all rows with hex values

### Step 5: Check Debezium Output

```bash
# Wait for processing
sleep 10

# Check captured events
cat output/events.json
```

## Expected Results

### Oracle Query Output

```
ID   COUNT  HEX                            Decoded UTF-8        Decoded BIG5
---- ------ ------------------------------ -------------------- --------------------
1    100    496E697469616C20526F77         Initial Row          Initial Row
10   1000   E6B8ACE8A9A6E4B8ADE69687       測試中文             (invalid)
11   1100   E4BDA0E5A5BDE4B896E7958C       你好世界             (invalid)
12   1200   E58FB0E58C97E5B882             台北市               (invalid)
20   2000   B4FAB8D5A4A4A4E5               (invalid)            測試中文
21   2100   A741A66EA540ACC9               (invalid)            你好世界
22   2200   A578A55FA5AB                   (invalid)            台北市
```

**Key observations:**
- UTF-8 rows (10-12): 12 bytes for 4 characters (3 bytes each)
- BIG5 rows (20-22): 8 bytes for 4 characters (2 bytes each)
- Each encoding only decodes correctly with its matching decoder

### Debezium Output WITH SMT

With the Big5 Decoder SMT enabled, the BIG5 encoded rows are correctly decoded:

| ID | Encoding | Raw (Garbled) | SMT Decoded |
|----|----------|---------------|-------------|
| 10-12 | UTF-8 | ￦ﾸﾬ￨ﾩﾦ... | (garbage - wrong encoding) |
| 20 | BIG5 | ﾴ￺ﾸￕﾤﾤﾤ￥ | **測試中文** |
| 21 | BIG5 | ﾧAﾦnﾥ@ﾬ￉ | **你好世界** |
| 22 | BIG5 | ﾥxﾥ_ﾥﾫ | **台北市** |

The SMT logs show the transformations:
```
[LegacyCharsetTransform] Decoded NAME: 'ﾴ￺ﾸￕﾤﾤﾤ￥' -> '測試中文'
[LegacyCharsetTransform] Decoded NAME: 'ﾧAﾦnﾥ@ﾬ￉' -> '你好世界'
[LegacyCharsetTransform] Decoded NAME: 'ﾥxﾥ_ﾥﾫ' -> '台北市'
```

## Encoding Comparison

| Text | UTF-8 Hex | UTF-8 Bytes | BIG5 Hex | BIG5 Bytes |
|------|-----------|-------------|----------|------------|
| 測試中文 | E6B8AC E8A9A6 E4B8AD E69687 | 12 | B4FA B8D5 A4A4 A4E5 | 8 |
| 你好世界 | E4BDA0 E5A5BD E4B896 E7958C | 12 | A741 A66E A540 ACC9 | 8 |
| 台北市 | E58FB0 E58C97 E5B882 | 9 | A578 A55F A5AB | 6 |
| 許功蓋 | E8A8B1 E58A9F E89B8B | 9 | B3 5C A5 5C BB 5C | 6 |

Note: Characters like 許功蓋 contain 0x5C (backslash) bytes in BIG5, which can cause issues in some contexts.

## Handling Approaches

### Option 1: SMT (Recommended for BIG5-only columns)

Use the Big5 Decoder SMT as configured above. This is the cleanest solution when all data in a column uses BIG5 encoding.

**Limitations:** If the column contains mixed encodings (some rows UTF-8, some BIG5), the SMT will decode everything as BIG5.

### Option 2: Consumer-Side Decoding

If you can't use the SMT, decode in your consumer application:

```python
def recover_bytes_from_debezium(garbled: str) -> bytes:
    """Recover original bytes from Oracle JDBC's halfwidth conversion."""
    recovered = []
    for char in garbled:
        cp = ord(char)
        if cp >= 0xFF00:
            recovered.append(cp - 0xFF00)
        else:
            recovered.append(cp)
    return bytes(recovered)

# Usage
raw_bytes = recover_bytes_from_debezium(debezium_event['after']['NAME'])
chinese_text = raw_bytes.decode('big5')  # or 'utf-8'
```

### Option 3: Use Oracle AL32UTF8 Character Set

Convert database to Unicode (requires migration):
```sql
-- Requires database recreation or migration
ALTER DATABASE CHARACTER SET AL32UTF8;
```

### Option 4: Store as RAW/BLOB

Store binary data explicitly:
```sql
CREATE TABLE data (
    id NUMBER,
    name_raw RAW(100),
    encoding VARCHAR2(10)  -- 'UTF8' or 'BIG5'
);
```

## SMT Implementation Details

The SMT is implemented in `smt/src/main/java/com/example/debezium/smt/LegacyCharsetTransform.java`.

### Configuration Options

| Property | Description | Required |
|----------|-------------|----------|
| `encoding` | Source character encoding (e.g., BIG5, GB2312, GBK, Shift_JIS) | Yes |
| `columns` | Comma-separated list of column names to decode | No |
| `tables` | Comma-separated list of table patterns (regex). Format: `server.schema.table` | No (all tables) |

**Note:** Output is always Unicode (UTF-8).

### Table Pattern Examples

The `tables` option uses Java regex patterns matching the Debezium topic name format: `server.schema.table`.

```properties
# Match specific table
debezium.transforms.legacycharset.tables=oracle\\.USR1\\.ADAM1

# Match multiple specific tables
debezium.transforms.legacycharset.tables=.*\\.USR1\\.ADAM1,.*\\.USR1\\.CUSTOMERS

# Match all tables in a schema
debezium.transforms.legacycharset.tables=.*\\.USR1\\..*

# Match tables with prefix
debezium.transforms.legacycharset.tables=.*\\.USR1\\.LEGACY_.*

# Empty = apply to all tables (default)
debezium.transforms.legacycharset.tables=
```

### Combining Multiple SMT Instances

For maximum flexibility, you can define multiple SMT instances with different configurations:

```properties
# Multiple SMT instances for different charsets
debezium.transforms=taiwan,china

# First SMT: BIG5 for Taiwan legacy tables
debezium.transforms.taiwan.type=com.example.debezium.smt.LegacyCharsetTransform
debezium.transforms.taiwan.encoding=BIG5
debezium.transforms.taiwan.columns=NAME,ADDRESS
debezium.transforms.taiwan.tables=.*\\.SCHEMA1\\.TW_.*

# Second SMT: GB2312 for China region tables
debezium.transforms.china.type=com.example.debezium.smt.LegacyCharsetTransform
debezium.transforms.china.encoding=GB2312
debezium.transforms.china.columns=CUSTOMER_NAME,CITY
debezium.transforms.china.tables=.*\\.SCHEMA1\\.CN_.*
```

You can also combine with Debezium's built-in predicates for additional filtering flexibility.

### Supported Encodings

The SMT supports any Java charset. Common examples:

| Encoding | Region | Example |
|----------|--------|---------|
| `BIG5` | Taiwan, Hong Kong | Traditional Chinese |
| `GB2312` | China | Simplified Chinese |
| `GBK` | China | Extended Chinese |
| `Shift_JIS` | Japan | Japanese |
| `EUC-KR` | Korea | Korean |

```properties
# Examples
debezium.transforms.legacycharset.encoding=BIG5
debezium.transforms.legacycharset.encoding=GB2312
debezium.transforms.legacycharset.encoding=Shift_JIS
```

## Comparison: Debezium vs OpenLogReplicator

| Aspect | Debezium | Debezium + SMT | OpenLogReplicator |
|--------|----------|----------------|-------------------|
| Encoding handling | Assumes database charset | Configurable per column | Configurable |
| Raw byte access | Through JSON (lossy) | Recovered by SMT | Direct in output |
| US7ASCII + BIG5 | Garbled output | Correctly decoded | May preserve bytes |
| Setup complexity | Low | Medium | Higher |

## Cleanup

```bash
# Remove test rows
python3 -c "
import oracledb
conn = oracledb.connect(user='USR1', password='USR1PWD', dsn='localhost:1521/XEPDB1')
conn.cursor().execute('DELETE FROM ADAM1 WHERE ID > 1')
conn.commit()
print('Cleaned up test rows')
"
```

## References

- [Oracle Character Set Migration](https://docs.oracle.com/en/database/oracle/oracle-database/19/nlspg/character-set-migration.html)
- [Debezium Oracle Connector](https://debezium.io/documentation/reference/stable/connectors/oracle.html)
- [Debezium Transformations](https://debezium.io/documentation/reference/stable/transformations/index.html)
- [Big5 Encoding](https://en.wikipedia.org/wiki/Big5)
- [iconv Manual](https://man7.org/linux/man-pages/man1/iconv.1.html)
