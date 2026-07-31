defmodule Cgc2046Web.ErrorJSONTest do
  use Cgc2046Web.ConnCase, async: true

  test "renders 404" do
    assert Cgc2046Web.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert Cgc2046Web.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
