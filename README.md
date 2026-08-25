# Goatfi

Captive portal detection and polite click-through acceptance for Elixir,
built with headless [Nerves](https://nerves-project.org) devices in mind.

Guest WiFi networks often gate access behind a captive portal: a
"accept our terms to connect" page that a human with a browser clicks
through. A headless device has no browser and no human, so it sits
behind the portal forever. Goatfi does what the human would have done:

1. **Detect** - probe well-known connectivity check URLs and notice
   when the response is intercepted (`Goatfi.check/1`).
2. **Clear** - follow the redirect to the portal page (HTTP `Location`,
   meta refresh, and simple JavaScript redirects), find the form that
   looks like the terms confirmation, tick its checkboxes, and submit
   it (`Goatfi.clear/2`).
3. **Verify** - probe again to confirm the network opened up
   (`Goatfi.ensure/1` runs all three steps).

## Being an upstanding network citizen

Goatfi accepts click-through confirmations. It deliberately does not
try to get around portals:

* No MAC address rotation to reset quotas or dodge bans.
* No spoofing of connectivity-check endpoints.
* Forms with password fields are never touched - if a portal wants
  credentials or payment, Goatfi reports `{:blocked, ...}` and leaves
  the decision to you.
* Failed attempts back off exponentially rather than hammering the
  portal.
* The default User-Agent matches Chrome for compatibility (portals
  routinely serve broken pages to unrecognized agents) and can be set
  to anything with the `user_agent:` option.

Accepting a portal's terms programmatically still means *accepting the
terms*. Make sure the terms of the network you point this at are terms
you are fine with your device agreeing to.

## Usage

One-shot:

```elixir
case Goatfi.ensure(bind_interface: "wlan0") do
  {:ok, :internet} -> :ok                # nothing was in the way
  {:ok, :cleared} -> :ok                 # portal confirmed, verified open
  {:blocked, reason} -> ...              # needs a human (credentials, payment, odd form)
  {:error, reason} -> ...                # network not answering
end
```

Supervised, on a Nerves device (re-checks periodically and whenever
VintageNet reports the interface reconnecting, since portal
authorizations expire):

```elixir
# in your application's supervision tree
{Goatfi.Monitor, interface: "wlan0"}

# ask it how things are going
Goatfi.Monitor.status()
#=> %{last_result: {:ok, :internet}, last_checked_at: ~U[...], ...}
```

Useful options (all functions and the monitor accept them):

* `probes:` - override the connectivity probes, e.g.
  `[%{url: "http://connectivitycheck.gstatic.com/generate_204", expect: {:status, 204}}]`
* `insecure_tls: true` - retry portal pages without TLS verification
  (portals on private addresses often have self-signed certificates;
  probes are never affected)
* `extra_fields: %{"email" => "ops@example.com"}` - fill portal form
  fields the heuristics cannot guess
* `user_agent:` - override the default Chrome-compatible User-Agent

Goatfi has no runtime dependencies beyond OTP (`:httpc` does the HTTP
work) and integrates with VintageNet when present without requiring it.

## Installation

The package can be installed by adding `goatfi` to your list of
dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:goatfi, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/goatfi>.
