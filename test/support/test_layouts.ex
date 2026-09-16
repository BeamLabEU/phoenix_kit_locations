defmodule PhoenixKitLocations.Test.Layouts do
  @moduledoc """
  Minimal layouts for the LiveView test endpoint. Real layouts live in
  the host app and the phoenix_kit core — these just wrap LiveView
  content in an HTML shell so Phoenix.LiveViewTest can render it.
  """

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Test</title>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  # Mirrors the header fields core's admin layout reads from a plugin
  # LiveView's assigns (`page_section`, `page_crumbs`, `page_title`,
  # `page_action`), so tests can assert what lands in the breadcrumb bar.
  def app(assigns) do
    ~H"""
    <header id="test-admin-header">
      <.link
        :if={assigns[:page_section]}
        id="header-section"
        navigate={assigns[:page_section_path]}
      >
        {assigns[:page_section]}
      </.link>
      <.link
        :for={crumb <- assigns[:page_crumbs] || []}
        class="header-crumb"
        navigate={crumb[:path]}
      >
        {crumb.label}
      </.link>
      <span :if={assigns[:page_title]} id="header-title">{assigns[:page_title]}</span>
      <.link
        :if={assigns[:page_action]}
        id="header-action"
        navigate={assigns[:page_action].navigate}
        title={assigns[:page_action].label}
      >
        {assigns[:page_action].label}
      </.link>
    </header>
    <div id="test-flashes">
      <div :if={msg = Phoenix.Flash.get(@flash, :info)} id="flash-info" data-flash-kind="info">
        {msg}
      </div>
      <div :if={msg = Phoenix.Flash.get(@flash, :error)} id="flash-error" data-flash-kind="error">
        {msg}
      </div>
      <div
        :if={msg = Phoenix.Flash.get(@flash, :warning)}
        id="flash-warning"
        data-flash-kind="warning"
      >
        {msg}
      </div>
    </div>
    {@inner_content}
    """
  end

  # Phoenix's error pipeline will try to render "<status>.html" from the
  # layouts module if a LiveView raises during mount. Forward everything
  # to a single generic template so tests get a readable error instead of
  # a `no template defined` crash.
  def render(_template, assigns) do
    ~H"""
    <html>
      <body>
        <h1>Error</h1>
        <pre>{inspect(assigns[:reason] || assigns[:conn])}</pre>
      </body>
    </html>
    """
  end
end
