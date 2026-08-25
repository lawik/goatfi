defmodule GoatfiTest do
  use ExUnit.Case
  doctest Goatfi

  test "greets the world" do
    assert Goatfi.hello() == :world
  end
end
