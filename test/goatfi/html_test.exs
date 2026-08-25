defmodule Goatfi.HTMLTest do
  use ExUnit.Case, async: true

  alias Goatfi.HTML
  alias Goatfi.HTML.Form

  describe "forms/1" do
    test "parses a typical click-through portal form" do
      html = """
      <html><body>
      <form action="/portal/accept" method="POST">
        <input type="hidden" name="session" value="abc123"/>
        <input type="hidden" name="mac" value="aa:bb:cc:dd:ee:ff">
        <input type="checkbox" name="accept_terms" value="yes"> I accept the terms
        <button type="submit" name="action" value="connect">Connect</button>
      </form>
      </body></html>
      """

      assert [%Form{} = form] = HTML.forms(html)
      assert form.action == "/portal/accept"
      assert form.method == "post"
      assert form.fields == [{"session", "abc123"}, {"mac", "aa:bb:cc:dd:ee:ff"}]
      assert form.checkboxes == [{"accept_terms", "yes"}]
      assert form.submits == [{"action", "connect"}]
    end

    test "checkbox without a value defaults to on" do
      html = ~s(<form><input type="checkbox" name="agree"></form>)

      assert [%Form{checkboxes: [{"agree", "on"}]}] = HTML.forms(html)
    end

    test "submit input uses its value" do
      html = ~s(<form><input type="submit" name="go" value="Accept &amp; Connect"></form>)

      assert [%Form{submits: [{"go", "Accept & Connect"}]}] = HTML.forms(html)
    end

    test "keeps only the checked radio per group" do
      html = """
      <form>
        <input type="radio" name="plan" value="free">
        <input type="radio" name="plan" value="paid" checked>
      </form>
      """

      assert [%Form{fields: [{"plan", "paid"}]}] = HTML.forms(html)
    end

    test "select picks the selected option" do
      html = """
      <form>
        <select name="duration">
          <option value="1h">One hour</option>
          <option value="24h" selected>One day</option>
        </select>
      </form>
      """

      assert [%Form{fields: [{"duration", "24h"}]}] = HTML.forms(html)
    end

    test "handles single-quoted and unquoted attributes" do
      html = ~s(<form action='/go' method=post><input name=token value='t1'></form>)

      assert [%Form{action: "/go", method: "post", fields: [{"token", "t1"}]}] = HTML.forms(html)
    end

    test "multiple forms are all returned" do
      html = """
      <form action="/search"><input name="q"></form>
      <form action="/accept" method="post"><input type="checkbox" name="tos"></form>
      """

      assert [%Form{action: "/search"}, %Form{action: "/accept"}] = HTML.forms(html)
    end
  end

  describe "meta_refresh/1" do
    test "extracts the refresh URL" do
      html = ~s(<meta http-equiv="refresh" content="0;url=https://portal.example/login?t=1">)

      assert HTML.meta_refresh(html) == "https://portal.example/login?t=1"
    end

    test "is case-insensitive and tolerates spacing" do
      html = ~s(<META HTTP-EQUIV=Refresh CONTENT="5; URL = /portal">)

      assert HTML.meta_refresh(html) == "/portal"
    end

    test "returns nil when absent" do
      assert HTML.meta_refresh("<html><body>hello</body></html>") == nil
    end
  end

  describe "js_redirect/1" do
    test "extracts window.location assignment" do
      assert HTML.js_redirect(~s(<script>window.location = "http://portal.example/";</script>)) ==
               "http://portal.example/"
    end

    test "extracts location.href assignment" do
      assert HTML.js_redirect(~s(<script>location.href='/login';</script>)) == "/login"
    end

    test "extracts location.replace call" do
      assert HTML.js_redirect(~s{<script>location.replace("/go")</script>}) == "/go"
    end

    test "returns nil when absent" do
      assert HTML.js_redirect("<script>console.log('hi')</script>") == nil
    end
  end
end
