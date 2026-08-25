# Changelog

## v0.1.0

Initial release.

- `Goatfi.check/1` - captive portal detection via connectivity probes
  (Google/Apple endpoints by default, configurable).
- `Goatfi.clear/2` - walk redirects (HTTP, meta refresh, JavaScript) to
  the portal page, pick the confirmation form heuristically (English
  and Swedish vocabulary), and submit it. Refuses forms with password
  fields.
- `Goatfi.ensure/1` - check, clear, and verify in one call.
- `Goatfi.Monitor` - supervised process that keeps acceptance current:
  re-checks on VintageNet connection changes (when present) and
  periodically, with exponential backoff on failure.
- Interface binding (`bind_interface: "wlan0"`) so probes go out the
  right interface on multi-homed devices.
