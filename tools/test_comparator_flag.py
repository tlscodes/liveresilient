"""Prove the comparator's profile parse fails loudly instead of defaulting.

`tools/compare_first_record.py` decides whether the extension list is compared
as an ordered sequence or as a set by reading one boolean out of the Dart
profile. That makes the parse load-bearing: if it silently returned False on a
parse failure, the comparison would get STRICTER, a capture doing exactly what
the profile declares would be reported as a mismatch, and the failure would look
like a bytes problem rather than a tool problem.

So the claim "this is a hard error, not a default" needs its own evidence:

  1  the intact source parses, and the flag is the value the source states
  2  a source with the flag line removed raises, and says what it could not read
  3  a source where a DIFFERENT profile has the flag still raises, which is
     what makes the record bounds worth having

    python3 tools/test_comparator_flag.py
"""

import importlib.util
import os
import re
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'tools', 'compare_first_record.py')

spec = importlib.util.spec_from_file_location('compare_first_record', SRC)
comparator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparator)

REAL_PROFILE = comparator.PROFILE_SRC
fails = 0


def check(label, ok):
    global fails
    print('%s %s' % ('PASS' if ok else 'FAIL', label))
    if not ok:
        fails += 1


def with_source(text):
    """Runs read_profile() against a temporary profile source."""
    handle = tempfile.NamedTemporaryFile('w', suffix='.dart', delete=False,
                                         encoding='utf-8')
    try:
        handle.write(text)
        handle.close()
        comparator.PROFILE_SRC = handle.name
        return comparator.read_profile()
    finally:
        comparator.PROFILE_SRC = REAL_PROFILE
        os.unlink(handle.name)


def raises(text):
    try:
        with_source(text)
    except SystemExit as err:
        return str(err)
    return None


real = open(REAL_PROFILE, encoding='utf-8').read()

# 1 — the intact source, through the real reader.
_ciphers, _extensions, shuffles = comparator.read_profile()
check('the intact source parses and states the flag',
      shuffles == bool(re.search(
          r'\bshufflesExtensions:\s*true\b',
          real[real.index('chrome120 = UtlsClientProfile('):]
          [:real[real.index('chrome120 = UtlsClientProfile('):].index('\n  );')]
      )))

# 2 — the flag removed from chrome120 only. Everything else is untouched, so a
# tool that defaulted would sail through this and report a stricter comparison.
start = real.index('chrome120 = UtlsClientProfile(')
end = real.index('\n  );', start)
without = (real[:start]
           + re.sub(r'\n\s*shufflesExtensions:\s*(true|false),', '',
                    real[start:end])
           + real[end:])
message = raises(without)
check('a missing flag raises', message is not None)
check('and the message names the field',
      message is not None and 'shufflesExtensions' in message)

# 3 — the flag removed from chrome120 but still present in a later profile. The
# record bounds are what stop the reader borrowing a neighbour's value; without
# them this case would quietly parse and return the wrong answer.
check('a neighbour profile\'s flag is not borrowed',
      'shufflesExtensions' in without.split('chrome120')[-1]
      and raises(without) is not None)

print('COMPARATOR FLAG PROOF PASSED' if not fails
      else 'COMPARATOR FLAG PROOF FAILED')
sys.exit(1 if fails else 0)
