#!/usr/bin/env python3
"""
Test script to load Big5 and UTF-8 encoded Chinese text into Oracle.

This demonstrates how Oracle US7ASCII database handles different encodings
and how Debezium captures these changes.
"""

import oracledb

# Oracle connection settings
ORACLE_HOST = "localhost"
ORACLE_PORT = 1521
ORACLE_SERVICE = "XEPDB1"
ORACLE_USER = "USR1"
ORACLE_PASSWORD = "USR1PWD"

# Test data - Chinese text
TEST_STRINGS = [
    ("測試中文", "Test Chinese"),
    ("你好世界", "Hello World"),
    ("台北市", "Taipei City"),
]


def connect_oracle():
    """Connect to Oracle database."""
    dsn = f"{ORACLE_HOST}:{ORACLE_PORT}/{ORACLE_SERVICE}"
    conn = oracledb.connect(user=ORACLE_USER, password=ORACLE_PASSWORD, dsn=dsn)
    return conn


def insert_utf8(conn, id_start: int):
    """Insert UTF-8 encoded Chinese text."""
    print("\n=== Inserting UTF-8 encoded text ===")
    cursor = conn.cursor()

    for i, (chinese, english) in enumerate(TEST_STRINGS):
        row_id = id_start + i
        # UTF-8 bytes
        utf8_bytes = chinese.encode('utf-8')

        # Insert as raw bytes using UTL_RAW
        hex_str = utf8_bytes.hex().upper()
        sql = f"""
            INSERT INTO ADAM1 (ID, NAME, COUNT, START_TIME)
            VALUES (:1, UTL_RAW.CAST_TO_VARCHAR2(HEXTORAW(:2)), :3, SYSTIMESTAMP)
        """
        cursor.execute(sql, [row_id, hex_str, row_id * 100])

        print(f"  ID={row_id}: '{chinese}' ({english})")
        print(f"    UTF-8 hex: {hex_str}")
        print(f"    UTF-8 bytes: {len(utf8_bytes)} bytes")

    conn.commit()
    cursor.close()
    print(f"  Committed {len(TEST_STRINGS)} UTF-8 rows")


def insert_big5(conn, id_start: int):
    """Insert Big5 encoded Chinese text."""
    print("\n=== Inserting BIG5 encoded text ===")
    cursor = conn.cursor()

    for i, (chinese, english) in enumerate(TEST_STRINGS):
        row_id = id_start + i
        # Big5 bytes
        big5_bytes = chinese.encode('big5')

        # Insert as raw bytes using UTL_RAW
        hex_str = big5_bytes.hex().upper()
        sql = f"""
            INSERT INTO ADAM1 (ID, NAME, COUNT, START_TIME)
            VALUES (:1, UTL_RAW.CAST_TO_VARCHAR2(HEXTORAW(:2)), :3, SYSTIMESTAMP)
        """
        cursor.execute(sql, [row_id, hex_str, row_id * 100])

        print(f"  ID={row_id}: '{chinese}' ({english})")
        print(f"    BIG5 hex: {hex_str}")
        print(f"    BIG5 bytes: {len(big5_bytes)} bytes")

    conn.commit()
    cursor.close()
    print(f"  Committed {len(TEST_STRINGS)} BIG5 rows")


def query_and_display(conn):
    """Query and display all rows, showing raw bytes."""
    print("\n=== Querying all rows ===")
    cursor = conn.cursor()

    cursor.execute("""
        SELECT ID, NAME, RAWTOHEX(UTL_RAW.CAST_TO_RAW(NAME)) as HEX_NAME, COUNT
        FROM ADAM1
        ORDER BY ID
    """)

    print(f"  {'ID':<4} {'COUNT':<6} {'HEX':<30} {'Decoded UTF-8':<20} {'Decoded BIG5':<20}")
    print(f"  {'-'*4} {'-'*6} {'-'*30} {'-'*20} {'-'*20}")

    for row in cursor:
        row_id, name, hex_name, count = row

        # Try to decode as UTF-8
        try:
            utf8_decoded = bytes.fromhex(hex_name).decode('utf-8')
        except:
            utf8_decoded = "(invalid)"

        # Try to decode as Big5
        try:
            big5_decoded = bytes.fromhex(hex_name).decode('big5')
        except:
            big5_decoded = "(invalid)"

        print(f"  {row_id:<4} {count:<6} {hex_name:<30} {utf8_decoded:<20} {big5_decoded:<20}")

    cursor.close()


def cleanup(conn, keep_id_1: bool = True):
    """Delete test rows."""
    print("\n=== Cleaning up test rows ===")
    cursor = conn.cursor()
    if keep_id_1:
        cursor.execute("DELETE FROM ADAM1 WHERE ID > 1")
    else:
        cursor.execute("DELETE FROM ADAM1")
    deleted = cursor.rowcount
    conn.commit()
    cursor.close()
    print(f"  Deleted {deleted} rows")


def main():
    print("=" * 60)
    print("Oracle Encoding Test: UTF-8 vs BIG5 in US7ASCII database")
    print("=" * 60)

    # Connect
    print(f"\nConnecting to Oracle at {ORACLE_HOST}:{ORACLE_PORT}/{ORACLE_SERVICE}...")
    conn = connect_oracle()
    print("  Connected!")

    # Clean up first
    cleanup(conn, keep_id_1=True)

    # Insert UTF-8 (IDs 10-12)
    insert_utf8(conn, id_start=10)

    # Insert Big5 (IDs 20-22)
    insert_big5(conn, id_start=20)

    # Query and display
    query_and_display(conn)

    # Close connection
    conn.close()
    print("\n" + "=" * 60)
    print("Done! Check Debezium output for captured CDC events.")
    print("=" * 60)


if __name__ == "__main__":
    main()
