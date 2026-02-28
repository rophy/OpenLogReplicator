# Test Fixtures

This directory holds test fixture data for full pipeline I/O tests.

## Directory Structure

```
data/
  redo/<fixture-name>/       # Archived redo log files (gitignored — too large)
  schema/<fixture-name>/     # Checkpoint/schema files (committed)
  expected/<fixture-name>/   # Expected JSON output — golden files (committed)
```

## Generating Fixtures

Use the automated pipeline in `tests/fixtures/`. See
[tests/fixtures/README.md](../fixtures/README.md) for full instructions.

```bash
cd tests/fixtures
./generate.sh basic-crud
```

## Notes

- Redo log files (`.arc`) are gitignored — regenerate them with `generate.sh`
- Schema checkpoint files and golden output files are committed
- Tests skip automatically if redo log fixtures are not present
- Redo log files are Oracle-version-specific; fixtures captured on one version
  may not work on another
