defmodule GoatfiTest do
  use ExUnit.Case, async: true

  describe "check/1 probe classification" do
    # check/1 talks to the network, so unit coverage of the pure
    # classification lives in the HTML/Portal tests; here we only pin
    # down behavior that needs no live network.
    test "reports an error when every probe is unreachable" do
      assert {:error, {:all_probes_failed, [_reason]}} =
               Goatfi.check(
                 probes: [%{url: "http://localhost:1/", expect: {:status, 204}}],
                 timeout: 250
               )
    end
  end
end
