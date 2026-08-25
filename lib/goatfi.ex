defmodule Goatfi do
  @moduledoc """
  Captive portal detection and polite click-through acceptance.

  Goatfi helps headless devices (typically Nerves systems) get past
  click-through captive portals: the "accept our terms to use this
  network" pages that guest WiFi networks put in front of new clients.

  It does the same thing a human with a browser would do:

  1. Probe a known URL and compare against the expected response
     (`check/1`).
  2. If the response was intercepted, follow the redirect to the portal
     page, find the confirmation form, and submit it (`clear/2`).
  3. Verify that the network is now open (`ensure/1` does all three).

  It deliberately does *not* try to bypass or trick portals. No MAC
  rotation, no probe-endpoint spoofing. If a portal requires credentials
  or payment, Goatfi reports that it could not clear it.

  For continuous operation on a device, add `Goatfi.Monitor` to your
  supervision tree. It watches VintageNet (when available) and re-runs
  the check/clear cycle whenever the interface reconnects, as well as
  periodically, since portal authorizations usually expire.

  ## Example

      case Goatfi.ensure(bind_interface: "wlan0") do
        {:ok, :internet} -> :ok
        {:ok, :cleared} -> :ok
        {:blocked, reason} -> Logger.warning("Portal not clearable: " <> inspect(reason))
        {:error, reason} -> Logger.warning("Network trouble: " <> inspect(reason))
      end
  """

  alias Goatfi.HTTP
  alias Goatfi.Portal

  @default_probes [
    %{url: "http://connectivitycheck.gstatic.com/generate_204", expect: {:status, 204}},
    %{url: "http://captive.apple.com/hotspot-detect.html", expect: {:body_contains, "Success"}}
  ]

  @typedoc "A connectivity probe: a URL and the response that proves no interception."
  @type probe :: %{
          url: String.t(),
          expect: {:status, pos_integer()} | {:body_contains, String.t()}
        }

  @typedoc """
  Options shared by `check/1`, `clear/2`, and `ensure/1`.

  * `:probes` - probe list used to detect interception (default: Google
    and Apple connectivity check endpoints)
  * `:bind_interface` - bind sockets to this network interface, e.g.
    `"wlan0"` (Linux only, requires root; default: no binding)
  * `:user_agent` - the User-Agent header to send (default identifies
    Goatfi honestly)
  * `:timeout` - per-request timeout in milliseconds (default 10000)
  * `:max_hops` - redirect hops to follow when walking to the portal
    page (default 8)
  * `:insecure_tls` - also retry portal-page requests without TLS
    verification. Portals on RFC1918 addresses often present
    self-signed certificates; this option is scoped to the portal walk
    and never used for the connectivity probes (default false)
  * `:extra_fields` - map of form fields to set or override when
    submitting the acceptance form, e.g. `%{"email" => "ops@example.com"}`
    (default `%{}`)
  """
  @type opts :: keyword()

  @typedoc "The outcome of a full check-and-clear cycle. See `ensure/1`."
  @type ensure_result ::
          {:ok, :internet | :cleared} | {:blocked, term()} | {:error, term()}

  @doc """
  Check whether HTTP traffic is being intercepted by a captive portal.

  Returns:

  * `{:ok, :internet}` - probes answered as expected; no portal in the way
  * `{:portal, url}` - interception detected, with the URL of the portal
    page (or of the intercepted probe itself when no redirect was given)
  * `{:error, reason}` - the network did not answer usefully at all
  """
  @spec check(opts()) :: {:ok, :internet} | {:portal, String.t()} | {:error, term()}
  def check(opts \\ []) do
    probes = Keyword.get(opts, :probes, @default_probes)

    probes
    |> Enum.map(&run_probe(&1, opts))
    |> summarize_probes()
  end

  @doc """
  Attempt to clear the captive portal at `portal_url`.

  Walks redirects (HTTP, `<meta http-equiv="refresh">`, and simple
  JavaScript redirects) to the portal page, locates the confirmation
  form, and submits it. Returns `{:ok, summary}` when a form was
  submitted, or `{:error, reason}` when no acceptance form could be
  found or submitted. Submitting is not proof of success: run `check/1`
  again afterwards, or use `ensure/1` which does so for you.
  """
  @spec clear(String.t(), opts()) :: {:ok, Portal.summary()} | {:error, term()}
  def clear(portal_url, opts \\ []) do
    Portal.clear(portal_url, opts)
  end

  @doc """
  Check connectivity and, if a portal is in the way, try to clear it.

  Returns:

  * `{:ok, :internet}` - nothing to do
  * `{:ok, :cleared}` - a portal was cleared and connectivity verified
  * `{:blocked, reason}` - a portal was found but could not be cleared
    (needs credentials, payment, or a form Goatfi does not understand)
  * `{:error, reason}` - the network is not answering
  """
  @spec ensure(opts()) :: ensure_result()
  def ensure(opts \\ []) do
    case check(opts) do
      {:ok, :internet} ->
        {:ok, :internet}

      {:portal, url} ->
        clear_and_verify(url, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp clear_and_verify(url, opts) do
    case Portal.clear(url, opts) do
      {:ok, summary} ->
        case check(opts) do
          {:ok, :internet} -> {:ok, :cleared}
          {:portal, _still} -> {:blocked, {:portal_persists, summary}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:blocked, reason}
    end
  end

  defp run_probe(%{url: url, expect: expect}, opts) do
    case HTTP.get(url, opts) do
      {:ok, response} -> classify_response(response, expect, url)
      {:error, reason} -> {:error, reason}
    end
  end

  defp classify_response(response, expect, url) do
    if expected?(response, expect) do
      {:ok, :internet}
    else
      portal_or_error(response, url)
    end
  end

  defp portal_or_error(%{status: status} = response, url) do
    cond do
      status in 300..399 and response.location != nil ->
        {:portal, absolutize(response.location, url)}

      status == 511 ->
        {:portal, absolutize(response.location || Portal.embedded_url(response.body) || url, url)}

      status in 200..299 ->
        {:portal, absolutize(Portal.embedded_url(response.body) || url, url)}

      true ->
        {:error, {:unexpected_status, status}}
    end
  end

  defp absolutize(target, base) do
    base |> URI.merge(target) |> URI.to_string()
  end

  defp expected?(%{status: status}, {:status, status}), do: true

  defp expected?(%{status: status, body: body}, {:body_contains, marker})
       when status in 200..299 do
    String.contains?(body, marker)
  end

  defp expected?(_response, _expect), do: false

  # Any probe seeing a portal wins (portals sometimes whitelist specific
  # connectivity-check endpoints); otherwise any probe seeing internet
  # wins; only when all probes error out do we report an error.
  defp summarize_probes(results) do
    Enum.find(results, &match?({:portal, _}, &1)) ||
      Enum.find(results, &match?({:ok, :internet}, &1)) ||
      {:error, {:all_probes_failed, for({:error, reason} <- results, do: reason)}}
  end
end
