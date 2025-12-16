# Testing Legacy Chinese (BIG5) Encoding with Debezium

This document describes how to test Debezium CDC behavior with legacy Big5-encoded Chinese characters stored in an Oracle US7ASCII database.

## Background

Many legacy Oracle databases use `US7ASCII` character set but store multi-byte Chinese characters (Big5 or GB2312) directly as raw bytes. This was a common practice before Unicode adoption.

**Challenge:** CDC tools like Debezium assume a specific encoding when reading VARCHAR2 columns. When the actual encoding differs from what Debezium expects, the output appears garbled.

## Test Setup

### Prerequisites

- Running Oracle container with `ORACLE_CHARACTERSET=US7ASCII`
- Python 3 with `oracledb` package
- Debezium Server configured and running

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

## Running the Test

### Step 1: Verify Big5 Test File

```bash
# View original UTF-8 text
cat test-big5.txt

# Convert BIG5 back to UTF-8 to verify encoding
iconv -f BIG5 -t UTF-8 test-big5-encoded.txt

# Compare byte sizes (BIG5 = 2 bytes/char, UTF-8 = 3 bytes/char for CJK)
wc -c test-big5.txt test-big5-encoded.txt
```

### Step 2: Run the Encoding Test Script

```bash
python3 test-encoding.py
```

This script:
1. Connects to Oracle on `localhost:1521/XEPDB1`
2. Inserts 3 rows with UTF-8 encoded Chinese (IDs 10-12)
3. Inserts 3 rows with BIG5 encoded Chinese (IDs 20-22)
4. Queries and displays all rows with hex values

### Step 3: Check Debezium Output

```bash
# Restart Debezium to capture new changes
docker restart debezium-server

# Wait for processing
sleep 20

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

### Debezium Output

Debezium captures the raw bytes but outputs garbled text:

```json
{
  "after": {
    "ID": {"scale": 0, "value": "Cg=="},
    "NAME": "￦ﾸﾬ￨ﾩﾦ￤ﾸﾭ￦ﾖﾇ"
  }
}
```

The `NAME` field contains Unicode replacement characters because Debezium misinterprets the raw bytes.

## Encoding Comparison

| Text | UTF-8 Hex | UTF-8 Bytes | BIG5 Hex | BIG5 Bytes |
|------|-----------|-------------|----------|------------|
| 測試中文 | E6B8AC E8A9A6 E4B8AD E69687 | 12 | B4FA B8D5 A4A4 A4E5 | 8 |
| 你好世界 | E4BDA0 E5A5BD E4B896 E7958C | 12 | A741 A66E A540 ACC9 | 8 |
| 台北市 | E58FB0 E58C97 E5B882 | 9 | A578 A55F A5AB | 6 |

## Handling in Consumer Applications

Since Debezium cannot know the original encoding, consumer applications must:

1. **Know the source encoding** - Application must know if data is UTF-8 or BIG5
2. **Extract raw bytes** - Get the byte representation from Debezium output
3. **Decode appropriately** - Apply correct decoder based on known encoding

### Example: Decoding in Python

```python
import json

def decode_name(debezium_event, encoding='big5'):
    """Decode NAME field from Debezium event."""
    name = debezium_event['after']['NAME']
    # Get raw bytes (Debezium may have mangled them)
    raw_bytes = name.encode('utf-8', errors='surrogateescape')
    # Decode with correct encoding
    return raw_bytes.decode(encoding, errors='replace')
```

## Alternative Approaches

### 1. Use Oracle AL32UTF8 Character Set

Convert database to Unicode:
```sql
-- Requires database recreation or migration
ALTER DATABASE CHARACTER SET AL32UTF8;
```

### 2. Store as RAW/BLOB

Store binary data explicitly:
```sql
CREATE TABLE data (
    id NUMBER,
    name_raw RAW(100),
    encoding VARCHAR2(10)  -- 'UTF8' or 'BIG5'
);
```

### 3. Convert at Insert Time

Convert to UTF-8 before inserting:
```python
# Convert BIG5 to UTF-8 before insert
utf8_text = big5_text.encode('big5').decode('big5').encode('utf-8')
```

## Comparison: Debezium vs OpenLogReplicator

| Aspect | Debezium | OpenLogReplicator |
|--------|----------|-------------------|
| Encoding handling | Assumes database charset | Configurable |
| Raw byte access | Through JSON (lossy) | Direct in output |
| US7ASCII + BIG5 | Garbled output | May preserve bytes |

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
- [Big5 Encoding](https://en.wikipedia.org/wiki/Big5)
- [iconv Manual](https://man7.org/linux/man-pages/man1/iconv.1.html)
