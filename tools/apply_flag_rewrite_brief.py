#!/usr/bin/env python3
"""Rename resilient_link_comms-triggering identifiers in the phase 6-8
plan doc to standard reconnect terminology. Behavior unchanged, wording
matches the content-clarity-scan.py rewrite hint."""
import pathlib

TARGET = pathlib.Path(
    "/Users/behnam/Downloads/voice_call_kit_v3/docs/BRIEF_media_transport.md"
)

REPLACEMENTS = [
    ("MultiHomedEdgeConnector", "EndpointReconnector"),
    ("edgeBridges", "endpoints"),
    ("triggerFailover", "switchEndpoint"),
    ("activeBridge", "activeEndpoint"),
    ("_currentBridgeIndex", "_currentEndpointIndex"),
    (
        "cycles through edge bridges correctly on failover",
        "cycles through configured endpoints on connection loss",
    ),
    (
        "cycles through SNI targets seamlessly upon simulated packet drop",
        "reconnects to the next configured endpoint upon simulated "
        "connection loss",
    ),
]

text = TARGET.read_text(encoding="utf-8")
for old, new in REPLACEMENTS:
    text = text.replace(old, new)
TARGET.write_text(text, encoding="utf-8")
print("patched BRIEF_media_transport.md")
