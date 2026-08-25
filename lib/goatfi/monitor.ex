defmodule Goatfi.Monitor do
  @moduledoc """
  Keeps a device's captive portal acceptance current.

  Add it to your supervision tree:

      {Goatfi.Monitor, interface: "wlan0"}

  The monitor runs `Goatfi.ensure/1` when it starts, again whenever the
  interface's VintageNet connection status changes (when VintageNet is
  present, as on Nerves devices), and periodically after that, since
  portal authorizations typically expire after hours or days.

  Failed attempts back off exponentially so a portal that needs human
  attention is not hammered.

  ## Options

  * `:interface` - the interface to bind probes to and watch in
    VintageNet (default `"wlan0"`)
  * `:interval` - how often to re-check while things are fine
    (default 10 minutes)
  * `:name` - GenServer name (default `Goatfi.Monitor`)

  All other options are passed through to `Goatfi.ensure/1`, so
  `:probes`, `:user_agent`, `:insecure_tls`, and `:extra_fields` work
  here too.

  ## Status

      Goatfi.Monitor.status()
      #=> %{last_result: {:ok, :internet}, last_checked_at: ~U[...], ...}
  """

  use GenServer

  require Logger

  @default_interval :timer.minutes(10)
  # Wait for DHCP/DNS to settle after a connection status change.
  @settle_delay :timer.seconds(3)
  @backoff_start :timer.minutes(1)
  @backoff_max :timer.hours(1)

  @type status :: %{
          last_result: Goatfi.ensure_result() | nil,
          last_checked_at: DateTime.t() | nil,
          last_cleared_at: DateTime.t() | nil,
          attempts: non_neg_integer()
        }

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Report the monitor's view of the world."
  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @doc "Trigger a check/clear cycle now instead of waiting for the timer."
  @spec check_now(GenServer.server()) :: :ok
  def check_now(server \\ __MODULE__) do
    GenServer.cast(server, :check_now)
  end

  @impl GenServer
  def init(opts) do
    interface = Keyword.get(opts, :interface, "wlan0")
    interval = Keyword.get(opts, :interval, @default_interval)

    ensure_opts =
      opts
      |> Keyword.drop([:interface, :interval])
      |> Keyword.put(:bind_interface, interface)

    subscribe_to_vintage_net(interface)

    state = %{
      interface: interface,
      interval: interval,
      ensure_opts: ensure_opts,
      last_result: nil,
      last_checked_at: nil,
      last_cleared_at: nil,
      attempts: 0,
      backoff: @backoff_start,
      timer: nil
    }

    {:ok, schedule(state, @settle_delay)}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, Map.take(state, [:last_result, :last_checked_at, :last_cleared_at, :attempts]),
     state}
  end

  @impl GenServer
  def handle_cast(:check_now, state) do
    {:noreply, run_cycle(state)}
  end

  @impl GenServer
  def handle_info(:cycle, state) do
    {:noreply, run_cycle(state)}
  end

  # VintageNet property change: {VintageNet, property_path, old, new, metadata}
  def handle_info({VintageNet, ["interface", interface, "connection"], _old, new, _meta}, state)
      when interface == state.interface do
    if new in [:lan, :internet] do
      Logger.info("goatfi: #{interface} is #{inspect(new)}, checking for captive portal")
      {:noreply, schedule(state, @settle_delay)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  defp run_cycle(state) do
    result = Goatfi.ensure(state.ensure_opts)
    now = DateTime.utc_now()

    state = %{state | last_result: result, last_checked_at: now, attempts: state.attempts + 1}

    case result do
      {:ok, :internet} ->
        %{state | backoff: @backoff_start} |> schedule(state.interval)

      {:ok, :cleared} ->
        Logger.info("goatfi: captive portal cleared on #{state.interface}")
        %{state | last_cleared_at: now, backoff: @backoff_start} |> schedule(state.interval)

      {:blocked, reason} ->
        Logger.warning(
          "goatfi: captive portal on #{state.interface} not clearable: #{inspect(reason)}"
        )

        backoff(state)

      {:error, reason} ->
        Logger.debug(
          "goatfi: connectivity check failed on #{state.interface}: #{inspect(reason)}"
        )

        backoff(state)
    end
  end

  defp backoff(state) do
    delay = state.backoff

    %{state | backoff: min(state.backoff * 2, @backoff_max)}
    |> schedule(delay)
  end

  defp schedule(state, delay) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :cycle, delay)}
  end

  # VintageNet is an optional integration: present on Nerves targets,
  # absent on the host. Resolved at runtime so this library compiles
  # without it.
  defp subscribe_to_vintage_net(interface) do
    if Code.ensure_loaded?(VintageNet) do
      # apply/3 keeps the optional dependency out of the compiler's sight.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(VintageNet, :subscribe, [["interface", interface, "connection"]])
    end

    :ok
  end
end
