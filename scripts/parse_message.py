#!/usr/bin/env python3
# parse_message.py — extract text/timestamp/from from an inbox message JSON
# Outputs NULL-separated: text\0timestamp\0from
import json, sys
d = json.loads(sys.argv[1])
sys.stdout.write(d['text'] + '\0' + d.get('timestamp', '') + '\0' + d.get('from', 'lead'))
