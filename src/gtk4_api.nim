# ==============================================================================
#  gtk4_api.nim  — Nim-обёртка над GTK4/GObject/GLib C API  (v1)
#
#  Стиль биндингов — как в src/ffmpeg_api.nim (перенесено из PMI):
#  opaque-структуры импортируются как пустые object'ы, доступ — только
#  через C-функции; никаких полей наружу не тащим, кроме тех немногих,
#  что реально нужно читать напрямую.
#
#  ВАЖНО про статическую сборку (см. README и config.nims):
#  В отличие от FFmpeg/x264 (см. PMI), GTK4 НЕ собирается в единый
#  статический .a практически пригодным способом: у него модульная
#  система загрузчиков (gdk-pixbuf, immodules, icon-тема, GSettings
#  schemas и т.п.), которая ищет .so/.dll модули и данные по известным
#  путям во время выполнения. Поэтому GTK4 линкуется ДИНАМИЧЕСКИ:
#    • Fedora  — системные libgtk-4.so.* уже стоят у пользователя
#      (пакет gtk4), либо ставятся через dnf install gtk4-devel.
#    • Windows — рантайм GTK4 (DLL, схемы, иконки) собирается через
#      MSYS2/mingw64 (mingw-w64-x86_64-gtk4) и копируется рядом с
#      Monolit.exe скриптом package-windows (см. config.nims); это
#      обычная практика для GTK-приложений на Windows (ср. GIMP,
#      Inkscape) — "статический GTK" там никто не поставляет.
#  Кодек/фильтр-часть (FFmpeg+x264+vidstab) при этом остаётся полностью
#  статической, как в PMI — идея статической сборки применена именно
#  к тяжёлой медиа-части, а не к системному GUI-тулкиту.
# ==============================================================================

{.passC: gorge("pkg-config --cflags gtk4").}
when not defined(windows):
  {.passL: gorge("pkg-config --libs gtk4").}
else:
  # На кросс-сборке под mingw pkg-config должен быть настроен на mingw64
  # sysroot (PKG_CONFIG_PATH/PKG_CONFIG_LIBDIR из config.nims) — тогда
  # gorge() ниже вернёт те же -lgtk-4 -lgdk-4 ... но собранные mingw-гцц.
  {.passL: gorge("pkg-config --libs gtk4").}

# ------------------------------------------------------------------------------
# Базовые типы GLib/GObject — opaque-указатели, как AVFormatContext в PMI
# ------------------------------------------------------------------------------
type
  GObject*        {.importc: "GObject",        header: "<glib-object.h>".} = object
  GApplication*   {.importc: "GApplication",   header: "<gio/gio.h>".}    = object
  GtkApplication* {.importc: "GtkApplication", header: "<gtk/gtk.h>".}    = object
  GtkWidget*      {.importc: "GtkWidget",      header: "<gtk/gtk.h>".}    = object
  GtkWindow*      {.importc: "GtkWindow",      header: "<gtk/gtk.h>".}    = object
  GtkBox*         {.importc: "GtkBox",         header: "<gtk/gtk.h>".}    = object
  GtkNotebook*    {.importc: "GtkNotebook",    header: "<gtk/gtk.h>".}    = object
  GtkButton*      {.importc: "GtkButton",      header: "<gtk/gtk.h>".}    = object
  GtkLabel*       {.importc: "GtkLabel",       header: "<gtk/gtk.h>".}    = object
  GtkScale*       {.importc: "GtkScale",       header: "<gtk/gtk.h>".}    = object
  GtkRange*       {.importc: "GtkRange",       header: "<gtk/gtk.h>".}    = object
  GtkSpinButton*  {.importc: "GtkSpinButton",  header: "<gtk/gtk.h>".}    = object
  GtkCheckButton* {.importc: "GtkCheckButton", header: "<gtk/gtk.h>".}    = object
  GtkDropDown*    {.importc: "GtkDropDown",    header: "<gtk/gtk.h>".}    = object
  GtkStringList*  {.importc: "GtkStringList",  header: "<gtk/gtk.h>".}    = object
  GtkListItemFactory* {.importc: "GtkListItemFactory", header: "<gtk/gtk.h>".} = object
  GtkListItem*    {.importc: "GtkListItem",    header: "<gtk/gtk.h>".}    = object
  GtkProgressBar* {.importc: "GtkProgressBar", header: "<gtk/gtk.h>".}    = object
  GtkFileChooserNative* {.importc: "GtkFileChooserNative", header: "<gtk/gtk.h>".} = object
  GtkFileFilter*  {.importc: "GtkFileFilter",  header: "<gtk/gtk.h>".}    = object
  GFile*          {.importc: "GFile",          header: "<gio/gio.h>".}    = object
  GError*         {.importc: "GError", header: "<glib.h>".} = object
    domain*:  cuint
    code*:    cint
    message*: cstring

  GtkOrientation* = distinct cint
  GtkAlign*       = distinct cint
  GConnectFlags*  = distinct cint
  GtkFileChooserAction* = distinct cint
  GtkResponseType*      = distinct cint

# distinct-типы в Nim НЕ наследуют операторы своего базового типа
# автоматически — это сделано намеренно, иначе distinct не давал бы
# никакой защиты от типов. Чтобы GtkResponseType(response) == GTK_RESPONSE_ACCEPT
# вообще компилировался, оператор `==` нужно явно "занять" у cint через
# {.borrow.} — без этой строки у GtkResponseType попросту нет оператора
# `==`, и компилятор Error: type mismatch, перебирая вообще все известные
# ему перегрузки `==` (для AVCodecID, bool, string и т.д.), не находит ни
# одной подходящей.
proc `==`*(a, b: GtkResponseType): bool {.borrow.}

const
  GTK_ORIENTATION_HORIZONTAL* = GtkOrientation(0)
  GTK_ORIENTATION_VERTICAL*   = GtkOrientation(1)

  GTK_ALIGN_START*  = GtkAlign(1)
  GTK_ALIGN_FILL*   = GtkAlign(0)

  GTK_FILE_CHOOSER_ACTION_OPEN* = GtkFileChooserAction(0)
  GTK_FILE_CHOOSER_ACTION_SAVE* = GtkFileChooserAction(1)

  GTK_RESPONSE_ACCEPT* = GtkResponseType(-3)
  GTK_RESPONSE_CANCEL* = GtkResponseType(-6)

  G_APPLICATION_DEFAULT_FLAGS* = 0.cint

# ------------------------------------------------------------------------------
# GApplication / GtkApplication — точка входа приложения
# ------------------------------------------------------------------------------
proc gtk_application_new*(application_id: cstring; flags: cint): ptr GtkApplication
  {.importc: "gtk_application_new", header: "<gtk/gtk.h>".}
proc g_application_run*(app: ptr GApplication; argc: cint; argv: ptr cstring): cint
  {.importc: "g_application_run", header: "<gio/gio.h>".}
proc g_object_unref*(obj: pointer)
  {.importc: "g_object_unref", header: "<glib-object.h>".}

# g_signal_connect() в C — макрос над g_signal_connect_data(); импортируем
# саму функцию и оборачиваем шаблоном, чтобы не тащить varargs-магию сюда.
proc g_signal_connect_data*(instance: pointer; detailed_signal: cstring;
                             c_handler: pointer; data: pointer;
                             destroy_data: pointer; flags: cint): culong
  {.importc: "g_signal_connect_data", header: "<glib-object.h>".}

template connect*(instance: pointer; signal: string; handler: untyped; data: pointer = nil) =
  ## `handler` принимается как `untyped`, потому что вызывающий код передаёт
  ## типизированный `proc {.cdecl.}` (например, onActivate), а не сырой
  ## pointer — cast[pointer] здесь единственное место, где нужен явный
  ## переход от Nim-типа функции к C GCallback.
  discard g_signal_connect_data(instance, signal.cstring,
                                 cast[pointer](handler), data, nil, 0.cint)

# ------------------------------------------------------------------------------
# Окно / контейнеры
# ------------------------------------------------------------------------------
proc gtk_application_window_new*(app: ptr GtkApplication): ptr GtkWidget
  {.importc: "gtk_application_window_new", header: "<gtk/gtk.h>".}
proc gtk_window_set_title*(window: ptr GtkWindow; title: cstring)
  {.importc: "gtk_window_set_title", header: "<gtk/gtk.h>".}
proc gtk_window_set_default_size*(window: ptr GtkWindow; w, h: cint)
  {.importc: "gtk_window_set_default_size", header: "<gtk/gtk.h>".}
proc gtk_window_set_child*(window: ptr GtkWindow; child: ptr GtkWidget)
  {.importc: "gtk_window_set_child", header: "<gtk/gtk.h>".}
proc gtk_window_present*(window: ptr GtkWindow)
  {.importc: "gtk_window_present", header: "<gtk/gtk.h>".}
proc gtk_window_destroy*(window: ptr GtkWindow)
  {.importc: "gtk_window_destroy", header: "<gtk/gtk.h>".}

proc gtk_box_new*(orientation: GtkOrientation; spacing: cint): ptr GtkWidget
  {.importc: "gtk_box_new", header: "<gtk/gtk.h>".}
proc gtk_box_append*(box: ptr GtkBox; child: ptr GtkWidget)
  {.importc: "gtk_box_append", header: "<gtk/gtk.h>".}
proc gtk_box_set_spacing*(box: ptr GtkBox; spacing: cint)
  {.importc: "gtk_box_set_spacing", header: "<gtk/gtk.h>".}

proc gtk_notebook_new*(): ptr GtkWidget
  {.importc: "gtk_notebook_new", header: "<gtk/gtk.h>".}
proc gtk_notebook_append_page*(notebook: ptr GtkNotebook; child: ptr GtkWidget;
                                tabLabel: ptr GtkWidget): cint
  {.importc: "gtk_notebook_append_page", header: "<gtk/gtk.h>".}

proc gtk_widget_set_margin_top*(w: ptr GtkWidget; m: cint)
  {.importc: "gtk_widget_set_margin_top", header: "<gtk/gtk.h>".}
proc gtk_widget_set_margin_bottom*(w: ptr GtkWidget; m: cint)
  {.importc: "gtk_widget_set_margin_bottom", header: "<gtk/gtk.h>".}
proc gtk_widget_set_margin_start*(w: ptr GtkWidget; m: cint)
  {.importc: "gtk_widget_set_margin_start", header: "<gtk/gtk.h>".}
proc gtk_widget_set_margin_end*(w: ptr GtkWidget; m: cint)
  {.importc: "gtk_widget_set_margin_end", header: "<gtk/gtk.h>".}
proc gtk_widget_set_sensitive*(w: ptr GtkWidget; sensitive: cint)
  {.importc: "gtk_widget_set_sensitive", header: "<gtk/gtk.h>".}
proc gtk_widget_set_hexpand*(w: ptr GtkWidget; expand: cint)
  {.importc: "gtk_widget_set_hexpand", header: "<gtk/gtk.h>".}

# ------------------------------------------------------------------------------
# Простые виджеты
# ------------------------------------------------------------------------------
proc gtk_label_new*(text: cstring): ptr GtkWidget
  {.importc: "gtk_label_new", header: "<gtk/gtk.h>".}
proc gtk_label_set_text*(lbl: ptr GtkLabel; text: cstring)
  {.importc: "gtk_label_set_text", header: "<gtk/gtk.h>".}
proc gtk_label_set_markup*(lbl: ptr GtkLabel; markup: cstring)
  {.importc: "gtk_label_set_markup", header: "<gtk/gtk.h>".}
  ## Текст с Pango-разметкой: "<b>жирный</b>", "<i>курсив</i>" и т.п. —
  ## используется там, где нужно жирное/курсивное начертание, потому что
  ## gtk_label_new()/gtk_check_button_new_with_label() размечать текст
  ## сами по себе не умеют.
proc gtk_label_set_xalign*(lbl: ptr GtkLabel; xalign: cfloat)
  {.importc: "gtk_label_set_xalign", header: "<gtk/gtk.h>".}

proc gtk_button_new_with_label*(label: cstring): ptr GtkWidget
  {.importc: "gtk_button_new_with_label", header: "<gtk/gtk.h>".}
proc gtk_button_set_label*(btn: ptr GtkButton; label: cstring)
  {.importc: "gtk_button_set_label", header: "<gtk/gtk.h>".}
proc gtk_button_new*(): ptr GtkWidget
  {.importc: "gtk_button_new", header: "<gtk/gtk.h>".}
proc gtk_button_set_child*(btn: ptr GtkButton; child: ptr GtkWidget)
  {.importc: "gtk_button_set_child", header: "<gtk/gtk.h>".}
  ## Произвольный виджет вместо текста кнопки — нужен, когда подпись
  ## должна нести Pango-разметку (например, полужирную), которую
  ## gtk_button_new_with_label напрямую не поддерживает: кнопка создаётся
  ## пустой через gtk_button_new(), а сюда передаётся GtkLabel с markup.

proc gtk_check_button_new_with_label*(label: cstring): ptr GtkWidget
  {.importc: "gtk_check_button_new_with_label", header: "<gtk/gtk.h>".}
proc gtk_check_button_get_active*(btn: ptr GtkCheckButton): cint
  {.importc: "gtk_check_button_get_active", header: "<gtk/gtk.h>".}
proc gtk_check_button_set_active*(btn: ptr GtkCheckButton; active: cint)
  {.importc: "gtk_check_button_set_active", header: "<gtk/gtk.h>".}
proc gtk_check_button_new*(): ptr GtkWidget
  {.importc: "gtk_check_button_new", header: "<gtk/gtk.h>".}
proc gtk_check_button_set_child*(btn: ptr GtkCheckButton; child: ptr GtkWidget)
  {.importc: "gtk_check_button_set_child", header: "<gtk/gtk.h>".}
  ## Тот же приём, что и gtk_button_set_child выше, только для чекбокса —
  ## нужен, чтобы подпись рядом с галочкой можно было сделать полужирной.

# ------------------------------------------------------------------------------
# Числовые контролы: Scale (ползунок) и SpinButton
# ------------------------------------------------------------------------------
proc gtk_scale_new_with_range*(orientation: GtkOrientation;
                                min, max, step: cdouble): ptr GtkWidget
  {.importc: "gtk_scale_new_with_range", header: "<gtk/gtk.h>".}
proc gtk_scale_set_digits*(scale: ptr GtkScale; digits: cint)
  {.importc: "gtk_scale_set_digits", header: "<gtk/gtk.h>".}

# GtkPositionType нужен только для gtk_scale_set_value_pos ниже — заводить
# ради одной константы отдельный распределённый по всему файлу enum не
# стали, объявляем прямо здесь, рядом с единственным местом использования.
type
  GtkPositionType* = distinct cint
const
  GTK_POS_RIGHT* = GtkPositionType(1)

# Встроенный в GTK способ подписать числовое значение прямо на ползунке —
# избавляет от необходимости городить отдельный GtkLabel и вручную
# синхронизировать его с сигналом "value-changed" при каждом движении
# ползунка. draw_value включает подпись, value_pos задаёт её положение
# (справа от ползунка — не перекрывает сам слайдер и не требует
# дополнительного места по высоте, в отличие от GTK_POS_TOP/BOTTOM).
proc gtk_scale_set_draw_value*(scale: ptr GtkScale; drawValue: cint)
  {.importc: "gtk_scale_set_draw_value", header: "<gtk/gtk.h>".}
proc gtk_scale_set_value_pos*(scale: ptr GtkScale; pos: GtkPositionType)
  {.importc: "gtk_scale_set_value_pos", header: "<gtk/gtk.h>".}

proc gtk_range_set_value*(range: ptr GtkRange; value: cdouble)
  {.importc: "gtk_range_set_value", header: "<gtk/gtk.h>".}
proc gtk_range_get_value*(range: ptr GtkRange): cdouble
  {.importc: "gtk_range_get_value", header: "<gtk/gtk.h>".}

proc gtk_spin_button_new_with_range*(min, max, step: cdouble): ptr GtkWidget
  {.importc: "gtk_spin_button_new_with_range", header: "<gtk/gtk.h>".}
proc gtk_spin_button_get_value*(spin: ptr GtkSpinButton): cdouble
  {.importc: "gtk_spin_button_get_value", header: "<gtk/gtk.h>".}
proc gtk_spin_button_set_value*(spin: ptr GtkSpinButton; value: cdouble)
  {.importc: "gtk_spin_button_set_value", header: "<gtk/gtk.h>".}

# ------------------------------------------------------------------------------
# DropDown (замена GtkComboBoxText в GTK4) — список строк через GtkStringList
# ------------------------------------------------------------------------------
## Настоящий заголовок GTK4 объявляет параметр как
## `const char * const *strings` (указатель на массив НЕИЗМЕНЯЕМЫХ
## указателей на неизменяемые строки). Если объявить его в Nim как
## `ptr cstring`, компилятор Nim сгенерирует C-тип `char**` — без
## какого-либо `const`. В языке C неявное добавление `const` разрешено
## только на САМОМ ВНЕШНЕМ уровне указателя (`char*` → `const char*` —
## можно), но не на вложенном (`char**` → `const char* const*` — нельзя,
## нужно явное приведение). GCC 14 (Fedora 44 и новее) сделал такое
## несовпадение уровней const жёсткой ошибкой компиляции по умолчанию
## (`-Werror=incompatible-pointer-types`), тогда как раньше это было
## лишь предупреждением — отсюда ошибка сборки именно на этой машине.
## Решение — объявить параметр как `pointer` (генерирует C `void*`):
## `void*` неявно и без предупреждений конвертируется в обе стороны
## с любым типом указателя, включая `const char* const*`.
proc gtk_string_list_new*(strings: pointer): ptr GtkStringList
  {.importc: "gtk_string_list_new", header: "<gtk/gtk.h>".}
proc gtk_drop_down_new*(model: pointer; expression: pointer): ptr GtkWidget
  {.importc: "gtk_drop_down_new", header: "<gtk/gtk.h>".}
proc gtk_drop_down_get_selected*(dd: ptr GtkDropDown): cuint
  {.importc: "gtk_drop_down_get_selected", header: "<gtk/gtk.h>".}
proc gtk_drop_down_set_selected*(dd: ptr GtkDropDown; pos: cuint)
  {.importc: "gtk_drop_down_set_selected", header: "<gtk/gtk.h>".}

# ------------------------------------------------------------------------------
# Своя фабрика строк списка — единственная причина, зачем она нужна:
# GTK4 сам по умолчанию рисует галочку для выбранного пункта СПРАВА от
# текста, без публичного способа передвинуть её влево. Чтобы получить
# "галочка, затем пробел, затем текст" (как попросили), пришлось взять
# рендеринг строки на себя: gtk_signal_list_item_factory_new() + сигналы
# "setup"/"bind" — стандартный способ кастомизировать вид строк
# GtkDropDown/GtkListView в GTK4.
proc gtk_signal_list_item_factory_new*(): ptr GtkListItemFactory
  {.importc: "gtk_signal_list_item_factory_new", header: "<gtk/gtk.h>".}
proc gtk_drop_down_set_factory*(dd: ptr GtkDropDown; factory: ptr GtkListItemFactory)
  {.importc: "gtk_drop_down_set_factory", header: "<gtk/gtk.h>".}
proc gtk_list_item_set_child*(item: pointer; child: ptr GtkWidget)
  {.importc: "gtk_list_item_set_child", header: "<gtk/gtk.h>".}
proc gtk_list_item_get_item*(item: pointer): pointer
  {.importc: "gtk_list_item_get_item", header: "<gtk/gtk.h>".}
proc gtk_list_item_get_selected*(item: pointer): cint
  {.importc: "gtk_list_item_get_selected", header: "<gtk/gtk.h>".}
proc gtk_string_object_get_string*(obj: pointer): cstring
  {.importc: "gtk_string_object_get_string", header: "<gtk/gtk.h>".}
proc gtk_image_new_from_icon_name*(icon_name: cstring): ptr GtkWidget
  {.importc: "gtk_image_new_from_icon_name", header: "<gtk/gtk.h>".}
proc gtk_widget_set_visible*(widget: ptr GtkWidget; visible: cint)
  {.importc: "gtk_widget_set_visible", header: "<gtk/gtk.h>".}
proc g_object_set_data*(obj: pointer; key: cstring; data: pointer)
  {.importc: "g_object_set_data", header: "<glib-object.h>".}
proc g_object_get_data*(obj: pointer; key: cstring): pointer
  {.importc: "g_object_get_data", header: "<glib-object.h>".}

proc g_object_bind_property*(source: pointer; source_property: cstring;
                              target: pointer; target_property: cstring;
                              flags: cint): pointer
  {.importc: "g_object_bind_property", header: "<glib-object.h>".}
proc g_binding_unbind*(binding: pointer)
  {.importc: "g_binding_unbind", header: "<glib-object.h>".}
const G_BINDING_SYNC_CREATE = 2.cint  # применить текущее значение сразу при создании привязки

proc onDropdownItemSetup(factory: pointer; listItem: pointer; userData: pointer) {.cdecl.} =
  ## "setup" вызывается один раз на строку popup-списка: создаём
  ## горизонтальный бокс [галочка-иконка, подпись] и запоминаем оба
  ## дочерних виджета на самом list item, чтобы достать их в "bind".
  let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6.cint)
  let check = gtk_image_new_from_icon_name("object-select-symbolic".cstring)
  gtk_widget_set_visible(check, 0.cint)
  let label = gtk_label_new(nil)
  gtk_box_append(cast[ptr GtkBox](box), check)
  gtk_box_append(cast[ptr GtkBox](box), label)
  gtk_list_item_set_child(listItem, box)
  g_object_set_data(listItem, "monolit-check".cstring, cast[pointer](check))
  g_object_set_data(listItem, "monolit-label".cstring, cast[pointer](label))

proc onDropdownItemBind(factory: pointer; listItem: pointer; userData: pointer) {.cdecl.} =
  ## "bind" вызывается при показе конкретного пункта — но для короткого
  ## нескролящегося списка (2-9 пунктов) GTK обычно НЕ переигрывает bind
  ## заново при каждой смене выбора: строки создаются один раз и потом
  ## переиспользуются как есть. Поэтому разовое чтение
  ## gtk_list_item_get_selected() тут не работает — галочка застывала на
  ## пункте, который был выбран в момент самого первого открытия списка
  ## (см. скриншот — mkv выбран, а галочка так и осталась на mp4).
  ## Правильно — живая привязка свойства "selected" -> "visible" через
  ## g_object_bind_property: она сама реагирует на изменение selected в
  ## любой момент, без повторного bind. Старую привязку (если bind всё
  ## же вызвался повторно) снимаем, чтобы не плодить дубликаты.
  let check = cast[ptr GtkWidget](g_object_get_data(listItem, "monolit-check".cstring))
  let label = cast[ptr GtkLabel](g_object_get_data(listItem, "monolit-label".cstring))
  let text = gtk_string_object_get_string(gtk_list_item_get_item(listItem))
  gtk_label_set_text(label, text)
  let oldBinding = g_object_get_data(listItem, "monolit-binding".cstring)
  if oldBinding != nil:
    g_binding_unbind(oldBinding)
  let binding = g_object_bind_property(listItem, "selected".cstring,
                                       cast[pointer](check), "visible".cstring,
                                       G_BINDING_SYNC_CREATE)
  g_object_set_data(listItem, "monolit-binding".cstring, binding)

proc newDropDown*(items: openArray[string]): ptr GtkWidget =
  ## Хелпер: строит GtkDropDown из seq[string] — прячет возню с
  ## NULL-terminated char** массивом, которого требует gtk_string_list_new,
  ## и подключает свою фабрику строк (см. onDropdownItemSetup/Bind выше),
  ## чтобы галочка выбранного пункта была слева от текста, а не справа
  ## (штатное поведение GTK4). Массив items остаётся "чистым" — сама
  ## строка модели (и то, что вернёт gtk_string_object_get_string) не
  ## содержит никакой галочки, это только визуальная надстройка.
  var cstrs = newSeq[cstring](len(items) + 1)
  for i, s in items: cstrs[i] = s.cstring
  cstrs[len(items)] = nil
  let model = gtk_string_list_new(addr cstrs[0])
  result = gtk_drop_down_new(cast[pointer](model), nil)
  let factory = gtk_signal_list_item_factory_new()
  connect(cast[pointer](factory), "setup", onDropdownItemSetup)
  connect(cast[pointer](factory), "bind", onDropdownItemBind)
  gtk_drop_down_set_factory(cast[ptr GtkDropDown](result), factory)

# ------------------------------------------------------------------------------
# ProgressBar
# ------------------------------------------------------------------------------
proc gtk_progress_bar_new*(): ptr GtkWidget
  {.importc: "gtk_progress_bar_new", header: "<gtk/gtk.h>".}
proc gtk_progress_bar_set_fraction*(bar: ptr GtkProgressBar; fraction: cdouble)
  {.importc: "gtk_progress_bar_set_fraction", header: "<gtk/gtk.h>".}
proc gtk_progress_bar_set_text*(bar: ptr GtkProgressBar; text: cstring)
  {.importc: "gtk_progress_bar_set_text", header: "<gtk/gtk.h>".}
proc gtk_progress_bar_set_show_text*(bar: ptr GtkProgressBar; show: cint)
  {.importc: "gtk_progress_bar_set_show_text", header: "<gtk/gtk.h>".}

# ------------------------------------------------------------------------------
# Выбор файла — GtkFileChooserNative (нативный диалог и на Linux, и на
# Windows; в отличие от GtkFileDialog (>=4.10) доступен уже с GTK 3.20,
# так что не привязывает минимальную версию GTK4 слишком высоко).
# ------------------------------------------------------------------------------
proc gtk_file_chooser_native_new*(title: cstring; parent: ptr GtkWindow;
                                   action: GtkFileChooserAction;
                                   accept_label, cancel_label: cstring): ptr GtkFileChooserNative
  {.importc: "gtk_file_chooser_native_new", header: "<gtk/gtk.h>".}
proc gtk_native_dialog_show*(dialog: pointer)
  {.importc: "gtk_native_dialog_show", header: "<gtk/gtk.h>".}
proc gtk_native_dialog_destroy*(dialog: pointer)
  {.importc: "gtk_native_dialog_destroy", header: "<gtk/gtk.h>".}
proc gtk_file_chooser_get_file*(chooser: pointer): ptr GFile
  {.importc: "gtk_file_chooser_get_file", header: "<gtk/gtk.h>".}
proc gtk_file_chooser_set_current_name*(chooser: pointer; name: cstring)
  {.importc: "gtk_file_chooser_set_current_name", header: "<gtk/gtk.h>".}
proc gtk_file_chooser_add_filter*(chooser: pointer; filter: ptr GtkFileFilter)
  {.importc: "gtk_file_chooser_add_filter", header: "<gtk/gtk.h>".}
proc gtk_file_filter_new*(): ptr GtkFileFilter
  {.importc: "gtk_file_filter_new", header: "<gtk/gtk.h>".}
proc gtk_file_filter_add_pattern*(filter: ptr GtkFileFilter; pattern: cstring)
  {.importc: "gtk_file_filter_add_pattern", header: "<gtk/gtk.h>".}
proc gtk_file_filter_set_name*(filter: ptr GtkFileFilter; name: cstring)
  {.importc: "gtk_file_filter_set_name", header: "<gtk/gtk.h>".}
proc g_file_get_path*(file: ptr GFile): cstring
  {.importc: "g_file_get_path", header: "<gio/gio.h>".}

# ------------------------------------------------------------------------------
# Главный цикл / потокобезопасное обновление UI из воркер-потока
#
# GTK НЕ потокобезопасен: обновлять виджеты можно только из главного
# потока. Как и в PMI (см. worker.nim, progressBuf в allocShared-памяти),
# фоновый поток Monolit пишет прогресс ТОЛЬКО в общую shared-переменную
# (не трогая виджеты напрямую), а g_idle_add планирует функцию-колбэк,
# которая выполнится в главном GTK-потоке и там уже безопасно обновит
# GtkProgressBar/GtkLabel.
# ------------------------------------------------------------------------------
type GSourceFunc* = proc(data: pointer): cint {.cdecl.}

proc g_idle_add*(function: GSourceFunc; data: pointer): cuint
  {.importc: "g_idle_add", header: "<glib.h>".}

const G_SOURCE_REMOVE* = 0.cint  # возврат из GSourceFunc: не вызывать повторно

# ------------------------------------------------------------------------------
# locale.h — принудительный возврат LC_NUMERIC в "C" после инициализации GTK
#
# GTK4 при старте сам вызывает setlocale(LC_ALL, "") (нужно для переводов
# интерфейса, форматов дат и т.п.), из-за чего процесс подхватывает
# СИСТЕМНУЮ локаль пользователя целиком — в т.ч. LC_NUMERIC. В локалях,
# где десятичный разделитель — запятая (ru_RU, de_DE, большинство
# европейских), это ломает разбор числовых аргументов фильтр-графов
# FFmpeg: libavutil (av_expr/strtod) при парсинге "0.300" в такой локали
# читает только "0", натыкается на ".300" и падает с "Invalid chars".
# Nim же форматирует float всегда через точку, независимо от локали —
# то есть сама генерация строки корректна, а вот av_expr_parse её
# трактует уже по локали ПРОЦЕССА. LC_NUMERIC=C — это то, что FFmpeg
# всегда ожидает от хост-приложения (см. документацию libavutil).
# Значение LC_NUMERIC импортируется из <locale.h>, а не захардкожено,
# т.к. на разных платформах (glibc vs MSVCRT на Windows) числовое
# значение этого макроса разное.
var LC_NUMERIC* {.importc: "LC_NUMERIC", header: "<locale.h>".}: cint
proc c_setlocale*(category: cint; locale: cstring): cstring
  {.importc: "setlocale", header: "<locale.h>".}
