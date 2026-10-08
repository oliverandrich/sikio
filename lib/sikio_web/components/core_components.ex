# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  It holds the basic building blocks such as tables, forms and inputs.
  The components are mostly markup, with doc strings and declared attributes.
  This app owns them and may change their markup and styling.

  Styling uses vanilla [Tailwind CSS](https://tailwindcss.com) utilities.
  Useful references:

    * [Lucide Icons](https://github.com/zoedsoupe/lucide_icons) - use `Lucideicons` components.

    * [Phoenix.Component](https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: SikioWeb.Gettext

  alias Phoenix.HTML.Form
  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="fixed top-4 right-4 z-50 max-w-[calc(100vw-2rem)]"
      {@rest}
    >
      <div class={[
        "flex w-80 max-w-full items-start gap-3 rounded-control border p-4 text-label shadow-lg sm:w-96",
        @kind == :info &&
          "border-line bg-surface text-ink",
        @kind == :error &&
          "border-danger bg-danger-surface text-ink"
      ]}>
        <Lucideicons.info :if={@kind == :info} aria-hidden="true" class="size-5 shrink-0" />
        <Lucideicons.circle_alert :if={@kind == :error} aria-hidden="true" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label={gettext("close")}>
          <Lucideicons.x aria-hidden="true" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a modal confirmation dialog for bulk changes.

  Render it only while it should be open. On mount it dispatches `sikio:show`.
  `assets/js/app.js` then calls `showModal()`; see that file.
  The dialog focuses itself, so no button shows a focus ring before the first Tab.
  The server never renders `open`, and `JS.ignore_attributes/1` keeps it across patches.
  The buttons send `confirm_<name>` and `cancel_<name>`; Escape sends `cancel_<name>`.
  Events go to `target` when given.
  """
  attr :name, :string, required: true
  attr :title, :string, required: true
  attr :confirm_label, :string, required: true
  attr :variant, :string, default: "primary", doc: "danger when the answer cannot be undone"
  attr :wide, :boolean, default: false, doc: "room for a form rather than a question"
  attr :target, :any, default: nil, doc: "the component that answers, rather than the view"
  slot :inner_block, required: true
  slot :aside, doc: "another way out, at the left of the buttons"

  def confirm_dialog(assigns) do
    assigns = assign(assigns, :event, String.replace(assigns.name, "-", "_"))

    ~H"""
    <dialog
      id={"#{@name}-confirm"}
      tabindex="-1"
      autofocus
      aria-labelledby={"#{@name}-heading"}
      phx-mounted={JS.ignore_attributes(["open"]) |> JS.dispatch("sikio:show")}
      phx-window-keydown={"cancel_#{@event}"}
      phx-key="Escape"
      phx-target={@target}
      class={[
        "m-auto rounded-lg border border-line bg-surface text-ink shadow-2xl outline-none backdrop:bg-black/30",
        if(@wide, do: "w-[min(34rem,calc(100vw-2rem))]", else: "w-[min(28rem,calc(100vw-2rem))]")
      ]}
    >
      <div class="p-5 sm:p-6">
        <h2 id={"#{@name}-heading"} class="text-[17px] leading-6 font-semibold">{@title}</h2>
        <div class={["text-sm text-muted", if(@wide, do: "mt-5", else: "mt-2")]}>
          {render_slot(@inner_block)}
        </div>
      </div>
      <%!-- Action bar. Below `sm` the buttons stack with confirm on top. From `sm` they form a
      right-aligned row, with the `aside` slot at the far left. --%>
      <div
        id={"#{@name}-actions"}
        class="flex flex-col gap-2 rounded-b-lg border-t border-line bg-ground px-5 py-4 sm:flex-row-reverse sm:items-center sm:gap-3 sm:px-6"
      >
        <.button
          id={"confirm-#{@name}"}
          type="button"
          variant={@variant}
          phx-click={"confirm_#{@event}"}
          phx-target={@target}
        >
          {@confirm_label}
        </.button>
        <.button
          id={"cancel-#{@name}"}
          type="button"
          phx-click={"cancel_#{@event}"}
          phx-target={@target}
        >
          {gettext("Cancel")}
        </.button>
        <div :if={@aside != []} class="flex justify-center sm:mr-auto">{render_slot(@aside)}</div>
      </div>
    </dialog>
    """
  end

  @doc "Returns text field classes for dialogs: touch height on phones, button height from `sm`."
  def dialog_field,
    do:
      "min-h-11 rounded-control border border-edge bg-surface px-3 text-sm text-ink placeholder:text-muted sm:min-h-9 focus-visible:outline-2 focus-visible:outline-accent"

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled type)
  attr :class, :any, default: nil, doc: "added to the button's own classes"
  attr :variant, :string, values: ~w(primary danger)
  slot :inner_block, required: true

  # A disabled filled button renders as an outline button instead of a grey block.
  @stepped_back "disabled:border disabled:border-edge disabled:bg-surface disabled:text-muted disabled:shadow-none"

  def button(%{rest: rest} = assigns) do
    variants = %{
      "primary" => ["bg-accent text-on-accent hover:bg-accent/85", @stepped_back],
      "danger" => ["bg-danger text-on-accent hover:bg-danger/85", @stepped_back],
      nil => "border border-edge bg-surface text-ink hover:bg-ground disabled:opacity-50"
    }

    assigns =
      assign(assigns, :class, [
        "inline-flex min-h-11 items-center justify-center gap-2 rounded-control px-3 py-2 text-sm font-semibold shadow-xs transition-colors sm:min-h-9 cursor-pointer disabled:cursor-not-allowed focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent",
        Map.fetch!(variants, assigns[:variant]),
        assigns.class
      ])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="mb-4 space-y-1">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="inline-flex items-center gap-2 text-label font-semibold">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={
              @class ||
                "size-4 rounded border-control accent-accent focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
            }
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="mb-4 space-y-1">
      <label for={@id}>
        <span :if={@label} class="mb-1 block text-label font-semibold">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[
            @class ||
              field_class(),
            @errors == [] && "border-control",
            @errors != [] &&
              (@error_class || "border-danger outline-danger")
          ]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="mb-4 space-y-1">
      <label for={@id}>
        <span :if={@label} class="mb-1 block text-label font-semibold">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class ||
              [field_class(), "min-h-28"],
            @errors == [] && "border-control",
            @errors != [] &&
              (@error_class || "border-danger outline-danger")
          ]}
          {@rest}
        >{Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Renders the remaining types, such as text, url, password and datetime-local.
  def input(assigns) do
    ~H"""
    <div class="mb-4 space-y-1">
      <label for={@id}>
        <span :if={@label} class="mb-1 block text-label font-semibold">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Form.normalize_value(@type, @value)}
          class={[
            @class ||
              field_class(),
            @errors == [] && "border-control",
            @errors != [] &&
              (@error_class || "border-danger outline-danger")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc """
  Renders rows in a card with an optional heading above it, like an iOS settings group.
  `tag` is the card's element, `nav` for a group of links.
  """
  attr :id, :string, required: true
  attr :heading, :string, default: nil
  attr :tag, :string, default: "div"
  slot :action, doc: "a link beside the heading"
  slot :inner_block, required: true

  def group(assigns) do
    ~H"""
    <section id={@id} class="mb-6" aria-labelledby={@heading && "#{@id}-heading"}>
      <div :if={@heading} class="mb-2 flex items-baseline justify-between gap-3 px-4">
        <h2 id={"#{@id}-heading"} class="text-meta font-semibold tracking-wider text-muted uppercase">
          {@heading}
        </h2>
        <span :if={@action != []} class="text-label">{render_slot(@action)}</span>
      </div>
      <.dynamic_tag
        tag_name={@tag}
        class="flex flex-col divide-y divide-line overflow-hidden rounded-xl bg-surface ring-1 ring-line"
      >
        {render_slot(@inner_block)}
      </.dynamic_tag>
    </section>
    """
  end

  @doc "Renders a row of `group/1` that leads to another page."
  attr :to, :string, required: true
  attr :detail, :any, default: nil, doc: "muted text before the chevron, such as a count"
  slot :icon
  slot :inner_block, required: true

  def group_link(assigns) do
    ~H"""
    <.link
      navigate={@to}
      class="flex min-h-12 items-center gap-3 px-4 text-body text-ink hover:bg-ground"
    >
      {render_slot(@icon)}
      <span class="min-w-0 grow truncate">{render_slot(@inner_block)}</span>
      <span :if={@detail} class="font-mono text-meta text-muted">{@detail}</span>
      <Lucideicons.chevron_right aria-hidden="true" class="size-4 shrink-0 text-muted" />
    </.link>
    """
  end

  @doc "Renders a field's error message, for fields not rendered by `input/1`."
  attr :id, :string, default: nil
  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p id={@id} class="mt-1.5 flex gap-2 items-center text-label text-danger">
      <Lucideicons.circle_alert aria-hidden="true" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <%!-- On phones, the top bar shows the title once this heading scrolls under it. --%>
        <h1 data-large-title class="text-title font-semibold">
          {render_slot(@inner_block)}
        </h1>
        <p
          :if={@subtitle != []}
          class="mt-2 max-w-xl text-muted"
        >
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="w-full text-left text-body [&_th]:px-4 [&_th]:py-3 [&_th]:font-semibold [&_th]:text-label [&_th]:text-muted [&_td]:px-4 [&_td]:py-3 [&_tbody_tr]:border-t [&_tbody_tr]:border-line">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="divide-y divide-line">
      <li :for={item <- @item} class="flex gap-4 py-4">
        <div class="min-w-0 flex-1">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # Gettext macros take static strings, which `mix gettext.extract` collects:
    #
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # Changeset errors are dynamic, so this calls the `Gettext` functions with the backend.
    # Translations live in errors.po, the "errors" domain.
    if count = opts[:count] do
      Gettext.dngettext(SikioWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(SikioWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end

  # Shared by the text, select and textarea inputs.
  @doc "Returns text field classes outside dialogs, for fields not rendered by `input/1`."
  def field_class,
    do:
      "block w-full rounded-control border border-edge bg-surface px-3 py-2 text-ink placeholder:text-muted focus:border-accent focus:outline-2 focus:outline-accent disabled:cursor-not-allowed disabled:opacity-50"
end
