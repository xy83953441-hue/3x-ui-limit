"""Keep the standalone installer TLS implementation identical to the menu library."""
from pathlib import Path
import sys
root = Path(__file__).resolve().parent.parent
path = root / 'install.sh'
source = path.read_text(encoding='utf-8')
start, end = '# BEGIN GENERATED SSL\n', '# END GENERATED SSL'
before, rest = source.split(start, 1)
_, after = rest.split(end, 1)
expected = before + start + (root / 'scripts/lib/ssl.sh').read_text(encoding='utf-8') + end + after
if '--check' in sys.argv:
    if source != expected:
        sys.exit('SSL helpers differ; run python3 scripts/sync_ssl.py')
else:
    path.write_text(expected, encoding='utf-8', newline='\n')
