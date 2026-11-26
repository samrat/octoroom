defmodule Octoroom.Cloudflare.HTTPTest do
  use ExUnit.Case, async: true

  alias Octoroom.Cloudflare.HTTP

  test "returns an actionable error when app_id or app_secret is missing" do
    assert {:error, {:cloudflare_not_configured, msg}} = HTTP.new_session(%{})
    assert msg =~ ":app_id"
    assert msg =~ "Octoroom.Cloudflare.Local"

    assert {:error, {:cloudflare_not_configured, msg}} =
             HTTP.new_session(%{app_id: "app_123", app_secret: ""})

    assert msg =~ ":app_secret"
  end
end
