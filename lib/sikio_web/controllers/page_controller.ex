defmodule SikioWeb.PageController do
  use SikioWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
