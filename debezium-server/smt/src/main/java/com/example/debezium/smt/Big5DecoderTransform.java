package com.example.debezium.smt;

import org.apache.kafka.common.config.ConfigDef;
import org.apache.kafka.connect.connector.ConnectRecord;
import org.apache.kafka.connect.data.Field;
import org.apache.kafka.connect.data.Schema;
import org.apache.kafka.connect.data.SchemaBuilder;
import org.apache.kafka.connect.data.Struct;
import org.apache.kafka.connect.transforms.Transformation;

import java.nio.charset.Charset;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

/**
 * Debezium SMT to decode legacy encoded strings (BIG5, GB2312, etc.)
 * from Oracle US7ASCII databases.
 *
 * Oracle JDBC converts high bytes (>=0x80) to Unicode halfwidth range (0xFFxx).
 * This SMT recovers the original bytes and decodes them with the specified charset.
 */
public class Big5DecoderTransform<R extends ConnectRecord<R>> implements Transformation<R> {

    public static final String COLUMNS_CONFIG = "columns";
    public static final String ENCODING_CONFIG = "encoding";

    private static final ConfigDef CONFIG_DEF = new ConfigDef()
            .define(COLUMNS_CONFIG, ConfigDef.Type.STRING, "",
                    ConfigDef.Importance.HIGH,
                    "Comma-separated list of column names to decode")
            .define(ENCODING_CONFIG, ConfigDef.Type.STRING, "BIG5",
                    ConfigDef.Importance.MEDIUM,
                    "Character encoding to use for decoding (default: BIG5)");

    private Set<String> columns;
    private Charset encoding;

    @Override
    public void configure(Map<String, ?> configs) {
        String columnList = (String) configs.get(COLUMNS_CONFIG);
        if (columnList == null || columnList.isEmpty()) {
            columnList = "";
        }
        columns = new HashSet<>(Arrays.asList(columnList.split(",")));

        Object encodingObj = configs.get(ENCODING_CONFIG);
        String encodingName = encodingObj != null ? (String) encodingObj : "BIG5";
        encoding = Charset.forName(encodingName);

        System.out.println("[Big5DecoderTransform] Configured for columns: " + columns + ", encoding: " + encoding);
    }

    @Override
    public R apply(R record) {
        if (record.value() == null) {
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
