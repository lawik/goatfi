defmodule Goatfi.HTTP do
  @moduledoc """
  Thin wrapper around `:httpc` used for portal probing and clearing.

  Uses a dedicated `:httpc` profile with cookie handling enabled, since
  captive portals routinely track the confirmation flow with session
  cookies. Redirects are never followed automatically; the caller
  decides which redirects to walk.
  """

  @profile :goatfi
  @default_timeout 10_000

  @type response :: %{
          status: pos_integer(),
          headers: [{String.t(), String.t()}],
          body: binary(),
          location: String.t() | nil,
          url: String.t()
        }

  @doc "Perform a GET request. Returns `{:ok, response}` or `{:error, reason}`."
  @spec get(String.t(), keyword()) :: {:ok, response()} | {:error, term()}
  def get(url, opts \\ []) do
    request(:get, url, nil, opts)
  end

  @doc """
  Perform a form POST with an `application/x-www-form-urlencoded` body.

  `fields` is an enumerable of `{name, value}` pairs.
  """
  @spec post_form(String.t(), Enumerable.t(), keyword()) :: {:ok, response()} | {:error, term()}
  def post_form(url, fields, opts \\ []) do
    request(:post, url, URI.encode_query(fields), opts)
  end

  @doc "Forget all cookies collected in Goatfi's HTTP session."
  @spec reset_session() :: :ok
  def reset_session() do
    ensure_profile()
    :httpc.reset_cookies(@profile)
    :ok
  end

  defp request(method, url, body, opts) do
    ensure_profile()

    headers = [{~c"user-agent", String.to_charlist(user_agent(opts))} | extra_headers(opts)]

    target =
      case method do
        :get -> {String.to_charlist(url), headers}
        :post -> {String.to_charlist(url), headers, ~c"application/x-www-form-urlencoded", body}
      end

    http_options =
      [
        autoredirect: false,
        timeout: Keyword.get(opts, :timeout, @default_timeout),
        connect_timeout: Keyword.get(opts, :timeout, @default_timeout)
      ] ++ ssl_options(url, opts)

    request_options = [body_format: :binary, socket_opts: socket_opts(opts)]

    case :httpc.request(method, target, http_options, request_options, @profile) do
      {:ok, {{_http_version, status, _reason_phrase}, headers, response_body}} ->
        headers =
          Enum.map(headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)

        {:ok,
         %{
           status: status,
           headers: headers,
           body: response_body,
           location: header_value(headers, "location"),
           url: url
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extra_headers(opts) do
    for {name, value} <- Keyword.get(opts, :headers, []) do
      {String.to_charlist(name), String.to_charlist(value)}
    end
  end

  defp header_value(headers, name) do
    Enum.find_value(headers, fn
      {^name, value} -> value
      _other -> nil
    end)
  end

  defp user_agent(opts) do
    Keyword.get(opts, :user_agent, default_user_agent())
  end

  # Chrome-compatible by default: plenty of portals serve broken or
  # empty pages to unrecognized agents. Compatibility, not deception --
  # rate limiting and backoff are what keep Goatfi polite.
  defp default_user_agent() do
    "Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 (KHTML, like Gecko) " <>
      "Chrome/139.0.0.0 Safari/537.36"
  end

  defp ssl_options(url, opts) do
    with "https" <> _rest <- url,
         true <- Keyword.get(opts, :insecure_tls, false) do
      [ssl: [verify: :verify_none]]
    else
      _other -> []
    end
  end

  defp socket_opts(opts) do
    case Keyword.get(opts, :bind_interface) do
      nil -> []
      interface -> [{:raw, 1, 25, interface <> <<0>>}]
    end
  end

  defp ensure_profile() do
    case :inets.start(:httpc, profile: @profile) do
      {:ok, _pid} ->
        :httpc.set_options([cookies: :enabled], @profile)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end
end
