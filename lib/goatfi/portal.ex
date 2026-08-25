defmodule Goatfi.Portal do
  @moduledoc """
  Walks to a captive portal page and submits its confirmation form.

  The flow mirrors what a person does in a browser: follow redirects
  (HTTP `Location`, meta refresh, and simple JavaScript redirects) until
  a page with a form appears, pick the form that looks like the "accept
  the terms and connect" form, tick its checkboxes, and submit it.

  Form selection is heuristic. Forms are scored on their fields, button
  labels, and action URLs against vocabulary common to click-through
  portals (in English and Swedish). Password fields disqualify a form:
  a portal that wants credentials is not something Goatfi should ever
  try to get past on its own.
  """

  alias Goatfi.HTML
  alias Goatfi.HTML.Form
  alias Goatfi.HTTP

  require Logger

  @max_hops 8

  @accept_words ~w(
    accept agree connect continue submit login start free guest terms ok
    godkann godkanner anslut fortsatt acceptera villkor vidare surfa
  )

  @typedoc "What was submitted where, for logging and debugging."
  @type summary :: %{
          portal_url: String.t(),
          submitted_to: String.t(),
          method: String.t(),
          fields: [{String.t(), String.t()}],
          final_status: pos_integer()
        }

  @doc """
  Clear the portal reached from `start_url`.

  See `Goatfi.clear/2` for the options.
  """
  @spec clear(String.t(), keyword()) :: {:ok, summary()} | {:error, term()}
  def clear(start_url, opts \\ []) do
    HTTP.reset_session()

    with {:ok, page} <- walk(start_url, opts),
         {:ok, form} <- pick_form(page) do
      submit(page, form, opts)
    end
  end

  @doc """
  Follow redirects from `url` until a page stops redirecting.

  Returns `{:ok, %{url: final_url, body: body, status: status}}`.
  """
  @spec walk(String.t(), keyword()) ::
          {:ok, %{url: String.t(), body: binary(), status: pos_integer()}} | {:error, term()}
  def walk(url, opts \\ []) do
    do_walk(url, Keyword.get(opts, :max_hops, @max_hops), opts)
  end

  @doc false
  # Pull a redirect target out of an intercepted response body, used when
  # a portal answers 200/511 with an inline redirect instead of Location.
  @spec embedded_url(binary()) :: String.t() | nil
  def embedded_url(body) do
    HTML.meta_refresh(body) || HTML.js_redirect(body)
  end

  defp do_walk(url, hops_left, _opts) when hops_left <= 0 do
    {:error, {:too_many_redirects, url}}
  end

  defp do_walk(url, hops_left, opts) do
    with {:ok, response} <- get_with_tls_fallback(url, opts) do
      cond do
        response.status in 300..399 and response.location != nil ->
          do_walk(absolutize(response.location, url), hops_left - 1, opts)

        next = embedded_url(response.body) ->
          follow_embedded(absolutize(next, url), url, response, hops_left, opts)

        true ->
          {:ok, %{url: url, body: response.body, status: response.status}}
      end
    end
  end

  defp follow_embedded(next, url, response, hops_left, opts) do
    if next == url do
      {:ok, %{url: url, body: response.body, status: response.status}}
    else
      do_walk(next, hops_left - 1, opts)
    end
  end

  # Portal pages on private addresses often present self-signed
  # certificates. When :insecure_tls is set, retry a failed TLS
  # connection without verification -- for the portal walk only.
  defp get_with_tls_fallback(url, opts) do
    case HTTP.get(url, Keyword.delete(opts, :insecure_tls)) do
      {:error, {:failed_connect, info}} = error ->
        if Keyword.get(opts, :insecure_tls, false) and tls_failure?(info) do
          Logger.warning("goatfi: retrying #{redact(url)} without TLS verification")
          HTTP.get(url, opts)
        else
          error
        end

      other ->
        other
    end
  end

  defp tls_failure?(info) do
    info |> inspect() |> String.contains?("tls_alert")
  end

  defp pick_form(page) do
    forms = HTML.forms(page.body)

    scored =
      forms
      |> Enum.map(&{score(&1), &1})
      |> Enum.filter(fn {score, _form} -> is_integer(score) end)
      |> Enum.sort_by(fn {score, _form} -> score end, :desc)

    case scored do
      [{_score, form} | _rest] -> {:ok, form}
      [] when forms == [] -> {:error, {:no_form_found, page.url}}
      [] -> {:error, {:only_credential_forms, page.url}}
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp score(%Form{} = form) do
    field_names = Enum.map(form.fields, fn {name, _value} -> String.downcase(name || "") end)

    password? =
      String.match?(form.raw, ~r/type\s*=\s*["']?password/i) or
        Enum.any?(field_names, &String.contains?(&1, "password"))

    if password? do
      :password_form
    else
      text = String.downcase(HTML.decode_entities(form.raw) <> " " <> (form.action || ""))

      submit_text =
        form.submits |> Enum.map_join(" ", fn {_name, value} -> value end) |> String.downcase()

      word_hits = Enum.count(@accept_words, &String.contains?(normalize(text), &1))
      submit_hits = Enum.count(@accept_words, &String.contains?(normalize(submit_text), &1))

      word_hits + submit_hits * 3 + length(form.checkboxes) * 2 +
        if(form.method == "post", do: 1, else: 0)
    end
  end

  # Fold the Swedish letters so the wordlist can stay ASCII.
  defp normalize(text) do
    text
    |> String.replace(["å", "ä"], "a")
    |> String.replace("ö", "o")
  end

  defp submit(page, %Form{} = form, opts) do
    action = absolutize(form.action || page.url, page.url)
    fields = build_fields(form, opts)

    Logger.info(
      "goatfi: submitting portal form to #{redact(action)} " <>
        "(#{form.method}, fields: #{inspect(Enum.map(fields, &elem(&1, 0)))})"
    )

    result =
      case form.method do
        "post" ->
          HTTP.post_form(action, fields, Keyword.merge(opts, headers: [{"referer", page.url}]))

        _get ->
          uri = URI.parse(action)
          query = URI.encode_query(fields)
          merged = %{uri | query: merge_query(uri.query, query)} |> URI.to_string()
          HTTP.get(merged, Keyword.merge(opts, headers: [{"referer", page.url}]))
      end

    with {:ok, response} <- result,
         {:ok, followed} <- follow_after_submit(response, action, opts) do
      {:ok,
       %{
         portal_url: page.url,
         submitted_to: action,
         method: form.method,
         fields: fields,
         final_status: followed.status
       }}
    end
  end

  defp follow_after_submit(response, url, opts) do
    cond do
      response.status in 300..399 and response.location != nil ->
        walk(absolutize(response.location, url), opts)

      next = embedded_url(response.body) ->
        walk(absolutize(next, url), opts)

      true ->
        {:ok, %{url: url, body: response.body, status: response.status}}
    end
  end

  defp build_fields(%Form{} = form, opts) do
    extra = opts |> Keyword.get(:extra_fields, %{}) |> Map.new()

    checkbox_fields = Enum.map(form.checkboxes, fn {name, value} -> {name, value} end)

    submit_field =
      case form.submits do
        [{name, value} | _rest] when is_binary(name) and name != "" -> [{name, value}]
        _other -> []
      end

    (form.fields ++ checkbox_fields ++ submit_field)
    |> Enum.reject(fn {name, _value} -> name in [nil, ""] end)
    |> Enum.map(fn {name, value} -> {name, Map.get(extra, name, value)} end)
    |> then(fn fields ->
      known = Enum.map(fields, &elem(&1, 0))
      fields ++ for {name, value} <- extra, name not in known, do: {name, value}
    end)
  end

  defp merge_query(nil, query), do: query
  defp merge_query("", query), do: query
  defp merge_query(existing, query), do: existing <> "&" <> query

  defp absolutize(target, base) do
    base |> URI.merge(target) |> URI.to_string()
  end

  # Portal URLs embed per-client tokens; keep logs useful but tidy.
  defp redact(url) do
    case URI.parse(url) do
      %URI{query: nil} -> url
      uri -> %{uri | query: "..."} |> URI.to_string()
    end
  end
end
