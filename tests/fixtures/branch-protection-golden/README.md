# branch-protection golden context lists (#1671 AC4)

Captured from the **pre-#1671** `branch-protection.sh` (commit `29ccf89d`),
one context per line, sorted with `LC_ALL=C sort`, on a fixture with a
Dockerfile, `.github/workflows/codeql.yml` on disk and no `no-cluster-deploy`
pair:

- `row1-public-contexts.txt` — `--visibility public --has-dockerfile true
  --has-codeql true --codeql-languages python`
- `row5-private-contexts.txt` — `--visibility private --has-dockerfile true
  --has-codeql true --codeql-languages python`

`tests/bootstrap-toolchain-protection.bats` requires #1670 D4 rows 1 and 5 to
produce exactly these sets. They are historical records: never regenerate them
from the current script, which would turn the check into a tautology.
