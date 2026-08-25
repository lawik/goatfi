defmodule Goatfi.HTML do
  @moduledoc """
  A deliberately small HTML scraper for captive portal pages.

  Captive portals serve simple, mostly static markup, so Goatfi gets by
  with targeted extraction instead of a full HTML parser: forms with
  their fields, `<meta http-equiv="refresh">` targets, and the common
  JavaScript redirect idioms.
  """

  defmodule Form do
    @moduledoc "A parsed `<form>`: where to submit, how, and with which fields."

    defstruct action: nil, method: "get", fields: [], submits: [], checkboxes: [], raw: ""

    @type t :: %__MODULE__{
            action: String.t() | nil,
            method: String.t(),
            fields: [{String.t(), String.t()}],
            submits: [{String.t() | nil, String.t()}],
            checkboxes: [{String.t(), String.t()}],
            raw: String.t()
          }
  end

  @doc "Extract all forms from an HTML document."
  @spec forms(binary()) :: [Form.t()]
  def forms(html) do
    ~r/<form\b([^>]*)>(.*?)<\/form>/is
    |> Regex.scan(html)
    |> Enum.map(fn [_all, attrs, inner] -> build_form(attributes(attrs), inner) end)
  end

  @doc """
  Extract the target of a `<meta http-equiv="refresh">` tag, if present.
  """
  @spec meta_refresh(binary()) :: String.t() | nil
  def meta_refresh(html) do
    with [tag | _rest] <-
           Regex.run(~r/<meta\b[^>]*http-equiv\s*=\s*["']?refresh["']?[^>]*>/i, html),
         content when is_binary(content) <- attributes(tag)["content"],
         [_all, url] <- Regex.run(~r/url\s*=\s*["']?([^"'\s;>]+)/i, content) do
      url
    else
      _other -> nil
    end
  end

  @doc """
  Extract a JavaScript redirect target (`window.location = ...`,
  `location.href = ...`, `location.replace(...)`), if present.
  """
  @spec js_redirect(binary()) :: String.t() | nil
  def js_redirect(html) do
    assignment =
      Regex.run(
        ~r/(?:window\.|document\.|top\.)?location(?:\.href)?\s*=\s*["']([^"']+)["']/i,
        html
      )

    call = Regex.run(~r/location\.(?:replace|assign)\(\s*["']([^"']+)["']\s*\)/i, html)

    case assignment || call do
      [_all, url] -> url
      nil -> nil
    end
  end

  @doc "Decode the handful of HTML entities that show up in attribute values."
  @spec decode_entities(String.t()) :: String.t()
  def decode_entities(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&#x27;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&nbsp;", " ")
  end

  defp build_form(attrs, inner) do
    {fields, submits, checkboxes} = collect_inputs(inner)

    %Form{
      action: attrs["action"] && decode_entities(attrs["action"]),
      method: String.downcase(attrs["method"] || "get"),
      fields: fields,
      submits: submits,
      checkboxes: checkboxes,
      raw: inner
    }
  end

  # Walks <input>, <button>, <select>, and <textarea> elements, splitting
  # them into plain fields, submit controls, and checkboxes so the portal
  # logic can decide what a human would have submitted.
  defp collect_inputs(inner) do
    inputs =
      ~r/<input\b[^>]*>/i
      |> Regex.scan(inner)
      |> Enum.map(fn [tag] -> attributes(tag) end)

    buttons =
      ~r/<button\b([^>]*)>(.*?)<\/button>/is
      |> Regex.scan(inner)
      |> Enum.map(fn [_all, attrs, label] ->
        attributes(attrs) |> Map.put_new("type", "submit") |> Map.put("_label", strip_tags(label))
      end)

    selects =
      ~r/<select\b([^>]*)>(.*?)<\/select>/is
      |> Regex.scan(inner)
      |> Enum.map(fn [_all, attrs, options] ->
        attributes(attrs)
        |> Map.put("value", selected_option(options))
        |> Map.put("type", "select")
      end)

    textareas =
      ~r/<textarea\b([^>]*)>(.*?)<\/textarea>/is
      |> Regex.scan(inner)
      |> Enum.map(fn [_all, attrs, content] ->
        attributes(attrs) |> Map.put("value", String.trim(content)) |> Map.put("type", "textarea")
      end)

    (inputs ++ buttons ++ selects ++ textareas)
    |> Enum.reduce({[], [], []}, &sort_control/2)
    |> then(fn {fields, submits, checkboxes} ->
      {Enum.reverse(fields), Enum.reverse(submits), Enum.reverse(checkboxes)}
    end)
  end

  defp sort_control(control, acc) do
    type = String.downcase(control["type"] || "text")
    name = control["name"]
    value = decode_entities(control["value"] || "")
    add_control(type, name, value, control, acc)
  end

  defp add_control(type, name, value, control, {fields, submits, checkboxes})
       when type in ["submit", "image"] do
    label = control["_label"] || value
    {fields, [{name, if(value == "", do: label, else: value)} | submits], checkboxes}
  end

  defp add_control("checkbox", nil, _value, _control, acc), do: acc

  defp add_control("checkbox", name, value, _control, {fields, submits, checkboxes}) do
    {fields, submits, [{name, if(value == "", do: "on", else: value)} | checkboxes]}
  end

  defp add_control("radio", nil, _value, _control, acc), do: acc

  # Keep only the first (or checked) radio of each group, like a browser default.
  defp add_control("radio", name, value, control, {fields, submits, checkboxes} = acc) do
    cond do
      Map.has_key?(control, "checked") ->
        {List.keystore(fields, name, 0, {name, value}), submits, checkboxes}

      List.keymember?(fields, name, 0) ->
        acc

      true ->
        {[{name, value} | fields], submits, checkboxes}
    end
  end

  defp add_control(type, _name, _value, _control, acc) when type in ["button", "reset"], do: acc
  defp add_control(_type, nil, _value, _control, acc), do: acc

  defp add_control(_type, name, value, _control, {fields, submits, checkboxes}) do
    {[{name, value} | fields], submits, checkboxes}
  end

  defp selected_option(options_html) do
    selected =
      Regex.run(~r/<option\b([^>]*selected[^>]*)>([^<]*)/i, options_html)

    first = Regex.run(~r/<option\b([^>]*)>([^<]*)/i, options_html)

    case selected || first do
      [_all, attrs, label] -> attributes(attrs)["value"] || String.trim(label)
      nil -> ""
    end
  end

  defp strip_tags(html) do
    html |> String.replace(~r/<[^>]*>/, "") |> String.trim()
  end

  @doc false
  @spec attributes(String.t()) :: %{optional(String.t()) => String.t()}
  def attributes(tag) do
    pairs =
      ~r/([a-zA-Z0-9_:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>\/]+))/
      |> Regex.scan(tag)
      |> Map.new(fn
        [_all, key, dq] -> {String.downcase(key), dq}
        [_all, key, "", sq] -> {String.downcase(key), sq}
        [_all, key, "", "", bare] -> {String.downcase(key), bare}
      end)

    # Boolean attributes (checked, selected, disabled) carry meaning too.
    booleans =
      ~r/(?:^|\s)(checked|selected|disabled|required)(?=[\s>\/]|$)/i
      |> Regex.scan(tag)
      |> Map.new(fn [_all, key] -> {String.downcase(key), ""} end)

    Map.merge(booleans, pairs)
  end
end
