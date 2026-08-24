#!/usr/bin/env python3
"""Check that the given XML config files are well-formed (CI helper).

Usage: check-config-xml.py FILE [FILE ...]
"""

import sys
import xml.etree.ElementTree as ET

for f in sys.argv[1:]:
    ET.parse(f)
    print(f, "well-formed")
