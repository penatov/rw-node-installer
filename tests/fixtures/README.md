# Regression fixtures

- `site-sha256.txt`: normalized full-HTML SHA-256 for `port-equivalence-0..99`,
  captured from the tested native generator at commit `70c67fd`. This corpus had
  already passed full rendering/design equivalence checks during the migration.
- `ip-cases.tsv`: 2246 expected results from the previous independent IP/CIDR
  oracle: 574 normalization/version cases plus membership and prefix checks.
  Columns: mode, input, networks, exit status, stdout. `-` denotes an empty field.

These are data, not executable references. CI only compares against them; it never
rewrites them to bless a changed result. Deliberate renderer/parser changes require
reviewing the expected differences before updating fixtures.
