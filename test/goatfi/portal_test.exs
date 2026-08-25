defmodule Goatfi.PortalTest do
  use ExUnit.Case, async: false

  alias Goatfi.Portal

  # A minimal HTTP server: accepts one connection at a time and answers
  # from a routing function, enough to fake a captive portal.
  defmodule FakePortal do
    def start(router) do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

      {:ok, port} = :inet.port(listen)
      parent = self()
      pid = spawn_link(fn -> accept_loop(listen, router, parent) end)
      {port, pid}
    end

    defp accept_loop(listen, router, parent) do
      case :gen_tcp.accept(listen) do
        {:ok, socket} ->
          handle(socket, router, parent)
          accept_loop(listen, router, parent)

        {:error, _closed} ->
          :ok
      end
    end

    defp handle(socket, router, parent) do
      with {:ok, request} <- read_request(socket, "") do
        [request_line | _rest] = String.split(request, "\r\n")
        [method, path, _version] = String.split(request_line, " ", parts: 3)
        body = request |> String.split("\r\n\r\n", parts: 2) |> Enum.at(1, "")
        send(parent, {:request, method, path, body})
        {status, headers, response_body} = router.(method, path, body)

        response =
          "HTTP/1.1 #{status}\r\n" <>
            Enum.map_join(headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end) <>
            "content-length: #{byte_size(response_body)}\r\nconnection: close\r\n\r\n" <>
            response_body

        :gen_tcp.send(socket, response)
      end

      :gen_tcp.close(socket)
    end

    defp read_request(socket, acc) do
      case :gen_tcp.recv(socket, 0, 1000) do
        {:ok, data} ->
          acc = acc <> data

          if complete?(acc) do
            {:ok, acc}
          else
            read_request(socket, acc)
          end

        {:error, _reason} ->
          if acc == "", do: {:error, :closed}, else: {:ok, acc}
      end
    end

    defp complete?(request) do
      case String.split(request, "\r\n\r\n", parts: 2) do
        [headers, body] ->
          case Regex.run(~r/content-length:\s*(\d+)/i, headers) do
            [_all, length] -> byte_size(body) >= String.to_integer(length)
            nil -> true
          end

        _incomplete ->
          false
      end
    end
  end

  test "clears a click-through portal: redirect, form, submit, verify" do
    router = fn
      "GET", "/generate_204", _body ->
        if Process.whereis(:portal_cleared) do
          {"204 No Content", [], ""}
        else
          {"302 Found", [{"location", "/portal?session=s1"}], ""}
        end

      "GET", "/portal?session=s1", _body ->
        {"200 OK", [{"content-type", "text/html"}],
         """
         <html><body>
         <h1>Welcome to Guest WiFi</h1>
         <form action="/accept" method="post">
           <input type="hidden" name="session" value="s1">
           <input type="checkbox" name="terms" value="accepted"> I accept the terms of use
           <button type="submit" name="do" value="connect">Godk&auml;nn och anslut</button>
         </form>
         </body></html>
         """}

      "POST", "/accept", body ->
        fields = URI.decode_query(body)

        if fields["session"] == "s1" and fields["terms"] == "accepted" do
          # Register cleared state in a way both router closures can see.
          Process.register(spawn(fn -> Process.sleep(:infinity) end), :portal_cleared)
          {"302 Found", [{"location", "/welcome"}], ""}
        else
          {"403 Forbidden", [], "bad submission"}
        end

      "GET", "/welcome", _body ->
        {"200 OK", [{"content-type", "text/html"}], "<html><body>You are online.</body></html>"}
    end

    {port, _pid} = FakePortal.start(router)
    base = "http://127.0.0.1:#{port}"
    probes = [%{url: "#{base}/generate_204", expect: {:status, 204}}]

    try do
      assert {:portal, portal_url} = Goatfi.check(probes: probes)
      assert portal_url == "#{base}/portal?session=s1"

      assert {:ok, :cleared} = Goatfi.ensure(probes: probes)

      assert_received {:request, "POST", "/accept", body}
      fields = URI.decode_query(body)
      assert fields["do"] == "connect"
    after
      if pid = Process.whereis(:portal_cleared) do
        Process.unregister(:portal_cleared)
        Process.exit(pid, :kill)
      end
    end
  end

  test "refuses to touch a credentials-only portal" do
    router = fn
      "GET", "/portal", _body ->
        {"200 OK", [{"content-type", "text/html"}],
         """
         <form action="/login" method="post">
           <input type="text" name="username">
           <input type="password" name="password">
           <input type="submit" value="Log in">
         </form>
         """}
    end

    {port, _pid} = FakePortal.start(router)

    assert {:error, {:only_credential_forms, _url}} =
             Portal.clear("http://127.0.0.1:#{port}/portal")
  end

  test "follows meta refresh hops to the portal page" do
    router = fn
      "GET", "/start", _body ->
        {"200 OK", [{"content-type", "text/html"}],
         ~s(<meta http-equiv="refresh" content="0;url=/portal">)}

      "GET", "/portal", _body ->
        {"200 OK", [{"content-type", "text/html"}],
         ~s(<form action="/accept" method="post"><input type="checkbox" name="tos"></form>)}
    end

    {port, _pid} = FakePortal.start(router)

    assert {:ok, page} = Portal.walk("http://127.0.0.1:#{port}/start")
    assert page.url == "http://127.0.0.1:#{port}/portal"
  end

  test "gives up on redirect loops" do
    router = fn
      "GET", _path, _body -> {"302 Found", [{"location", "/loop"}], ""}
    end

    {port, _pid} = FakePortal.start(router)

    assert {:error, {:too_many_redirects, _url}} =
             Portal.walk("http://127.0.0.1:#{port}/loop")
  end
end
