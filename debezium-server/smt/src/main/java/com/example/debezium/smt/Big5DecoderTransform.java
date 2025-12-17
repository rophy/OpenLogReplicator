package com.example.debezium.smt;

import org.apache.kafka.common.config.ConfigDef;
import org.apache.kafka.connect.connector.ConnectRecord;
import org.apache.kafka.connect.data.Field;
import org.apache.kafka.connect.data.Schema;
import org.apache.kafka.connect.data.SchemaBuilder;
import org.apache.kafka.connect.data.Struct;
import org.apache.kafka.connect.transforms.Transformation;

import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * Debezium SMT to decode legacy encoded strings (BIG5, GB2312, etc.)
 * from Oracle US7ASCII databases.
 *
 * Oracle JDBC converts high bytes (>=0x80) to Unicode halfwidth range (0xFFxx).
 * This SMT recovers the original bytes and decodes them with the specified charset.
 *
 * Configuration:
 * - columns: Comma-separated list of column names to decode
 * - encoding: Character encoding (default: BIG5)
 * - tables: Comma-separated list of table patterns (regex supported)
 *           Format matches Debezium topic: server.schema.table
 *           If empty, applies to all tables.
 */
public class Big5DecoderTransform<R extends ConnectRecord<R>> implements Transformation<R> {

    public static final String COLUMNS_CONFIG = "columns";
    public static final String ENCODING_CONFIG = "encoding";
    public static final String TABLES_CONFIG = "tables";

    private static final ConfigDef CONFIG_DEF = new ConfigDef()
            .define(COLUMNS_CONFIG, ConfigDef.Type.STRING, "",
                    ConfigDef.Importance.HIGH,
                    "Comma-separated list of column names to decode")
            .define(ENCODING_CONFIG, ConfigDef.Type.STRING, "BIG5",
                    ConfigDef.Importance.MEDIUM,
                    "Character encoding to use for decoding (default: BIG5)")
            .define(TABLES_CONFIG, ConfigDef.Type.STRING, "",
                    ConfigDef.Importance.MEDIUM,
                    "Comma-separated list of table patterns (regex). " +
                    "Format: server.schema.table or use .* wildcards. " +
                    "If empty, applies to all tables.");

    private Set<String> columns;
    private Charset encoding;
    private List<Pattern> tablePatterns;

    @Override
    public void configure(Map<String, ?> configs) {
        // Parse columns (comma-separated, with trimming)
        columns = new HashSet<>();
        String columnList = (String) configs.get(COLUMNS_CONFIG);
        if (columnList != null && !columnList.trim().isEmpty()) {
            for (String col : columnList.split(",")) {
                String trimmed = col.trim();
                if (!trimmed.isEmpty()) {
                    columns.add(trimmed);
                }
            }
        }

        Object encodingObj = configs.get(ENCODING_CONFIG);
        String encodingName = encodingObj != null ? (String) encodingObj : "BIG5";
        encoding = Charset.forName(encodingName);

        // Parse table patterns
        tablePatterns = new ArrayList<>();
        String tableList = (String) configs.get(TABLES_CONFIG);
        if (tableList != null && !tableList.trim().isEmpty()) {
            for (String pattern : tableList.split(",")) {
                String trimmed = pattern.trim();
                if (!trimmed.isEmpty()) {
                    tablePatterns.add(Pattern.compile(trimmed));
                }
            }
        }

        System.out.println("[Big5DecoderTransform] Configured for columns: " + columns +
                ", encoding: " + encoding +
                ", tables: " + (tablePatterns.isEmpty() ? "(all)" : tablePatterns));
    }

    /**
     * Check if the record's topic matches any of the configured table patterns.
     * If no patterns are configured, returns true (match all).
     */
    private boolean matchesTables(String topic) {
        if (tablePatterns.isEmpty()) {
            return true; // No filter = match all
        }
        for (Pattern pattern : tablePatterns) {
            if (pattern.matcher(topic).matches()) {
                return true;
            }
        }
        return false;
    }

    @Override
    public R apply(R record) {
        if (record.value() == null) {
            return record;
        }

        // Check table filter first
        if (!matchesTables(record.topic())) {
            return record;
        }

        if (!(record.value() instanceof Struct)) {
            return record;
        }

        Struct value = (Struct) record.value();

        // Handle Debezium envelope (before/after)
        Struct after = value.schema().field("after") != null ? value.getStruct("after") : null;
        Struct before = value.schema().field("before") != null ? value.getStruct("before") : null;

        boolean modified = false;
        Struct newAfter = null;
        Struct newBefore = null;

        if (after != null) {
            newAfter = processStruct(after);
            if (newAfter != after) {
                modified = true;
            }
        }

        if (before != null) {
            newBefore = processStruct(before);
            if (newBefore != before) {
                modified = true;
            }
        }

        if (!modified) {
            return record;
        }

        // Build new value with modified after/before
        Struct newValue = new Struct(value.schema());
        for (Field field : value.schema().fields()) {
            if (field.name().equals("after") && newAfter != null) {
                newValue.put(field, newAfter);
            } else if (field.name().equals("before") && newBefore != null) {
                newValue.put(field, newBefore);
            } else {
                newValue.put(field, value.get(field));
            }
        }

        return record.newRecord(
                record.topic(),
                record.kafkaPartition(),
                record.keySchema(),
                record.key(),
                newValue.schema(),
                newValue,
                record.timestamp()
        );
    }

    private Struct processStruct(Struct struct) {
        boolean modified = false;
        Struct newStruct = new Struct(struct.schema());

        for (Field field : struct.schema().fields()) {
            Object fieldValue = struct.get(field);

            if (columns.contains(field.name()) && fieldValue instanceof String) {
                String decoded = decodeString((String) fieldValue);
                newStruct.put(field, decoded);
                if (!decoded.equals(fieldValue)) {
                    modified = true;
                    System.out.println("[Big5DecoderTransform] Decoded " + field.name() +
                            ": '" + fieldValue + "' -> '" + decoded + "'");
                }
            } else {
                newStruct.put(field, fieldValue);
            }
        }

        return modified ? newStruct : struct;
    }

    /**
     * Recover original bytes from Oracle JDBC's Unicode halfwidth conversion.
     * Oracle JDBC converts bytes >= 0x80 to Unicode codepoints in 0xFFxx range.
     */
    private String decodeString(String garbled) {
        if (garbled == null || garbled.isEmpty()) {
            return garbled;
        }

        byte[] recovered = new byte[garbled.length()];
        int byteIndex = 0;

        for (int i = 0; i < garbled.length(); i++) {
            int cp = garbled.codePointAt(i);

            if (cp >= 0xFF00 && cp <= 0xFFFF) {
                // Halfwidth range - recover original byte
                recovered[byteIndex++] = (byte) (cp - 0xFF00);
            } else if (cp < 0x80) {
                // ASCII - keep as is
                recovered[byteIndex++] = (byte) cp;
            } else {
                // Other Unicode - try to preserve
                recovered[byteIndex++] = (byte) (cp & 0xFF);
            }
        }

        // Decode with specified encoding
        try {
            return new String(Arrays.copyOf(recovered, byteIndex), encoding);
        } catch (Exception e) {
            System.err.println("[Big5DecoderTransform] Failed to decode: " + e.getMessage());
            return garbled;
        }
    }

    @Override
    public ConfigDef config() {
        return CONFIG_DEF;
    }

    @Override
    public void close() {
        // No resources to release
    }
}
