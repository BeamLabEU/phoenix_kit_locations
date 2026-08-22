<!-- ПРИМЕЧАНИЕ ОРКЕСТРАТОРА 2026-07-10: решения по открытым вопросам планировщика -->
> **Решения по открытым вопросам (2026-07-10):**
> 1. **v0.5 (PlacePicker) делаем сейчас** — потребитель: опциональная финальная задача T23 волны 1 склада (замена `<select>` на PlacePicker); волна 1 склада на пикер НЕ блокируется (стартует с `<select>`).
> 2. **Локали en/et/ru** — как у соседних модулей (manufacturing/warehouse), весь набор core не требуется.
> 3. **Мультиязычность name/description Space СОХРАНЯЕМ** (MultilangForm, как в старом floor/room-флоу) — новая вкладка не должна регрессировать существующую функциональность. Задачу 13 расширить соответственно.
> 4. **Immediate commit = submit-сохранение формы** (не автосейв на каждый ввод); rename/reorder — мгновенные. Подтверждено.
> 5. **Hard delete с CASCADE — подтверждён**, обязательно модальное подтверждение с количеством дочерних узлов.
>
> **Правка кросс-чека:** публичный API пути — `Spaces.full_path/2` (НЕ `Paths.full_path` — Paths остаётся модулем URL-хелперов); DEVELOPMENT_PLAN.md §5 обновлён.

> Ревью-правки (многораундовое ревью 2026-07-10: GLM High+Max / Sonnet / Kimi / Vibe / Opus-max) интегрированы в тексты задач.


# План: иерархия площадок в phoenix_kit_locations (v0.3 → v0.5)

## Цель

Реализовать план из `dev_docs/DEVELOPMENT_PLAN.md`: расширить `Space.kind` до полного набора внутренних уровней, построить N-уровневое дерево Spaces с immediate-commit CRUD во вкладке "Structure" карточки локации (взамен текущего staged floor/room-черновика), и дать другим модулям (склад, производство) API для работы с местом: `PlacePicker`, `Spaces.full_path/2`, готовый resolve-набор `list_locations/1` + `get_location_type_by_name/1`.

## Текущее состояние (подтверждено чтением кода 2026-07-10)

- `PhoenixKitLocations.Schemas.Space` (`lib/phoenix_kit_locations/schemas/space.ex`) — self-ref дерево, `@kinds ~w(floor room)`, `kinds/0`/`statuses/0` уже есть. CHECK в БД (core V122) уже разрешает `floor room hall suite section zone aisle shelf corner` — расширение `@kinds` не требует миграции.
- `PhoenixKitLocations.Spaces` (`lib/phoenix_kit_locations/spaces.ex`) — полноценный CRUD-контекст: `list_for_location/1`, `list_tree/1`, `create_space/2`, `update_space/3`, `delete_space/2` (hard-delete, CASCADE детям), `reorder_siblings/4`. Инвариант "родитель из той же Location" и защита от циклов уже реализованы на уровне контекста.
- `PhoenixKitLocations.Web.LocationFormLive` (`lib/phoenix_kit_locations/web/location_form_live.ex`, 2338 строк) — форма локации в двух `<.form>` блоках (`location-form-top` / `location-form-bottom`), между которыми сейчас сидит секция "Spaces" со staged floor/room-черновиками (drafts в `socket.assigns.space_drafts`, коммит только по общей кнопке Save). Разделение на два `<.form>` существует **только из-за** этой секции (см. `merge_running_changes/2`).
- `PhoenixKitLocations.Attachments` (`lib/phoenix_kit_locations/attachments.ex`) — multi-scope файлы/featured image, уже поддерживает `%Space{}` в `folder_name_for/1`. Работает без изменений.
- Модуль **не имеет собственного gettext backend** — `use Gettext, backend: PhoenixKitWeb.Gettext` (core). Core — Hex-зависимость, править `.po` там нельзя (INERT). Прецедент решения уже есть в двух соседних path-dep модулях: `PhoenixKitManufacturing.Gettext` (`phoenix_kit_manufacturing/lib/phoenix_kit_manufacturing/gettext.ex`) и `PhoenixKitWarehouse.Gettext` — тонкий `use Gettext.Backend, otp_app: :app_name`, локали `en/et/ru` (`priv/gettext/{en,et,ru}/LC_MESSAGES/default.po` + `default.pot`).
- `PhoenixKitWarehouse.Web.Components.WarehouseHeader` (`phoenix_kit_warehouse/lib/phoenix_kit_warehouse/web/components/warehouse_header.ex`) — прецедент "общий tab-header между несколькими LiveView одной сущности": `role="tablist"` + `<.link navigate>` + daisyUI `tabs tabs-border` / `tab-active`. Это модель для новой вкладки "Structure" (два разных route/LiveView, примечание 2026-08-22: `<.nav_tabs>` умеет и `navigate` (и всегда умел), так что `LocationTabs` теперь рендерится через него — обёртка осталась только ради локального API).
- `PhoenixKitWeb.Components.FolderExplorer` (`/www/app/deps/phoenix_kit/lib/phoenix_kit_web/components/folder_explorer.ex`) — модель рекурсивного узла дерева: MapSet-based expand state, `on_navigate`/`on_toggle`/`show_rename`/`enable_drag` как настраиваемые атрибуты (уже используется в двух режимах — сайдбар и move-picker в MediaBrowser). Это прямой прототип для `space_tree_node/1`.
- `PhoenixKitCatalogue.Web.Components.ItemPicker` (`phoenix_kit_catalogue/lib/phoenix_kit_catalogue/web/components/item_picker.ex`) — прецедент self-contained search-combobox LiveComponent с сообщением `{:item_picker_select, id, item}`, N экземпляров на странице по `id`. Тестируется через реальный host LiveView (`test/web/item_picker_events_test.exs`), не изолированно.
- `PhoenixKitCatalogue.Catalogue.Tree` (`phoenix_kit_catalogue/lib/phoenix_kit_catalogue/catalogue/tree.ex`) — `ancestor_uuids/1` + `ancestors_in_order/1`: рекурсивный CTE (`UNION`, не `UNION ALL` — cycle-safe) + `walk_up/3`. Прямой шаблон для `Spaces.full_path/2`.
- `Locations.list_locations/1` уже принимает `type_uuid:`, `Locations.get_location_type_by_name/1` уже существует — связка "тип по имени → locations по type_uuid" из §5 DEVELOPMENT_PLAN **уже реализована**, новый код не нужен.
- `lib/phoenix_kit_locations.ex` — `admin_tabs/0`: статические пути обязаны идти раньше `:uuid`-wildcard путей; текущий `admin_locations_edit` — `path: "locations/:uuid/edit"`, `live_view: {LocationFormLive, :edit}`.
- Тесты: `test/support/data_case.ex`, `live_case.ex`, `test_router.ex` (роуты, повторяющие `Paths`), `test/phoenix_kit_locations/schemas/space_test.exs` — докстрока файла уже обещает "cross-row invariant тестируется в `test/spaces_test.exs`", но этого файла ещё не существует.

## Что НЕ трогаем

- `CHANGELOG.md`, `@version` в `mix.exs` — maintainer-owned.
- Core `.po`/миграции phoenix_kit — Hex-зависимость, edits инертны.
- `mix.exs` версию pin `phoenix_kit` не трогаем, если только новый функционал не потребует более новой версии core (не должен — CHECK для kinds уже широкий).
- DB-миграции модуля — не нужны (kinds уже покрыты CHECK V122).

## Общее по проверке

`phoenix_kit_locations` — path dep в `/www/app` (`{:phoenix_kit_locations, path: "../phoenix_kit_locations", override: true}`). Любое изменение файла в этом репо не хот-релоадится в andi — после каждого блока задач, который нужно увидеть живьём в UI andi, требуется `sudo /usr/bin/supervisorctl restart elixir` (для admin_tabs — обязательно, boot-time discovery). Внутри самого `phoenix_kit_locations` для быстрой проверки логики используем `mix test` / `mix compile --warnings-as-errors` / `mix format` — эти команды не требуют andi вообще.

---

# v0.3 — Kinds + gettext + типы

## Задача 1. Собственный gettext backend модуля

**Файлы:**
- Создать `/www/phoenix_kit_locations/lib/phoenix_kit_locations/gettext.ex`:
  ```elixir
  defmodule PhoenixKitLocations.Gettext do
    @moduledoc "Gettext backend for phoenix_kit_locations."
    use Gettext.Backend, otp_app: :phoenix_kit_locations
  end
  ```
  (дословно мирроринг `PhoenixKitManufacturing.Gettext`.)
- Создать пустые каталоги `priv/gettext/en/LC_MESSAGES/`, `priv/gettext/et/LC_MESSAGES/`, `priv/gettext/ru/LC_MESSAGES/` (локали — как в manufacturing/warehouse; шаблон и `.po` наполнятся в задаче 3).
- В `mix.exs` → `defp package do ... files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)` — список **не включает `priv`**, из-за чего новые `.po`/`.pot` не попадут в опубликованный Hex-артефакт. Добавить `"priv"` в этот список (`files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)`); на компиляцию/тесты path-dep это не влияет, важно только для будущей публикации в Hex.

**Важно:** это НЕ заменяет `PhoenixKitWeb.Gettext` в существующих файлах (`location_form_live.ex`, `locations_live.ex`, `location_type_form_live.ex`) — трогать их backend не нужно, риск потерять уже работающие (пусть и случайные) переводы. Новый backend используется **только** для нового кода этого рефакторинга: `kind_label/1`/`kind_icon/1` (задача 2), новые компоненты и `LocationStructureLive`/`PlacePicker` (v0.4/v0.5).

**Проверка:** `cd /www/phoenix_kit_locations && mix compile` — модуль компилируется, `mix gettext.extract` (dry run, каталог пуст) отрабатывает без ошибок.

## Задача 2. Расширение `Space.@kinds` + `kind_label/1` + `kind_icon/1`

**Файл:** `/www/phoenix_kit_locations/lib/phoenix_kit_locations/schemas/space.ex`

- Заменить `@kinds ~w(floor room)` на `@kinds ~w(floor room zone section aisle shelf)` (список из §3 DEVELOPMENT_PLAN — без `hall/suite/corner`, они остаются зарезервированы в CHECK, но не используются на app-уровне).
- Обновить `@moduledoc`/комментарий над `@kinds` (сейчас гласит "V1 of the Spaces UI only exposes two kinds") — привести в соответствие с новым списком.
- Добавить `use Gettext, backend: PhoenixKitLocations.Gettext` в модуль (рядом с `use Ecto.Schema`/`import Ecto.Changeset`) — **обязательно макро-форма**, а не функциональный вызов `Gettext.gettext(Backend, "...")`: `mix gettext.extract` сканирует только макро-вызовы (`gettext/1,2,3`), функциональная форма им не видна и msgid не попадёт в `.pot` (см. задачу 3). Стиль `Gettext.gettext(Backend, "...")` из `attachments.ex` здесь не подходит именно по этой причине.
- Добавить публичные функции рядом с `kinds/0`/`statuses/0` (единый источник истины label+icon — переиспользуются `SpaceTree`, детальной панелью `LocationStructureLive` и picker-режимом в v0.5):
  ```elixir
  @spec kind_label(String.t()) :: String.t()
  def kind_label("floor"),   do: gettext("Floor")
  def kind_label("room"),    do: gettext("Room")
  def kind_label("zone"),    do: gettext("Zone")
  def kind_label("section"), do: gettext("Section")
  def kind_label("aisle"),   do: gettext("Aisle")
  def kind_label("shelf"),   do: gettext("Shelf")
  def kind_label(kind),      do: kind

  @spec kind_icon(String.t()) :: String.t()
  def kind_icon("floor"),   do: "hero-building-office-2"
  def kind_icon("room"),    do: "hero-squares-2x2"
  def kind_icon("zone"),    do: "hero-map"
  def kind_icon("section"), do: "hero-view-columns"
  def kind_icon("aisle"),   do: "hero-arrows-right-left"
  def kind_icon("shelf"),   do: "hero-archive-box"
  def kind_icon(_kind),     do: "hero-cube"
  ```
  (`gettext/1` здесь — макро из `use Gettext, backend: PhoenixKitLocations.Gettext` выше, а не вызов ядра; `kind_icon` — чисто косметика, если конкретное имя heroicon отсутствует в собранном наборе — заменить на любое существующее, не блокирует остальной план.)
- Никаких изменений в `changeset/2` не нужно — `validate_inclusion(:kind, @kinds)` и `check_constraint` уже читают `@kinds` динамически.

**Проверка:** `mix test test/phoenix_kit_locations/schemas/space_test.exs` — расширить существующий файл кейсами "accepts zone/section/aisle/shelf" (по образцу уже существующих "accepts floor"/"accepts room") + новый `describe "kind_label/1 and kind_icon/1"` с прямыми вызовами. `mix test`.

## Задача 3. Наполнение gettext-каталогов

**Команды (в `/www/phoenix_kit_locations`):**
```
mix gettext.extract
mix gettext.merge priv/gettext --locale en
mix gettext.merge priv/gettext --locale et
mix gettext.merge priv/gettext --locale ru
```
Затем вручную заполнить `msgstr` в `priv/gettext/et/LC_MESSAGES/default.po` и `priv/gettext/ru/LC_MESSAGES/default.po` для 6 новых msgid (Floor/Room/Zone/Section/Aisle/Shelf) — `en/default.po` можно оставить пустым (msgid == отображаемый текст по умолчанию в Gettext).

**Проверка:** `mix compile` (нет warning о непереведённых msgid), затем через Tidewave в andi (после restart, см. общий раздел проверки) — `Gettext.put_locale(PhoenixKitLocations.Gettext, "ru"); PhoenixKitLocations.Schemas.Space.kind_label("zone")` должно вернуть русский текст.

## Задача 4. Данные: создать LocationType Workshop и Office

Не код — ручной шаг в UI andi (`/admin/locations/types/new`, поля Name + опционально Description, как в `location_type_form_live.ex`) **или** через Tidewave:
```elixir
PhoenixKitLocations.Locations.create_location_type(%{name: "Workshop", description: "Production floor location"})
PhoenixKitLocations.Locations.create_location_type(%{name: "Office", description: "Office building location"})
```

**Проверка:** `PhoenixKitLocations.Locations.list_location_types()` в Tidewave показывает 3 типа (Warehouse, Workshop, Office); `/admin/locations/types` в UI показывает все три.

---

# v0.4 — Дерево Spaces во вкладке "Structure"

## Задача 5. Вынести `files_card_body/1` в общий компонент

**Файлы:**
- Создать `/www/phoenix_kit_locations/lib/phoenix_kit_locations/web/components/files_card.ex` — модуль `PhoenixKitLocations.Web.Components.FilesCard`, публичная функция `files_card_body/1` (перенести 1:1 из `location_form_live.ex` — `attr` декларации начинаются ~2021, сама функция `files_card_body/1` фактически начинается на строке **2028** (не 2015 — это уже attr-декларации), заканчивается ~2228; ориентироваться по имени функции/`attr`, а не по номерам строк; `use Phoenix.Component`, `use Gettext, backend: PhoenixKitWeb.Gettext` — backend НЕ менять, это существующие строки core, просто переехавшие; `import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]`; `alias PhoenixKit.Modules.Storage.URLSigner`; `alias PhoenixKitLocations.Attachments`).
- В `location_form_live.ex`: удалить `attr` декларации (~2021-2026) и private `files_card_body/1` (начинается ~2028, заканчивается ~2228 — ориентироваться по имени функции), добавить `import PhoenixKitLocations.Web.Components.FilesCard, only: [files_card_body: 1]`. Удалить ставший неиспользуемым `alias PhoenixKit.Modules.Storage.URLSigner` в `location_form_live.ex` — все 5 обращений к `URLSigner.signed_url/2` живут внутри переносимого `files_card_body/1`, больше нигде в файле алиас не используется, иначе `mix compile --warnings-as-errors` (шаг "Проверка" этой же задачи) упадёт на unused-alias. Три существующих call-сайта (`location_scope()`, `@floor.id`, `@room.id`) продолжают работать без изменений.
- JS hook `PkLocationsUploadScope` (сейчас raw `<script>` на строках 1297-1312 в `location_form_live.ex`, регистрирует хук глобально через `window.PhoenixKitHooks`, вне `files_card_body/1`) — при переносе конвертировать в **ColocatedHook** и разместить внутри `FilesCard`, рядом с `files_card_body/1` (конвенция CLAUDE.md: раздельные raw `<script>` запрещены, только `:type={Phoenix.LiveView.ColocatedHook}` с именем хука через точку — по образцу `ItemPicker` в catalogue): `<script :type={Phoenix.LiveView.ColocatedHook} name=".PkLocationsUploadScope">export default { mounted() { ... } }</script>`, тело `mounted()` — 1:1 перенос текущей логики (`dragenter` → `pushEvent("set_active_upload_scope", %{scope: ...})`). Обновить атрибут дропзоны внутри самой `files_card_body/1` (строка 2131) — `phx-hook="PkLocationsUploadScope"` → `phx-hook=".PkLocationsUploadScope"`. Удалить старый raw `<script>`-блок (1297-1312) и его doc-комментарий из `location_form_live.ex` целиком: колокированный хук компилируется в общий JS-манифест один раз при сборке ассетов и автоматически доступен любому LiveView, рендерящему `<.files_card_body>` — дублировать регистрацию в `LocationStructureLive` (задача 13) не требуется.

**Проверка:** `mix compile --warnings-as-errors`; `mix test test/phoenix_kit_locations/web/location_form_live_test.exs` — Files-карточка локации рендерится и работает как раньше (все существующие assertions на "Attached Files"/featured image должны пройти без изменений).

## Задача 6. `Paths.location_structure/1`

**Файл:** `/www/phoenix_kit_locations/lib/phoenix_kit_locations/paths.ex`

Добавить рядом с `location_edit/1`:
```elixir
@spec location_structure(String.t()) :: String.t()
def location_structure(uuid), do: Routes.path("#{@base}/#{uuid}/structure")
```

**Проверка:** `iex -S mix` → `PhoenixKitLocations.Paths.location_structure("abc")` возвращает `"/admin/locations/abc/structure"` (без locale-префикса вне HTTP-контекста, как и остальные `Paths.*`).

## Задача 7. Общий tab-header "Details / Structure"

**Файл:** создать `/www/phoenix_kit_locations/lib/phoenix_kit_locations/web/components/location_tabs.ex` — модуль `PhoenixKitLocations.Web.Components.LocationTabs`, мирроринг `PhoenixKitWarehouse.Web.Components.WarehouseHeader`:

```elixir
defmodule PhoenixKitLocations.Web.Components.LocationTabs do
  use Phoenix.Component
  use Gettext, backend: PhoenixKitLocations.Gettext

  alias PhoenixKitLocations.Paths

  attr :location, :map, required: true
  attr :active, :atom, required: true, values: [:details, :structure]

  def location_tabs(assigns) do
    ~H"""
    <div role="tablist" class="tabs tabs-border mb-4">
      <.link role="tab" navigate={Paths.location_edit(@location.uuid)} class={["tab", @active == :details && "tab-active"]}>
        {gettext("Details")}
      </.link>
      <.link role="tab" navigate={Paths.location_structure(@location.uuid)} class={["tab", @active == :structure && "tab-active"]}>
        {gettext("Structure")}
      </.link>
    </div>
    """
  end
end
```
(backend — собственный `PhoenixKitLocations.Gettext` из задачи 1, а НЕ core `PhoenixKitWeb.Gettext`: `WarehouseHeader` — прецедент для этого компонента — на самом деле использует `use Gettext, backend: PhoenixKitWarehouse.Gettext`, свой собственный backend модуля, а не core (`warehouse_header.ex:12`); для `LocationTabs` следовать тому же паттерну.)

Только показывается когда локация уже существует (`@action == :edit`) — на `:new` вкладки Structure не может быть (нет `location_uuid`).

**Проверка:** пока изолированно не рендерится нигде — проверяется вместе с задачей 9 (компилируется, атрибуты корректны).

## Задача 8. `SpaceTree` компонент (рекурсивный узел дерева)

**Файл:** создать `/www/phoenix_kit_locations/lib/phoenix_kit_locations/web/components/space_tree.ex` — модуль `PhoenixKitLocations.Web.Components.SpaceTree`, адаптация `PhoenixKitWeb.Components.FolderExplorer.folder_tree_node/1` под узлы `Spaces.list_tree/1`.

**Важно про форму узла:** `Spaces.list_tree/1` возвращает список `%Space{}` (не `Folder` struct и НЕ обёртку `%{space: ..., children: ...}`) — `build_tree/2` кладёт вложенный список детей прямо в поле `:children` того же struct (`Map.put(space, :children, ...)`, `spaces.ex:73-79`, `:children` — существующая `has_many` ассоциация схемы). Значит все поля узла читаются напрямую: `node.kind`, `node.uuid`, `node.name`, `node.status`, `node.children` — **не** `node.space.kind`/`node.space.uuid`.

Публичные компоненты:
- `space_tree/1` — обёртка: `<ul>` корневых узлов + кнопка "+ Add root space" (событие `on_add_root`, по умолчанию `"open_add_root"` — то же имя, что обработчик в задаче 12).
- `space_tree_node/1` — рекурсивный узел. Атрибуты (по образцу FolderExplorer, упрощённо — **без** desktop-only 240px сайдбара и without drag/drop, без connector-line CSS-хореографии; см. память про мобильный overflow — держим один full-width столбец, не копируем фиксированную ширину сайдбара):
  - `node` (`%Space{}` с полем `:children`, содержащим вложенный список таких же узлов — см. выше), `expanded` (MapSet), `selected_uuid`, `renaming_uuid`, `renaming_text`, `depth`, `myself`.
  - `on_select` (default `"select_space"`), `on_toggle` (default `"toggle_space_node"`) — конфигурируемые имена событий, чтобы v0.5 PlacePicker мог переиспользовать тот же компонент в режиме "выбор" с другими событиями.
  - `show_actions` (boolean, default `true`) — когда `false` (picker-режим), скрывает pencil/add/reorder/delete кнопки, оставляет только клик-для-выбора + expand/collapse. Мирроринг `FolderExplorer`'s `show_rename`/`enable_drag` флагов.
- Строка узла: иконка через `Space.kind_icon(node.kind)`, имя `node.name`, бейдж `Space.kind_label(node.kind)`, статус (приглушённый текст/бейдж если `node.status == "inactive"`).
- Когда `show_actions`: pencil-иконка запускает инлайн-переименование (текстовое поле вместо имени, submit на Enter/blur) — 1:1 адаптация FolderExplorer'овского `renaming_folder`/`renaming_text`/`is_renaming` паттерна, события `start_rename_space` / `rename_space_input` / `rename_space` / `cancel_rename_space`; кнопки ▲/▼ (`move_space_up`/`move_space_down`, скрыты у единственного/крайнего в списке сиблинга); кнопка "+" добавить ребёнка (`open_add_child`, передаёт `parent_uuid`); кнопка trash (`delete_space`, с `data-confirm`).
- Реордер (▲/▼) и переименование — единственные события, которые сам компонент считает "immediate" в UI-смысле (шлёт событие сразу); создание/редактирование прочих полей/статус/файлы — через форму-панель в `LocationStructureLive` (см. задачу 12).

**Проверка:** `mix compile --warnings-as-errors`. Полноценно проверяется рендер-тестом в задаче 17 (`render_component/2` с фиктивным деревом — 2-3 уровня, проверить что children рендерятся рекурсивно и `show_actions=false` скрывает кнопки).

## Задача 9. `LocationStructureLive` — каркас (mount + read-only рендер дерева)

**Файл:** создать `/www/phoenix_kit_locations/lib/phoenix_kit_locations/web/location_structure_live.ex` — модуль `PhoenixKitLocations.Web.LocationStructureLive`.

```elixir
use Phoenix.LiveView
use Gettext, backend: PhoenixKitLocations.Gettext
```

`mount(%{"uuid" => uuid}, _session, socket)`:
- `Locations.get_location(uuid)` — `nil?` → flash `:error` + `push_navigate(to: Paths.index())` (мирроринг `LocationFormLive`'s `load_location(:edit, ...)` not-found ветки, `Errors.message(:location_not_found)`).
- Иначе: `assign(location: location, tree: Spaces.list_tree(location.uuid), expanded: MapSet.new(), selected_uuid: nil, page_title: ...)`.

`render/1`: `admin_page_header` (title = имя локации) + `<.location_tabs location={@location} active={:structure} />` + `<.space_tree tree={@tree} expanded={@expanded} selected_uuid={@selected_uuid} myself={nil} />` (нет `myself` — это LiveView, не LiveComponent, `phx-target` не нужен).

`handle_event("toggle_space_node", %{"uuid" => uuid}, socket)` — toggle в MapSet `expanded` (мирроринг `toggle_folder_expand` семантики).

`handle_event("select_space", %{"uuid" => uuid}, socket)` — `assign(:selected_uuid, uuid)` (детальная панель добавится в задаче 12/13, пока просто подсвечивает узел).

**Проверка:** `mix compile --warnings-as-errors`. Полный HTTP/LiveView smoke-тест — после задачи 10 (нужен зарегистрированный роут).

## Задача 10. Регистрация роута + admin_tab (boot-time)

**Файлы:**
- `/www/phoenix_kit_locations/lib/phoenix_kit_locations.ex` — добавить в `admin_tabs/0`, сразу после `:admin_locations_edit`:
  ```elixir
  %Tab{
    id: :admin_locations_structure,
    label: "Structure",
    icon: "hero-squares-2x2",
    path: "locations/:uuid/structure",
    priority: 677,
    level: :admin,
    permission: module_key(),
    parent: :admin_locations,
    visible: false,
    live_view: {PhoenixKitLocations.Web.LocationStructureLive, :edit}
  }
  ```
- `/www/phoenix_kit_locations/test/support/test_router.ex` — добавить `live("/:uuid/structure", LocationStructureLive, :edit)` рядом с `live("/:uuid/edit", LocationFormLive, :edit)`.

**Проверка:**
1. В `phoenix_kit_locations`: `mix test test/phoenix_kit_locations_test.exs` (или любой существующий тест, трогающий `admin_tabs/0`, если есть) + `mix compile --warnings-as-errors`.
2. В andi: пересобрать и **перезапустить** (`sudo /usr/bin/supervisorctl restart elixir` — boot-time discovery admin_tabs). Открыть `/admin/locations/:uuid/structure` для существующей локации — страница грузится, показывает вкладки Details/Structure и (пока) пустое/наполненное дерево без интерактива.

## Задача 11. Ссылка "Structure" в списке локаций

**Файл:** `/www/phoenix_kit_locations/lib/phoenix_kit_locations/web/locations_live.ex`

В row menu (рядом со строкой 309, между `Edit` и divider'ом перед `Delete`):
```heex
<.table_row_menu_link navigate={Paths.location_structure(location.uuid)} icon="hero-squares-2x2" label={gettext("Structure")} />
```

**Проверка:** `mix test test/phoenix_kit_locations/web/locations_live_test.exs`; в UI andi `/admin/locations` — пункт меню "Structure" у каждой строки ведёт на новую страницу.

## Задача 12. `LocationStructureLive` — CRUD-хендлеры дерева

**Файл:** `location_structure_live.ex` (продолжение задачи 9)

Добавить `handle_event` для событий из `space_tree_node/1`:

- `"open_add_root"` / `"open_add_child"` (`%{"parent_uuid" => uuid}` или без параметра для root) — открывает мини-форму создания (`assign(:adding_parent_uuid, uuid_or_:root, :new_space_form, to_form(Spaces.change_space(%Space{})))`). Имя `"open_add_root"` совпадает с событием, которое шлёт кнопка "+ Add root space" в `space_tree/1` (задача 8) — единое имя на обеих сторонах.
- `"validate_new_space"` / `"create_space"` (`%{"space" => params}`) — `Spaces.create_space(Map.merge(params, %{"location_uuid" => location.uuid, "parent_uuid" => parent_uuid}), actor_opts(socket))`; при успехе — перезагрузить `:tree` из `Spaces.list_tree/1`, `expanded` дополнить `parent_uuid` (авто-развернуть), закрыть мини-форму, `assign(:selected_uuid, new_space.uuid)`; при ошибке — оставить форму открытой с ошибками (обычный changeset-flow).
- `"start_rename_space"` / `"rename_space_input"` / `"rename_space"` / `"cancel_rename_space"` — инлайн-переименование: на submit `Spaces.update_space(space, %{"name" => new_name}, actor_opts(socket))`, перезагрузить `:tree`.
- `"move_space_up"` / `"move_space_down"` (`%{"uuid" => uuid}`) — найти сиблингов узла в `:tree` (тот же `parent_uuid`), поменять местами с соседом, вызвать `Spaces.reorder_siblings(location.uuid, parent_uuid, new_ordered_uuids, actor_opts(socket))`, перезагрузить `:tree`.
- `"delete_space"` (`%{"uuid" => uuid}`) — `data-confirm` на кнопке в `space_tree_node` уже предупреждает о каскаде ("Delete this space and everything inside it? This cannot be undone." — hard delete, без "отметить на удаление" смягчения, т.к. в immediate-commit модели удаление окончательное сразу); `Spaces.delete_space(space, actor_opts(socket))`, перезагрузить `:tree`, если удалённый узел был `:selected_uuid` — сбросить в `nil`.

Все четыре мутирующих вызова контекста (`create_space/2`, `update_space/3`, `reorder_siblings/4`, `delete_space/2`) обязательно передают `actor_opts(socket)` последним аргументом — иначе activity log (`spaces.ex` форвардит `:actor_uuid` из `opts`) тихо теряет запись об авторе изменения. `actor_opts/1` — та же приватная функция, что уже существует в `location_form_live.ex:2270` (задача 14 явно оставляет её нетронутой); `LocationStructureLive` — отдельный модуль, поэтому заводит свою копию `actor_opts/1` по тому же образцу (читает `socket.assigns` на предмет текущего админа).

Форма "add child/root" рендерится как всплывающий/инлайн блок под кнопкой "+" (не глубже, чем сама секция — `kind` через `<.select>` с опциями `Enum.map(Space.kinds(), &{Space.kind_label(&1), &1})`, `name` обязательный текст-инпут).

**Проверка:** `mix compile --warnings-as-errors`. Полноценно — тест-файл в задаче 17. Быстрый ручной прогон через Tidewave/UI: создать root-space, добавить ребёнка, переименовать, передвинуть, удалить — дерево на странице обновляется без reload.

## Задача 13. `LocationStructureLive` — детальная панель + Attachments + breadcrumb

**Файл:** `location_structure_live.ex` (продолжение)

**Мультиязычность (обязательна, решение №3 шапки — без исключений для v0.4 MVP):**

- Модуль добавляет `import PhoenixKitWeb.Components.MultilangForm` и `import PhoenixKitWeb.Components.LanguageSwitcher, only: [language_switcher: 1]` (тот же импорт, что в `location_form_live.ex:9-10`).
- В `mount/3` (продолжая цепочку из задачи 9) добавить `|> mount_multilang()` — та же функция, что использует `LocationFormLive` (`location_form_live.ex:74`), даёт `:multilang_enabled`, `:primary_language`, `:language_tabs`, `:current_lang` на уровне сокета. В отличие от старого floor/room-флоу, здесь **не** нужен shadow-socket трюк `with_draft_lang/2` — открыта максимум одна деталь-панель (один выбранный узел), поэтому Space-форма делит один и тот же `:current_lang`, что и (потенциально) остальная страница; отдельного per-draft языкового состояния не заводим.
- Добавить `handle_event("switch_language", %{"lang" => lang_code}, socket)` → `{:noreply, handle_switch_language(socket, lang_code)}` — 1:1 копия клаузы `location_form_live.ex:275-276` (обе функции публичные в core `MultilangForm`, доступны через импорт).
- В `handle_event("select_space", ...)` (задача 9) — дополнительно установить `:selected_space` (сам `%Space{}` — плоский обход `:tree` по `uuid`, дерево уже в памяти) и `:space_form`/`:space_changeset` через `Spaces.change_space(selected_space)`, чтобы деталь-панель ниже сразу имела форму для рендера.

**Деталь-панель:**

- При `selected_uuid != nil`: рендерится карточка ниже дерева — форма редактирования выбранного Space: `kind` select; `name`/`description` — **обязательно** через `<.translatable_field>` (без опции "обычные текстовые поля", 1:1 по образцу `render_floor_view`/`render_room_editor` в `location_form_live.ex:1759-1786`): `field_name="name"`/`"description"`, `form_prefix="space"`, `changeset={@space_changeset}`, `schema_field={:name}`/`{:description}`, `multilang_enabled={@multilang_enabled}`, `current_lang={@current_lang}`, `primary_language={@primary_language}`, `lang_data={@space_lang_data}`; над полями — `<.language_switcher languages={@language_tabs} current_language={@current_lang} on_click="switch_language" variant={:tabs} size={:sm} />`, показывается только когда `@multilang_enabled and match?([_, _ | _], @language_tabs)` (тот же guard, что у `<.multilang_tabs>` в `LocationFormLive`); `notes` textarea, `status` select (active/inactive — здесь и живёт "деактивация" из DEVELOPMENT_PLAN §4).
- `:space_lang_data` вычисляется как `get_lang_data(@space_changeset, @current_lang, @multilang_enabled)` — публичная функция `MultilangForm.get_lang_data/3` (уже импортирована выше), тот же вызов, что раньше прятался за приватной `space_lang_data/2`-обёрткой в `location_form_live.ex:2333-2336`; здесь обёртка не нужна, т.к. `@space_changeset` никогда не бывает `nil`, когда панель видна.
- `handle_event("validate_space_form", %{"space" => params}, socket)` (`phx-change` формы) — `params = merge_translatable_params(params, socket, ~w(name description), changeset: @space_changeset, preserve_fields: %{"status" => :status, "kind" => :kind})` (публичная `MultilangForm.merge_translatable_params/4`, тот же паттерн, что раньше жил в `validate_space`/`location_form_live.ex:517-521` для floor/room-драфтов — переносится сюда, в постоянный immediate-commit флоу, ДО того как задача 14 удалит старую копию), затем `Spaces.change_space(selected_space, params) |> Map.put(:action, :validate)` → `assign(:space_changeset, ...)`.
- `handle_event("update_space_form", %{"space" => params}, socket)` (submit) — та же `merge_translatable_params/4`, затем `params = Attachments.inject_attachment_data(params, socket, socket.assigns.selected_uuid)` (arity 3: `params, socket, scope` — тот же вызов, что `location_form_live.ex:52` делает для Location-scope, здесь со scope = выбранный Space, чтобы pending featured-image/upload-состояние атомарно попало в `data` вместе с обычными полями), затем `Spaces.update_space(selected_space, params, actor_opts(socket))`; при успехе — refresh `:tree` (имя/kind могли измениться) и обновить `:selected_space`/`:space_changeset` из свежих данных; при ошибке — `assign(:space_changeset, changeset)` с ошибками формы.
- Breadcrumb полного пути к выбранному Space — **не** через `Spaces.full_path/2` (тот появится в задаче 18 и требует лишний DB-запрос); вместо этого дешёвый локальный helper `ancestor_chain(tree, selected_uuid)`, который обходит уже загруженное в памяти `:tree` (список `parent_uuid`-цепочки от корня до узла, O(глубина)) — рендерится как `Location.name / Floor 1 / Zone A / Shelf 3`.
- Files-карточка для выбранного Space: `import PhoenixKitLocations.Web.Components.FilesCard, only: [files_card_body: 1]`, `<.files_card_body scope={@selected_uuid} state={Attachments.state(%{assigns: assigns}, @selected_uuid)} uploads={@uploads} .../>`. Хук `PkLocationsUploadScope`, который использует дропзона внутри `files_card_body/1`, приходит бесплатно как ColocatedHook, скомпилированный вместе с `FilesCard` в задаче 5 — ничего копировать здесь не нужно.
- В `mount/3` добавить в конец assign-конвейера `|> Attachments.init() |> Attachments.allow_attachment_upload()` (`Attachments.init/1` — принимает `socket` через пайплайн, точно как в `LocationFormLive:75`; арность 1, не 0).
- В `handle_event("select_space", ...)` — дополнительно вызвать `Attachments.mount(socket, scope: uuid, resource: selected_space)` (ленивая инициализация scope только для выбранного узла, не для всего дерева сразу — деревья могут быть глубокими). **Важно:** т.к. в immediate-commit модели Space уже существует в БД с реальным uuid к моменту выбора, `Attachments.maybe_rename_pending_folder_for/2` здесь **не нужен** (в отличие от старого draft-флоу) — папка сразу получает детерминированное имя `location-space-<uuid>` при первом upload/featured-image.
- Добавить те же 5 attachment-хендлеров, что в `LocationFormLive` (делегируют в `Attachments`): `open_featured_image_picker`, `close_media_selector`, `cancel_upload`, `remove_file`, `clear_featured_image`, `set_active_upload_scope`; и `handle_info({:media_selected, ...})` / `{:media_selector_closed}` — копия существующих клауз из `location_form_live.ex:391-409` и `:1244-1248`.
- Добавить в `render/1` тот же `<.live_component module={PhoenixKitWeb.Live.Components.MediaSelectorModal} .../>`. Отдельный JS hook в `render/1` добавлять не нужно (см. выше — приходит вместе с `FilesCard`).

**Проверка:** в UI andi (после restart) — выбрать узел дерева, переключить язык детали-панели и убедиться, что `name`/`description` редактируются отдельно на каждом языке (паритет с Location), отредактировать поля, сохранить; загрузить файл/установить featured image для конкретного Space; убедиться, что файл Space'а не путается с файлами Location или других Spaces (разные scope-папки `location-space-<uuid>`).

## Задача 14. Демонтаж staged floor/room-черновика в `LocationFormLive`

**Файл:** `/www/phoenix_kit_locations/lib/phoenix_kit_locations/web/location_form_live.ex`

Удалить (диапазоны строк — по состоянию файла на момент исследования 2026-07-10, до задачи 5/этого рефакторинга; при удалении ориентироваться на именованные секции/комментарии, не только на номера):

- Module attrs: `@space_translatable_fields`, `@space_preserve_fields`.
- `alias PhoenixKitLocations.Spaces`, часть `alias PhoenixKitLocations.Schemas.{Location, Space}` → оставить только `Location`.
- `mount_space_scopes/1` и его вызов в `mount/3`; `assign_spaces_state/3` (обе клаузы); `persisted_draft/1`, `new_draft/3`, `draft_current_lang/2`, `floor_drafts/1`, `room_drafts_of/2`, `parent_id_of/1`, `find_draft/2`, `update_draft/3`, `first_visible_floor_id/1` — весь блок "Spaces state — staged drafts" (~строки 90-229).
- `handle_event` клаузы: `add_floor`, `add_room`, `select_floor` (обе), `edit_room`, `close_room_editor`, `switch_space_language`, `validate_space`, `delete_floor`, `delete_room` (~строки 419-594).
- `save`-хендлер (~347-385): убрать `validate_drafts_for_save`/`invalid_drafts`-ветвление, оставить прямой путь validate → `merge_translatable_params` → `Attachments.inject_attachment_data` → `save_location`.
- `validate_drafts_for_save/1`, `validate_draft_for_save/1`, `draft_has_errors?/1`, `active_focus_for_invalid/1`, `invalid_drafts_flash/2`, `describe_draft_problem/2`, `invalid_field_keys/1`, `humanize_field/1`, `identify_draft/2`, `typed_name/1`, `visible_drafts_of_kind/2`, `join_sentence/1`, `do_select_floor/2`, `with_draft_lang/2`, `forget_dropped_scopes/2`, `cascade_delete_floor/2`, `classify_for_floor_delete/3` (~строки 610-837).
- `save_location/3` (обе клаузы) — упростить: убрать вызовы `persist_space_drafts/3`, оставить `Locations.create_location`/`update_location` + `Attachments.maybe_rename_pending_folder_for` (только для Location scope) + `sync_types_and_redirect` напрямую (как в `location_type_form_live.ex`).
- `finish_save/5` — убрать полностью (обе клаузы, `reseat_active_tabs/2`, `remount_space_scopes/2`); `save_location` теперь сразу вызывает `sync_types_and_redirect/3` на успехе.
- Весь блок `persist_space_drafts/3` … `format_draft_error_reason/1` (~строки 925-1241): `persist_space_drafts`, `orphan_blank_floor?/2`, `blank_changeset_name?/1`, `persist_floor_drafts/5`, `step_floor_draft/5`, `apply_floor_persist_result/5`, `persist_floor/4` (3 клаузы), `persist_room_drafts/6`, `step_room_draft/7`, `persist_room/5` (3 клаузы), `draft_id?/1`, `scope_has_attachment_changes?/3`, `resolve_parent_uuid/2`, `space_to_attrs/1`, `blank_required_field?/1`, `draft_error_summary/1`, `format_draft_error_reason/1` (2 клаузы) — удалить целиком.
- `render_spaces_section/1`, `render_floor_view/1`, `render_room_editor/1` (~строки 1637-2013) — удалить целиком; в `render/1` удалить вызов `{render_spaces_section(assigns)}` и поясняющий комментарий над ним (~1515-1522).
- `draft_language_strip/1`, `floor_nav_tab_maps/1`, `floor_tab_label/1`, `room_row_label/1`, `space_lang_data/2` — удалить СТРОГО по этим именам, **не** по диапазону строк: физически этот участок файла (~2238-2337 на момент исследования) ПЕРЕСЕКАЕТСЯ с сохраняемыми функциями `section_heading/1` (~2261), `actor_opts/1` (~2270), `feature_label/1` (~2280) — их не задевать при удалении.
- Ставшие неиспользуемыми после остального удаления в этой задаче `import PhoenixKitWeb.Components.Core.NavTabs, only: [nav_tabs: 1]` — `<.nav_tabs>` использовался только внутри удаляемого `render_floor_view/1` (floor-табы), больше нигде в файле не вызывается; убрать импорт, иначе `mix compile --warnings-as-errors` (шаг "Проверка" ниже) упадёт на unused import. (`alias PhoenixKit.Modules.Storage.URLSigner` за аналогичный неиспользуемый импорт уже отвечает задача 5 — он становится мёртвым сразу при переносе `files_card_body/1`, раньше, чем эта задача.)

**Дополнительное упрощение (следствие удаления секции Spaces) — слияние `location-form-top`/`location-form-bottom`:** ПЕРЕД тем как сливать формы и удалять `merge_running_changes/2`, проверить фактическое содержимое `location-form-bottom` (`location_form_live.ex:1524-1624` на момент исследования) — оно **не** является "исключительно Spaces-разметкой": там живут Files-карточка Location-scope, Internal notes, Status select, переключатели Location Types и кнопка submit. Слияние всё равно безопасно, потому что причина раздельных `<.form>` НЕ в том, что нижняя половина Spaces-специфична, а в том, что нетронутый `render_spaces_section(assigns)` вызывается МЕЖДУ двумя `<.form>` как обычный компонент (не `<form>`-элемент) — вложенные HTML `<form>` невозможны, поэтому верхнюю форму приходилось закрывать перед этим вызовом и открывать новую после; обе половины уже используют один и тот же `@form`, `phx-change="validate"`, `phx-submit="save"`. После удаления `render_spaces_section(assigns)` (см. выше) единственная причина разрыва исчезает — объединить оба блока обратно в один `<.form id="location-form">`, обёртывающий Public Info + Address + Contact + Features + Files + Internal, и убрать `merge_running_changes/2` из `handle_event("validate", ...)`/`handle_event("save", ...)` — обычный `to_form(changeset)` цикл достаточен для одной формы. Если на момент реализации фактическое содержимое `location-form-bottom` отличается от описанного здесь (появились Spaces-специфичные поля) — перепроверить рассуждение заново, а не сливать вслепую.

**Оставить без изменений:** `@translatable_fields`, `@preserve_fields`, `@feature_keys`, `mount/3` (без spaces-веток), `handle_event` для `switch_language`/`validate`/`toggle_type`/`toggle_feature`/`check_address` (упрощённые), attachment-хендлеры Location-scope, `handle_info`, `sync_types_and_redirect/3`, `render/1` (без Spaces-секции, с одной формой), `section_heading/1`, `actor_opts/1`, `feature_label/1` — остаются как есть.

**Проверка:** `mix compile --warnings-as-errors` (никаких unused-alias/unused-function warning); `mix format`; `mix credo --strict`.

## Задача 15. Актуализация `location_form_live_test.exs`

**Файл:** `/www/phoenix_kit_locations/test/phoenix_kit_locations/web/location_form_live_test.exs`

Найти и удалить/переписать все тесты, ссылающиеся на `add_floor`/`add_room`/`space_drafts`/floor-room UI (grep по `"floor"`, `"room"`, `"Add floor"`, `"Spaces"` в файле). Тесты на сохранение самой локации (name/address/features/types/файлы) должны остаться и продолжать проходить.

**Проверка:** `mix test test/phoenix_kit_locations/web/location_form_live_test.exs`.

## Задача 16. `test/spaces_test.exs` — контекстные тесты (закрывает документированный пробел)

**Файл:** создать `/www/phoenix_kit_locations/test/spaces_test.exs` — докстрока `space_test.exs` уже обещает существование этого файла ("cross-row invariant... tested separately under `test/spaces_test.exs`").

`use PhoenixKitLocations.DataCase, async: true`, покрыть:
- `create_space/2` с новыми kinds (`zone`, `section`, `aisle`, `shelf`), `{:error, :parent_in_other_location}`, `{:error, :cycle}` через `update_space/3` (переродительствование).
- `list_tree/1` — 3-уровневое дерево (floor → zone → shelf), проверка вложенности `:children`.
- `reorder_siblings/4` — root-уровень (`parent_uuid: nil`, регрессия на `is_nil`-баг, уже описанный в комментарии `sibling_position_query/3`) и non-root.
- `delete_space/2` — CASCADE на детей.

**Проверка:** `mix test test/spaces_test.exs`.

## Задача 17. Тесты `LocationStructureLive` и `SpaceTree`

**Файлы:**
- Создать `/www/phoenix_kit_locations/test/phoenix_kit_locations/web/location_structure_live_test.exs` (по образцу `location_form_live_test.exs` / `LiveCase`): mount по `/en/admin/locations/:uuid/structure` рендерит дерево; создание root/child space через форму; переименование; move up/down меняет `position` в БД; delete каскадно убирает детей; выбор узла показывает detail-панель с его файлами.
- Опционально: `test/phoenix_kit_locations/web/components/space_tree_test.exs` — `render_component`-тест на голом дереве (2-3 уровня), проверка `show_actions={false}` скрывает CRUD-кнопки.

**Проверка:** `mix test`.

---

# v0.5 — API для других модулей

## Задача 18. `Spaces.full_path/2`

**Файл:** `/www/phoenix_kit_locations/lib/phoenix_kit_locations/spaces.ex`

Добавить `alias PhoenixKitLocations.Schemas.Location`. Порт паттерна `PhoenixKitCatalogue.Catalogue.Tree.ancestor_uuids/1` + `walk_up/3`, адаптированный под `phoenix_kit_location_spaces` (self-join по `parent_uuid`, `UNION` не `UNION ALL` — cycle-safe):

```elixir
@spec full_path(uuid, opts) :: String.t() | nil
def full_path(space_uuid, opts \\ []) when is_binary(space_uuid) do
  locale = Keyword.get(opts, :locale)

  with %Space{} = space <- get_space(space_uuid),
       %Location{} = location <- repo().get(Location, space.location_uuid) do
    ancestors = ancestors_in_order(space)  # root → direct parent, [] если space — корень

    ([location] ++ ancestors ++ [space])
    |> Enum.map(&translated_name(&1, locale))
    |> Enum.join(" / ")
  else
    nil -> nil
  end
end
```

Приватные хелперы:
- `ancestors_in_order/1` — CTE от `space.parent_uuid` вверх (мирроринг `Tree.ancestor_uuids/1` + `Tree.ancestors_in_order/1`, `walk_up/3`), возвращает `[Space.t()]` root → прямой родитель.
- `translated_name/2` — **не** писать свой `get_in(data, [locale, "name"]) || name`-ридер (некорректен: primary-язык хранится в колонке `name`, а не под ключом `data[locale]`, поэтому такой `get_in` вернёт `nil` для primary языка и не смёрджит fallback). Вместо этого переиспользовать существующий публичный core-хелпер чтения мультиязычных данных — `PhoenixKit.Utils.Multilang.get_language_data/2` (тот же, на который делегирует `Catalogue.Translations.get_translation/2`, а через него — `ItemPicker.translated_name/2`, приватная в catalogue, но реализующая ровно этот паттерн fallback-цепочки — копировать паттерн, не вызывать catalogue-функцию напрямую):
  ```elixir
  alias PhoenixKit.Utils.Multilang

  defp translated_name(%{name: name}, nil), do: name

  defp translated_name(%{data: data, name: name}, locale) do
    translation = Multilang.get_language_data(data, locale)
    Map.get(translation, "name") || name
  end
  ```
  `get_language_data/2` уже мёрджит primary-данные с оверрайдами нужного языка (см. `PhoenixKit.Utils.Multilang` в core) — ровно то поведение, которое нужно для `name`/`description` у `Location`/`Space`.

**Проверка:** `test/spaces_test.exs` — добавить кейсы: `full_path/2` для 3-уровневого дерева возвращает `"Location / Floor / Zone / Shelf"`; для корневого space — `"Location / Floor"`; несуществующий uuid → `nil`; с `locale: "ru"` при заполненном `data["ru"]["name"]` — русские сегменты.

## Задача 19. `PlacePicker` LiveComponent

**Файл:** создать `/www/phoenix_kit_locations/lib/phoenix_kit_locations/web/components/place_picker.ex` — модуль `PhoenixKitLocations.Web.Components.PlacePicker`, `use Phoenix.LiveComponent`.

Мирроринг `ItemPicker` (search-combobox) для Location-половины + переиспользование `SpaceTree.space_tree_node/1` в read-only режиме (`show_actions={false}`) для Space-половины:

- Атрибуты: `id` (required), `location_type_uuid` (optional — фильтр; резолвится потребителем заранее через уже существующий `Locations.get_location_type_by_name/1`, PlacePicker сам имени типа не резолвит — держим API маленьким), `selected_location_uuid`, `selected_space_uuid`, `locale`.
- `mount/1`: `assign(query: "", matches: [], open: false, selected_location: nil, tree: [], expanded: MapSet.new())`.
- `handle_event("location_query_change", %{"value" => q}, socket)` — `Locations.list_locations(status: "active", type_uuid: socket.assigns.location_type_uuid)` (существующая функция, без изменений), отфильтровать по подстроке `q` в Elixir (локаций типично немного — не нужен отдельный `search_locations/2` в контексте, в отличие от `Catalogue.search_items/2`).
- `handle_event("select_location", %{"uuid" => uuid}, socket)` — `Locations.get_location(uuid)`, `Spaces.list_tree(uuid)`, сброс `selected_space_uuid`.
- `handle_event("toggle_space_node", %{"uuid" => uuid}, socket)` — toggle в MapSet `expanded` (`SpaceTree.space_tree_node/1`, задача 8, шлёт это событие по умолчанию наравне с `select_space`/`on_toggle`; без этого обработчика дерево внутри пикера не разворачивается — узлы кликабельны для выбора, но стрелка expand/collapse будет no-op).
- `handle_event("select_space", %{"uuid" => uuid}, socket)` (переиспользует то же имя события, что `SpaceTree` шлёт по умолчанию, но таргетировано на `@myself` — LiveComponent) — `send(self(), {:place_picker_select, id, %{location_uuid: ..., space_uuid: uuid}})`.
- Кнопка/пункт "Use this location (no specific space)" — тот же message с `space_uuid: nil`.
- `handle_event("clear_location", ...)` — сброс к состоянию поиска.
- Рендер: `<input role="combobox">` (копия ItemPicker layout) → после выбора локации показывает breadcrumb (имя локации, "Change") + `<.space_tree tree={@tree} expanded={@expanded} selected_uuid={@selected_space_uuid} myself={@myself} show_actions={false} />`.

Добавить в moduledoc короткий usage-пример связки с уже существующим API (закрывает §5 DEVELOPMENT_PLAN без нового кода в `Locations`):
```
type = Locations.get_location_type_by_name("Warehouse")
<.live_component module={PlacePicker} id="picker-1" location_type_uuid={type && type.uuid} />
```

**Проверка:** `mix compile --warnings-as-errors`; полноценный прогон — задача 20.

## Задача 20. Тест-харнес и тесты `PlacePicker`

У модуля пока нет реального потребителя (warehouse/manufacturing — on hold, см. память проекта), поэтому для полноценного event-теста (по образцу `item_picker_events_test.exs`, который гоняет `ItemPicker` через реальный host LiveView, а не изолированно) нужен тестовый хост.

**Файлы:**
- Создать `/www/phoenix_kit_locations/test/support/place_picker_harness_live.ex` — минимальный `Phoenix.LiveView`, монтирующий один `<.live_component module={PlacePicker} id="harness-picker" />` и `handle_info({:place_picker_select, _id, place}, socket)`, сохраняющий `place` в assigns для проверки через `render/1`.
- Добавить роут в `test/support/test_router.ex` **внутри уже существующего** `scope "/en/admin/locations", PhoenixKitLocations.Web do ... live_session :locations_test, ... do` (не отдельным top-level scope — единственный `live_session`/root-layout в тестовом роутере уже настроен там; служебный путь для теста, не показывается в реальном UI): `live("/__test__/place-picker", PlacePickerHarnessLive, :index)`, итоговый URL — `/en/admin/locations/__test__/place-picker`.
- Создать `test/phoenix_kit_locations/web/components/place_picker_test.exs`: `live(conn, "/en/admin/locations/__test__/place-picker")` для mount; поиск локации по подстроке → выбор → сообщение `{:place_picker_select, ...}` долетает до host; фильтр по `location_type_uuid` исключает локации другого типа; выбор Space в дереве (включая предварительный `toggle_space_node` для разворачивания) прокидывает `space_uuid`; "Use this location" даёт `space_uuid: nil`.

**Проверка:** `mix test test/phoenix_kit_locations/web/components/place_picker_test.exs`; `mix test` (весь набор) зелёный; `mix format && mix quality` (алиас: format + credo --strict + dialyzer) без ошибок; финальный `mix precommit`-эквивалент — `mix compile --force --warnings-as-errors && mix quality.ci`.

---

# Финальная проверка всего плана

1. `cd /www/phoenix_kit_locations && mix format && mix quality` (format + credo --strict + dialyzer) — чисто.
2. `mix test` — весь набор зелёный (включая новые `spaces_test.exs`, `location_structure_live_test.exs`, `place_picker_test.exs`).
3. В `/www/app`: пересобрать зависимость и `sudo /usr/bin/supervisorctl restart elixir`.
4. UI-прогон в andi: `/admin/locations` → строка локации → "Structure" → создать 2-3 уровня (Floor → Zone → Shelf), переименовать, переместить, прикрепить файл к Zone, деактивировать Shelf, удалить Zone (убедиться, что Shelf исчез каскадно) → вернуться на "Details", сохранить локацию (без Spaces-секции, форма работает как обычная CRUD-форма) → `/admin/locations/types/new` создать Workshop/Office, если ещё не создан (задача 4).
5. Через Tidewave: `PhoenixKitLocations.Spaces.full_path(some_shelf_uuid)` возвращает читаемую строку пути.
