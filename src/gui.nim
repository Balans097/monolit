# ==============================================================================
#  gui.nim — построение и логика GTK4-интерфейса Monolit (4 вкладки)
#
#  Вынесено из Monolit.nim в отдельный модуль, чтобы точка входа приложения
#  оставалась тонкой (main() + av_log_set_level), а вся разметка окна,
#  обработчики сигналов и чтение значений виджетов в StabConfig жили рядом
#  друг с другом в одном файле src/. Монолит.nim теперь только вызывает
#  runApp() отсюда.
# ==============================================================================

import std/[strformat, os, strutils]
import gtk4_api, stabilizer

const MONOLIT_VERSION* = "1.3"

# ------------------------------------------------------------------------------
# Язык интерфейса — переключается на лету без перезапуска (переключатель
# внизу вкладки «Файл», см. buildFileTab). Каждый виджет с переводимым
# текстом регистрирует здесь замыкание "переприменить перевод к себе" (см.
# registerTr) сразу в момент своего создания — это одновременно ставит
# текст на текущем языке и запоминает, как обновить его позже. Такой
# подход через реестр замыканий вместо отдельного поля под каждую подпись
# в Widgets: переводимых виджетов (заголовки, подписи ползунков, чекбоксы,
# заметки, заголовки вкладок) в разы больше, чем реально нужных где-то ещё
# в обработчиках сигналов, и раздувать Widgets ради этого не хотелось.
# ------------------------------------------------------------------------------
type UiLang = enum uiRu, uiEn

var uiLang: UiLang = uiRu   # русский — язык интерфейса по умолчанию

proc tr(ru, en: string): string =
  if uiLang == uiRu: ru else: en

var uiTranslators: seq[proc () {.closure.}] = @[]

proc registerTr(action: proc () {.closure.}) =
  add(uiTranslators, action)
  action()   # сразу применяем на текущем языке — вызывающему не нужно
             # отдельно проставлять исходный текст самому

proc applyLanguage() =
  for action in uiTranslators: action()

# ------------------------------------------------------------------------------
# Списки значений для выпадающих списков — индекс в массиве == индекс,
# который вернёт gtk_drop_down_get_selected().
# ------------------------------------------------------------------------------
const
  PRESET_ITEMS = ["ultrafast", "superfast", "veryfast", "faster", "fast",
                  "medium", "slow", "slower", "veryslow"]
  PRESET_DEFAULT_IDX = 6   # "slow" — разумный компромисс качество/скорость по умолчанию

  INTERPOL_ITEMS = ["no", "linear", "bilinear", "bicubic"]
  INTERPOL_DEFAULT_IDX = 3 # "bicubic" — максимальное качество интерполяции

  CROP_ITEMS = ["keep", "black"]
  CROP_DEFAULT_IDX = 0     # "keep"

  # Контейнер результата — влияет на расширение файла в диалоге
  # сохранения (см. selectedContainerExt/onPickOutput/onSaveResponse
  # ниже); реальный мьюксер libavformat выбирает по расширению
  # cfg.outputFile (avformat_alloc_output_context2), поэтому важно,
  # чтобы выбор в этом списке и итоговое расширение файла не расходились.
  CONTAINER_ITEMS = ["mp4", "mkv"]
  CONTAINER_DEFAULT_IDX = 0   # "mp4"

  # Индекс 0 обязан соответствовать EncodeMode.emCRF, индекс 1 — emBitrate2Pass
  # (см. collectConfig и onEncodeModeChanged ниже — оба жёстко завязаны на
  # этот порядок). Единственный список с "естественным" языком текста —
  # поэтому единственный, чьи пункты подменяются при переключении языка
  # интерфейса (см. onLanguageChanged) через setDropDownItems.
  ENCODE_MODE_ITEMS_RU = ["1 проход (CRF)", "2 прохода (задать битрейт)"]
  ENCODE_MODE_ITEMS_EN = ["1 pass (CRF)", "2 passes (set bitrate)"]
  ENCODE_MODE_DEFAULT_IDX = 0

  # Названия языков традиционно показываются каждое на себе самом (в самом
  # языке), а не переводятся — поэтому здесь нет RU/EN-варианта.
  LANGUAGE_ITEMS = ["Русский", "English"]

# ------------------------------------------------------------------------------
# Все виджеты, к которым нужен доступ и при построении UI, и в обработчиках
# сигналов, и в таймере прогресса — собраны в один глобальный объект.
# Приложение однооконное и однопоточное для GTK (весь тяжёлый труд ушёл в
# фоновый поток stabilizer'а), так что глобальное состояние здесь оправданно
# и проще, чем тащить контекст через user_data во все колбэки.
# ------------------------------------------------------------------------------
type
  Widgets = object
    window:        ptr GtkWindow
    inputLabel:    ptr GtkLabel
    outputLabel:   ptr GtkLabel
    container:     ptr GtkDropDown   # выбор контейнера результата: mp4 / mkv

    shakiness:     ptr GtkRange
    accuracy:      ptr GtkRange
    stepsize:      ptr GtkRange
    mincontrast:   ptr GtkRange

    smoothing:     ptr GtkRange
    zoom:          ptr GtkRange
    optzoom:       ptr GtkDropDown
    crop:          ptr GtkDropDown
    interpol:      ptr GtkDropDown
    maxShift:      ptr GtkRange
    maxAngle:      ptr GtkRange

    sharpenEnabled: ptr GtkCheckButton
    sharpenAmount:  ptr GtkRange

    smartblurEnabled:   ptr GtkCheckButton
    smartblurRadius:    ptr GtkRange
    smartblurStrength:  ptr GtkRange
    smartblurThreshold: ptr GtkRange

    casEnabled:  ptr GtkCheckButton
    casStrength: ptr GtkRange

    preset:        ptr GtkDropDown
    encodeMode:    ptr GtkDropDown  # "1 проход (CRF)" / "2 прохода (битрейт)"
    crf:           ptr GtkRange
    videoBitrate:  ptr GtkRange     # кбит/с, активен только в режиме 2 проходов
    copyAudio:     ptr GtkCheckButton
    saveSubtitles:   ptr GtkCheckButton
    saveAttachments: ptr GtkCheckButton

    startButton:   ptr GtkButton
    startButtonLabel: ptr GtkLabel  # надпись на startButton — переключаем
                                     # текст между "Старт"/"Стоп" (Start/Stop)
    progressBar:   ptr GtkProgressBar
    statusLabel:   ptr GtkLabel

    language:      ptr GtkDropDown  # переключатель языка интерфейса (низ вкладки «Файл»)

var
  w: Widgets
  cfg: StabConfig = defaultStabConfig()
  procThread: Thread[StabConfig]
  timeoutId: cuint = 0
  jobRunning: bool = false
  # true, если пользователь явно выбрал путь сохранения через диалог
  # «Куда сохранить...» — тогда автоподстановка выходного пути рядом со
  # входным файлом (см. onOpenResponse) больше не трогает выбор.
  outputExplicit: bool = false

# g_timeout_add — в GLib это макрос-обёртка над g_timeout_add_full; здесь
# нужна ровно одна функция, поэтому импортируем её напрямую, не расширяя
# ради этого gtk4_api.nim. Объявлена заранее, до первого использования
# в onStartStopClicked ниже (Nim требует объявления сверху вниз).
proc g_timeout_add_wrapper(interval: cuint; fn: GSourceFunc; data: pointer): cuint
  {.importc: "g_timeout_add", header: "<glib.h>".}

# ------------------------------------------------------------------------------
# Мелкие билдеры — чтобы не повторять одну и ту же разметку "подпись + control"
# на четырёх вкладках подряд.
# ------------------------------------------------------------------------------
proc labeledRow(box: ptr GtkBox; captionRu, captionEn: string; control: ptr GtkWidget) =
  let
    row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, cint(12))
    lbl = gtk_label_new(nil)
  registerTr(proc () = gtk_label_set_text(cast[ptr GtkLabel](lbl), cstring(tr(captionRu, captionEn))))
  gtk_label_set_xalign(cast[ptr GtkLabel](lbl), 0.0)
  gtk_widget_set_hexpand(lbl, cint(0))
  gtk_widget_set_hexpand(control, cint(1))
  gtk_box_append(cast[ptr GtkBox](row), lbl)
  gtk_box_append(cast[ptr GtkBox](row), control)
  gtk_box_append(box, row)

proc newScaleRow(box: ptr GtkBox; captionRu, captionEn: string;
                  min, max, step, initial: float; digits: int): ptr GtkRange =
  let scale = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL,
                                        cdouble(min), cdouble(max), cdouble(step))
  gtk_scale_set_digits(cast[ptr GtkScale](scale), cint(digits))
  # Показываем текущее числовое значение прямо на ползунке (справа от
  # него) — стандартный механизм GTK, без отдельного синхронизируемого
  # вручную GtkLabel.
  gtk_scale_set_draw_value(cast[ptr GtkScale](scale), cint(1))
  gtk_scale_set_value_pos(cast[ptr GtkScale](scale), GTK_POS_RIGHT)
  gtk_range_set_value(cast[ptr GtkRange](scale), cdouble(initial))
  labeledRow(box, captionRu, captionEn, scale)
  result = cast[ptr GtkRange](scale)

proc newDropDownRow(box: ptr GtkBox; captionRu, captionEn: string;
                     items: openArray[string]; defaultIdx: int): ptr GtkDropDown =
  let dd = newDropDown(items)
  gtk_drop_down_set_selected(cast[ptr GtkDropDown](dd), cuint(defaultIdx))
  labeledRow(box, captionRu, captionEn, dd)
  result = cast[ptr GtkDropDown](dd)

# ------------------------------------------------------------------------------
# Хелперы для текста с Pango-разметкой (жирный/курсив). gtk_label_new()
# и gtk_check_button_new_with_label() размечать текст сами не умеют —
# разметка ставится отдельным вызовом gtk_label_set_markup() уже после
# создания виджета, а для чекбокса/кнопки подпись приходится собирать
# вручную как child-виджет вместо параметра label.
# ------------------------------------------------------------------------------
proc newBoldLabel(ru, en: string): ptr GtkWidget =
  let lbl = gtk_label_new(nil)
  registerTr(proc () = gtk_label_set_markup(cast[ptr GtkLabel](lbl), cstring("<b>" & tr(ru, en) & "</b>")))
  gtk_label_set_xalign(cast[ptr GtkLabel](lbl), 0.0)
  result = lbl

proc newItalicLabel(ru, en: string): ptr GtkWidget =
  let lbl = gtk_label_new(nil)
  registerTr(proc () = gtk_label_set_markup(cast[ptr GtkLabel](lbl), cstring("<i>" & tr(ru, en) & "</i>")))
  gtk_label_set_xalign(cast[ptr GtkLabel](lbl), 0.0)
  result = lbl

proc newBoldCheckButton(ru, en: string): ptr GtkWidget =
  result = gtk_check_button_new()
  let lbl = newBoldLabel(ru, en)
  gtk_check_button_set_child(cast[ptr GtkCheckButton](result), lbl)

proc newCheckButton(ru, en: string): ptr GtkWidget =
  ## Обычный (не полужирный) чекбокс со встроенной GTK-подписью — в
  ## отличие от newBoldCheckButton, здесь подпись хранится самим GTK
  ## (gtk_check_button_set_label), а не отдельным Label-child.
  let btn = gtk_check_button_new()
  registerTr(proc () = gtk_check_button_set_label(cast[ptr GtkCheckButton](btn), cstring(tr(ru, en))))
  result = btn

proc newPage(tabTitleRu, tabTitleEn: string; notebook: ptr GtkNotebook): ptr GtkBox =
  let page = gtk_box_new(GTK_ORIENTATION_VERTICAL, cint(8))
  gtk_widget_set_margin_top(page, cint(12))
  gtk_widget_set_margin_bottom(page, cint(12))
  gtk_widget_set_margin_start(page, cint(12))
  gtk_widget_set_margin_end(page, cint(12))
  let tabLabel = gtk_label_new(nil)
  registerTr(proc () = gtk_label_set_text(cast[ptr GtkLabel](tabLabel), cstring(tr(tabTitleRu, tabTitleEn))))
  discard gtk_notebook_append_page(notebook, page, tabLabel)
  result = cast[ptr GtkBox](page)

# ------------------------------------------------------------------------------
# Вкладка «Файл»
# ------------------------------------------------------------------------------
proc selectedContainerExt(): string =
  ## Расширение (без точки), выбранное в выпадающем списке «Контейнер
  ## результата» на вкладке «Файл» — "mp4" или "mkv".
  CONTAINER_ITEMS[int(gtk_drop_down_get_selected(w.container))]

proc onOpenResponse(dialog: pointer; response: cint; userData: pointer) {.cdecl.} =
  if GtkResponseType(response) == GTK_RESPONSE_ACCEPT:
    let file = gtk_file_chooser_get_file(dialog)
    if file != nil:
      let path = g_file_get_path(file)
      if path != nil:
        cfg.inputFile = $path
        gtk_label_set_text(w.inputLabel, cstring(cfg.inputFile))
        if not outputExplicit:
          # По умолчанию сохраняем рядом со входным файлом, пока
          # пользователь явно не укажет другое место через «Куда
          # сохранить...» — после этого outputExplicit=true и
          # автоподстановка больше не трогает выбор (см. onSaveResponse).
          let (dir, _, _) = splitFile(cfg.inputFile)
          let ext = selectedContainerExt()
          cfg.outputFile = (if len(dir) > 0: dir / ("stabilized." & ext)
                             else: "stabilized." & ext)
          gtk_label_set_text(w.outputLabel, cstring(cfg.outputFile))
        g_free(cast[pointer](path))
      g_object_unref(cast[pointer](file))
  gtk_native_dialog_destroy(dialog)

proc onSaveResponse(dialog: pointer; response: cint; userData: pointer) {.cdecl.} =
  if GtkResponseType(response) == GTK_RESPONSE_ACCEPT:
    let file = gtk_file_chooser_get_file(dialog)
    if file != nil:
      let path = g_file_get_path(file)
      if path != nil:
        var outPath = $path
        let wantExt = selectedContainerExt()
        # Пользователь мог вручную стереть/переписать расширение прямо в
        # диалоге сохранения — гарантируем, что реально будет использован
        # именно тот контейнер, что выбран на вкладке «Файл», иначе
        # libavformat (avformat_alloc_output_context2) определит мьюксер
        # по фактическому расширению файла, и оно разойдётся с тем, что
        # видел пользователь в выпадающем списке.
        if not endsWith(toLowerAscii(outPath), "." & wantExt):
          outPath = changeFileExt(outPath, wantExt)
        cfg.outputFile = outPath
        gtk_label_set_text(w.outputLabel, cstring(cfg.outputFile))
        outputExplicit = true
        g_free(cast[pointer](path))
      g_object_unref(cast[pointer](file))
  gtk_native_dialog_destroy(dialog)

proc onContainerChanged(dd: pointer; pspec: pointer; userData: pointer) {.cdecl.} =
  ## При смене контейнера сразу меняем расширение УЖЕ выбранного пути
  ## сохранения — иначе легко получить mkv-файл с именем output.mp4
  ## просто потому что забыли поправить расширение вручную.
  if len(cfg.outputFile) == 0: return
  let wantExt = selectedContainerExt()
  if not endsWith(toLowerAscii(cfg.outputFile), "." & wantExt):
    cfg.outputFile = changeFileExt(cfg.outputFile, wantExt)
    gtk_label_set_text(w.outputLabel, cstring(cfg.outputFile))

proc onPickInput(btn: ptr GtkButton; userData: pointer) {.cdecl.} =
  let filt = gtk_file_filter_new()
  gtk_file_filter_set_name(filt, cstring(tr("Видео", "Video")))
  for pat in ["*.mp4", "*.mkv", "*.mov", "*.avi", "*.webm"]:
    gtk_file_filter_add_pattern(filt, cstring(pat))
  let dlg = gtk_file_chooser_native_new(
    cstring(tr("Выберите исходное видео", "Choose source video")), w.window,
    GTK_FILE_CHOOSER_ACTION_OPEN, cstring(tr("Открыть", "Open")), cstring(tr("Отмена", "Cancel")))
  gtk_file_chooser_add_filter(cast[pointer](dlg), filt)
  connect(cast[pointer](dlg), "response", onOpenResponse)
  gtk_native_dialog_show(cast[pointer](dlg))

proc onPickOutput(btn: ptr GtkButton; userData: pointer) {.cdecl.} =
  let ext = selectedContainerExt()
  let dlg = gtk_file_chooser_native_new(
    cstring(tr("Сохранить стабилизированное видео как", "Save stabilized video as")), w.window,
    GTK_FILE_CHOOSER_ACTION_SAVE, cstring(tr("Сохранить", "Save")), cstring(tr("Отмена", "Cancel")))
  let filt = gtk_file_filter_new()
  gtk_file_filter_set_name(filt, cstring(ext & " " & tr("видео", "video")))
  gtk_file_filter_add_pattern(filt, cstring("*." & ext))
  gtk_file_chooser_add_filter(cast[pointer](dlg), filt)
  gtk_file_chooser_set_current_name(cast[pointer](dlg), cstring("stabilized." & ext))
  connect(cast[pointer](dlg), "response", onSaveResponse)
  gtk_native_dialog_show(cast[pointer](dlg))

proc onLanguageChanged(dd: pointer; pspec: pointer; userData: pointer) {.cdecl.} =
  let idx = int(gtk_drop_down_get_selected(cast[ptr GtkDropDown](dd)))
  uiLang = if idx == 0: uiRu else: uiEn
  # ENCODE_MODE_ITEMS — единственный список с "естественным" (не
  # техническим) текстом пунктов, поэтому единственный, чьи пункты нужно
  # физически подменить; остальные подписи обновляет applyLanguage() ниже
  # через реестр registerTr.
  setDropDownItems(w.encodeMode, if uiLang == uiRu: ENCODE_MODE_ITEMS_RU else: ENCODE_MODE_ITEMS_EN)
  applyLanguage()

proc buildFileTab(notebook: ptr GtkNotebook) =
  let page = newPage("Файл", "File", notebook)

  let
    inRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, cint(12))
    inBtn = gtk_button_new()
  registerTr(proc () = gtk_button_set_label(cast[ptr GtkButton](inBtn),
    cstring(tr("Выбрать исходное видео...", "Choose source video..."))))
  w.inputLabel = cast[ptr GtkLabel](gtk_label_new(cstring(cfg.inputFile)))
  gtk_label_set_xalign(w.inputLabel, 0.0)
  gtk_widget_set_hexpand(cast[ptr GtkWidget](w.inputLabel), cint(1))
  connect(cast[pointer](inBtn), "clicked", onPickInput)
  gtk_box_append(cast[ptr GtkBox](inRow), inBtn)
  gtk_box_append(cast[ptr GtkBox](inRow), cast[ptr GtkWidget](w.inputLabel))
  gtk_box_append(page, inRow)

  let
    outRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, cint(12))
    outBtn = gtk_button_new()
  registerTr(proc () = gtk_button_set_label(cast[ptr GtkButton](outBtn),
    cstring(tr("Куда сохранить...", "Save to..."))))
  w.outputLabel = cast[ptr GtkLabel](gtk_label_new(cstring(cfg.outputFile)))
  gtk_label_set_xalign(w.outputLabel, 0.0)
  gtk_widget_set_hexpand(cast[ptr GtkWidget](w.outputLabel), cint(1))
  connect(cast[pointer](outBtn), "clicked", onPickOutput)
  gtk_box_append(cast[ptr GtkBox](outRow), outBtn)
  gtk_box_append(cast[ptr GtkBox](outRow), cast[ptr GtkWidget](w.outputLabel))
  gtk_box_append(page, outRow)

  w.container = newDropDownRow(page, "Контейнер результата", "Output container",
                                CONTAINER_ITEMS, CONTAINER_DEFAULT_IDX)
  connect(cast[pointer](w.container), "notify::selected", onContainerChanged)
  let containerNote = newItalicLabel(
    "mkv надёжнее сохраняет субтитры и вложения (шрифты); mp4 — самый\n" &
    "совместимый вариант для проигрывателей и сайтов. Расширение файла\n" &
    "в диалоге «Куда сохранить...» подставляется по этому выбору.",
    "mkv preserves subtitles and attachments (fonts) more reliably; mp4\n" &
    "is the most compatible option for players and websites. The file\n" &
    "extension in the \"Save to...\" dialog follows this choice.")
  gtk_widget_set_margin_bottom(containerNote, cint(6))
  gtk_box_append(page, containerNote)

  let audioChk = newCheckButton("Копировать звук без перекодирования", "Copy audio without re-encoding")
  gtk_check_button_set_active(cast[ptr GtkCheckButton](audioChk), cint(1))
  w.copyAudio = cast[ptr GtkCheckButton](audioChk)
  gtk_box_append(page, audioChk)

  # Раньше субтитры копировались автоматически вместе со звуком (одним
  # флагом copyAudio на оба типа потоков) — теперь это два независимых
  # переключателя: можно, например, сохранить звук, но выкинуть субтитры,
  # или наоборот.
  let subsChk = newCheckButton("Сохранить субтитры", "Keep subtitles")
  gtk_check_button_set_active(cast[ptr GtkCheckButton](subsChk), cint(1))
  w.saveSubtitles = cast[ptr GtkCheckButton](subsChk)
  gtk_box_append(page, subsChk)

  # "Вложения" контейнера — это, как правило, встроенные в mkv шрифты
  # (нужны для корректного отображения стилизованных субтитров ASS/SSA)
  # и другие произвольные файлы, которые можно прикрепить к mkv-контейнеру.
  let attachChk = newCheckButton("Сохранить вложения (шрифты и т.п.)", "Keep attachments (fonts, etc.)")
  gtk_check_button_set_active(cast[ptr GtkCheckButton](attachChk), cint(1))
  w.saveAttachments = cast[ptr GtkCheckButton](attachChk)
  gtk_box_append(page, attachChk)

  # --- Язык интерфейса --------------------------------------------------------
  # По явному требованию — переключатель языка внизу именно вкладки
  # «Файл», а не где-то в общей области окна. Разделитель сверху отделяет
  # его от настроек контейнера/звука визуально, чтобы не выглядело единым
  # списком с ними.
  let sep = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL)
  gtk_widget_set_margin_top(sep, cint(14))
  gtk_widget_set_margin_bottom(sep, cint(6))
  gtk_box_append(page, sep)

  w.language = newDropDownRow(page, "Язык интерфейса", "Interface language",
                               LANGUAGE_ITEMS, 0)
  connect(cast[pointer](w.language), "notify::selected", onLanguageChanged)

# ------------------------------------------------------------------------------
# Вкладка «Стабилизация»
# ------------------------------------------------------------------------------
proc buildStabTab(notebook: ptr GtkNotebook) =
  let page = newPage("Стабилизация", "Stabilization", notebook)

  let hdr1 = newBoldLabel("Проход 1 — анализ движения (vidstabdetect)",
                           "Pass 1 — motion analysis (vidstabdetect)")
  gtk_box_append(page, hdr1)

  w.shakiness   = newScaleRow(page, "Резкость тряски (shakiness)", "Shakiness",
                               1, 10, 1, 10, 0)
  w.accuracy    = newScaleRow(page, "Точность анализа (accuracy)", "Accuracy",
                               1, 15, 1, 15, 0)
  w.stepsize    = newScaleRow(page, "Шаг поиска (stepsize)", "Step size",
                               1, 32, 1, 1,  0)
  w.mincontrast = newScaleRow(page, "Мин. контраст (mincontrast)", "Min. contrast",
                               0.0, 1.0, 0.05, 0.3, 2)

  let hdr2 = newBoldLabel("Проход 2 — компенсация (vidstabtransform)",
                           "Pass 2 — compensation (vidstabtransform)")
  gtk_widget_set_margin_top(hdr2, cint(12))
  gtk_box_append(page, hdr2)

  w.smoothing = newScaleRow(page, "Сглаживание (кадров)", "Smoothing (frames)",
                             0, 200, 1, 30, 0)
  w.zoom      = newScaleRow(page, "Базовый зум, %", "Base zoom, %",
                             0, 50,  1, 0,  0)
  w.optzoom   = newDropDownRow(page,
                  "Автозум (optzoom): 0=выкл 1=статич. 2=адаптивн.",
                  "Auto zoom (optzoom): 0=off 1=static 2=adaptive",
                  ["0", "1", "2"], 2)
  w.crop      = newDropDownRow(page, "Края кадра (crop)", "Frame edges (crop)",
                                CROP_ITEMS, CROP_DEFAULT_IDX)
  w.interpol  = newDropDownRow(page, "Интерполяция (interpol)", "Interpolation",
                                INTERPOL_ITEMS, INTERPOL_DEFAULT_IDX)
  w.maxShift  = newScaleRow(page, "Макс. сдвиг, px (-1 = без ограничения)",
                             "Max shift, px (-1 = unlimited)",
                             -1, 500, 1, -1, 0)
  w.maxAngle  = newScaleRow(page, "Макс. угол, рад (-1 = без ограничения)",
                             "Max angle, rad (-1 = unlimited)",
                             -1, 3, 0.05, -1, 2)

  let note = newItalicLabel(
    "«Чёрные поля» = crop=black; вариант «keep» дотягивает картинку\n" &
    "с предыдущего кадра вместо чёрной рамки.",
    "\"Black bars\" = crop=black; the \"keep\" option stretches the\n" &
    "previous frame's image instead of a black border.")
  gtk_widget_set_margin_top(note, cint(6))
  gtk_box_append(page, note)

# ------------------------------------------------------------------------------
# Вкладка «Резкость»
# ------------------------------------------------------------------------------
# Два чекбокса-фильтра резкости (unsharp/CAS) взаимно исключают друг
# друга — см. пояснение в buildSharpenTab ниже. Smart Blur — НЕЗАВИСИМЫЙ
# denoise/softening-фильтр: в реальном filter chain (buildTransformFilterDesc
# в stabilizer.nim) он всегда ставится ПЕРЕД unsharp/cas и может применяться
# одновременно с любым из них (шумоподавление до резкости — обычная и
# осмысленная комбинация, а не взаимоисключающая альтернатива). Раньше
# один обработчик гасил все три чекбокса разом, из-за чего Smart Blur
# нельзя было включить вместе с unsharp или cas, хотя пайплайн и
# документация (manual.md) описывают его как независимый (см. F-13
# аудита). Поэтому здесь два отдельных обработчика: onSharpenExclusiveToggled
# трогает только unsharp/cas, а Smart Blur переключается сам по себе без
# побочных эффектов на другие чекбоксы.
proc onSharpenExclusiveToggled(cb: ptr GtkCheckButton; userData: pointer) {.cdecl.} =
  if gtk_check_button_get_active(cb) == 0:
    return
  if cb != w.sharpenEnabled: gtk_check_button_set_active(w.sharpenEnabled, cint(0))
  if cb != w.casEnabled:     gtk_check_button_set_active(w.casEnabled, cint(0))

proc buildSharpenTab(notebook: ptr GtkNotebook) =
  let page = newPage("Резкость", "Sharpness", notebook)

  # --- smartblur: опциональное шумоподавление/смягчение ---------------------
  let sbChk = newBoldCheckButton(
    "Применить Smart Blur (smartblur) — шумоподавление/смягчение",
    "Apply Smart Blur (smartblur) — noise reduction/softening")
  w.smartblurEnabled = cast[ptr GtkCheckButton](sbChk)
  gtk_box_append(page, sbChk)

  w.smartblurRadius    = newScaleRow(page, "Радиус (luma_radius)", "Radius (luma_radius)",
                                      0.1, 5.0, 0.1, 1.0, 1)
  w.smartblurStrength  = newScaleRow(page, "Сила (luma_strength)", "Strength (luma_strength)",
                                      -1.0, 1.0, 0.05, 1.0, 2)
  w.smartblurThreshold = newScaleRow(page, "Порог (luma_threshold)", "Threshold (luma_threshold)",
                                      -30, 30, 1, 0, 0)

  let sbNote = newItalicLabel(
    "Smart Blur ставится ПЕРЕД фильтрами резкости ниже: резкость усиливает\n" &
    "уже имеющийся шум, поэтому шумоподавление имеет смысл делать раньше.",
    "Smart Blur is applied BEFORE the sharpening filters below: sharpening\n" &
    "amplifies existing noise, so denoising makes sense to do first.")
  gtk_widget_set_margin_top(sbNote, cint(6))
  gtk_widget_set_margin_bottom(sbNote, cint(6))
  gtk_box_append(page, sbNote)

  # --- unsharp: классическая резкость ----------------------------------------
  let chk = newBoldCheckButton("Повысить резкость после стабилизации (unsharp)",
                                "Increase sharpness after stabilization (unsharp)")
  w.sharpenEnabled = cast[ptr GtkCheckButton](chk)
  gtk_box_append(page, chk)

  w.sharpenAmount = newScaleRow(page, "Сила резкости (luma_amount)", "Sharpen strength (luma_amount)",
                                 0.0, 3.0, 0.1, 0.5, 2)

  # --- cas: Contrast Adaptive Sharpening -------------------------------------
  let casChk = newBoldCheckButton("Применить Contrast Adaptive Sharpening (cas)",
                                   "Apply Contrast Adaptive Sharpening (cas)")
  w.casEnabled = cast[ptr GtkCheckButton](casChk)
  gtk_widget_set_margin_top(casChk, cint(6))
  # По умолчанию включаем именно cas: из трёх фильтров резкости он меньше
  # всего «звенит» на контрастных краях (см. заметку ниже), поэтому это
  # наиболее безопасный/качественный выбор "из коробки". Устанавливаем
  # активным ДО connect(...) ниже, чтобы не спровоцировать одноразовый
  # холостой вызов onSharpenExclusiveToggled при старте.
  gtk_check_button_set_active(cast[ptr GtkCheckButton](casChk), cint(1))
  gtk_box_append(page, casChk)

  w.casStrength = newScaleRow(page, "Сила (strength)", "Strength", 0.0, 1.0, 0.05, 0.7, 2)

  # unsharp и cas исключают друг друга: одновременное включение обоих,
  # по всей видимости, лишено смысла (оба борются за резкость кадра
  # по-разному, и их эффекты только мешали бы друг другу). Smart Blur
  # решает другую задачу (шумоподавление ДО резкости) и включается
  # независимо от них — см. пояснение у onSharpenExclusiveToggled выше.
  connect(cast[pointer](chk),     "toggled", onSharpenExclusiveToggled)
  connect(cast[pointer](casChk),  "toggled", onSharpenExclusiveToggled)

  let note = newItalicLabel(
    "Резкость (unsharp/cas) применяется ПОСЛЕ стабилизации/зума — иначе\n" &
    "усиливаются артефакты исходной тряски вместо деталей кадра. Из этих\n" &
    "двух можно включить только один — cas меньше «звенит» на контрастных\n" &
    "краях, чем классический unsharp. Smart Blur независим и может быть\n" &
    "включён одновременно с любым из них.",
    "Sharpening (unsharp/cas) is applied AFTER stabilization/zoom — otherwise\n" &
    "it amplifies shake artifacts instead of frame detail. Only one of these\n" &
    "two can be enabled at a time — cas \"rings\" less on high-contrast edges\n" &
    "than classic unsharp. Smart Blur is independent and can be enabled\n" &
    "together with either of them.")
  gtk_widget_set_margin_top(note, cint(6))
  gtk_box_append(page, note)

# ------------------------------------------------------------------------------
# Вкладка «Компрессия»
# ------------------------------------------------------------------------------

# Переключение режима сжатия должно сразу же (де)активировать соответствующий
# ему числовой контрол: CRF имеет смысл только в однопроходном режиме,
# битрейт — только в двухпроходном; включать оба сразу вводит в заблуждение,
# т.к. реально применяется только один из них (см. stabilizer.buildTransformFilterDesc/
# runTransformPass, где выбор идёт по cfg.encodeMode).
proc onEncodeModeChanged(dd: pointer; pspec: pointer; userData: pointer) {.cdecl.} =
  let isTwoPass = gtk_drop_down_get_selected(cast[ptr GtkDropDown](dd)) == cuint(1)
  gtk_widget_set_sensitive(cast[ptr GtkWidget](w.crf), cint(not isTwoPass))
  gtk_widget_set_sensitive(cast[ptr GtkWidget](w.videoBitrate), cint(isTwoPass))

proc buildCompressionTab(notebook: ptr GtkNotebook) =
  let page = newPage("Компрессия", "Compression", notebook)

  w.encodeMode = newDropDownRow(page, "Режим сжатия", "Compression mode",
                                 ENCODE_MODE_ITEMS_RU, ENCODE_MODE_DEFAULT_IDX)
  connect(cast[pointer](w.encodeMode), "notify::selected", onEncodeModeChanged)

  w.preset = newDropDownRow(page, "Preset libx264", "Preset libx264",
                             PRESET_ITEMS, PRESET_DEFAULT_IDX)
  w.crf    = newScaleRow(page, "CRF (0=без потерь, 51=худшее качество)",
                          "CRF (0=lossless, 51=worst quality)", 0, 51, 1, 16, 0)
  w.videoBitrate = newScaleRow(page, "Целевой битрейт видео, кбит/с",
                                "Target video bitrate, kbps",
                                500, 50000, 100, 8000, 0)

  # По умолчанию выбран режим "1 проход (CRF)" — битрейт в нём не участвует
  # в кодировании вообще, поэтому сразу блокируем ползунок, чтобы не вводить
  # в заблуждение (актуальное состояние поддерживается onEncodeModeChanged).
  gtk_widget_set_sensitive(cast[ptr GtkWidget](w.videoBitrate), cint(0))

  # Курсив + два отдельных виджета вместо одного текстового блока: между
  # предложениями нужен явный вертикальный отступ, а не просто перенос
  # строки внутри одной подписи — margin_top у второго абзаца и даёт этот
  # "вертикальный пробел".
  let noteCRF = newItalicLabel(
    "«1 проход (CRF)» — постоянное качество на всём ролике; быстрее, но\n" &
    "итоговый размер файла заранее не предсказать. Для «наивысшего\n" &
    "качества» — preset=slow/slower и CRF 16-18.",
    "\"1 pass (CRF)\" — constant quality across the whole clip; faster, but\n" &
    "the final file size can't be predicted in advance. For \"highest\n" &
    "quality\" use preset=slow/slower and CRF 16-18.")
  gtk_widget_set_margin_top(noteCRF, cint(6))
  gtk_box_append(page, noteCRF)

  let note2Pass = newItalicLabel(
    "«2 прохода (битрейт)» — libx264 сначала проходит весь ролик, считая\n" &
    "статистику сложности сцен, затем кодирует повторно, распределяя биты\n" &
    "так, чтобы точно попасть в заданный битрейт/размер файла — вдвое\n" &
    "медленнее, зато предсказуемый результат.",
    "\"2 passes (bitrate)\" — libx264 first scans the whole clip gathering\n" &
    "scene-complexity statistics, then encodes again, distributing bits\n" &
    "so the target bitrate/file size is hit precisely — twice as slow,\n" &
    "but the result is predictable.")
  gtk_widget_set_margin_top(note2Pass, cint(10))   # вертикальный пробел между абзацами
  gtk_box_append(page, note2Pass)

# ------------------------------------------------------------------------------
# Считать значения со всех виджетов в StabConfig непосредственно перед стартом
# ------------------------------------------------------------------------------
proc collectConfig(): StabConfig =
  result = cfg   # inputFile/outputFile уже выставлены обработчиками выбора файла
  result.shakiness   = int(gtk_range_get_value(w.shakiness))
  result.accuracy    = int(gtk_range_get_value(w.accuracy))
  result.stepsize    = int(gtk_range_get_value(w.stepsize))
  result.mincontrast = float(gtk_range_get_value(w.mincontrast))

  result.smoothing = int(gtk_range_get_value(w.smoothing))
  result.zoom      = float(gtk_range_get_value(w.zoom))
  result.optzoom   = int(gtk_drop_down_get_selected(w.optzoom))
  result.crop      = CropMode(int(gtk_drop_down_get_selected(w.crop)))
  result.interpol  = InterpolMode(int(gtk_drop_down_get_selected(w.interpol)))
  result.maxShift  = int(gtk_range_get_value(w.maxShift))
  result.maxAngle  = float(gtk_range_get_value(w.maxAngle))

  result.sharpenEnabled = gtk_check_button_get_active(w.sharpenEnabled) != 0
  result.sharpenAmount  = float(gtk_range_get_value(w.sharpenAmount))

  result.smartblurEnabled   = gtk_check_button_get_active(w.smartblurEnabled) != 0
  result.smartblurRadius    = float(gtk_range_get_value(w.smartblurRadius))
  result.smartblurStrength  = float(gtk_range_get_value(w.smartblurStrength))
  result.smartblurThreshold = float(gtk_range_get_value(w.smartblurThreshold))

  result.casEnabled  = gtk_check_button_get_active(w.casEnabled) != 0
  result.casStrength = float(gtk_range_get_value(w.casStrength))

  result.preset     = PRESET_ITEMS[int(gtk_drop_down_get_selected(w.preset))]
  # Индекс 0 = "1 проход (CRF)" = emCRF, индекс 1 = "2 прохода" = emBitrate2Pass
  # (см. ENCODE_MODE_ITEMS_RU/EN выше — порядок жёстко согласован с EncodeMode).
  result.encodeMode = if gtk_drop_down_get_selected(w.encodeMode) == cuint(0):
                         emCRF
                       else:
                         emBitrate2Pass
  result.crf             = int(gtk_range_get_value(w.crf))
  result.videoBitrateKbps = int(gtk_range_get_value(w.videoBitrate))
  result.copyAudio  = gtk_check_button_get_active(w.copyAudio) != 0
  result.saveSubtitles   = gtk_check_button_get_active(w.saveSubtitles) != 0
  result.saveAttachments = gtk_check_button_get_active(w.saveAttachments) != 0
  result.tempDir    = getTempDir()

# ------------------------------------------------------------------------------
# Фоновый поток обработки + таймер опроса прогресса
# ------------------------------------------------------------------------------
proc processingThreadProc(jobCfg: StabConfig) {.thread.} =
  runStabilization(jobCfg)

proc updateStartButtonLabel() =
  ## Общая точка обновления надписи на кнопке «Старт»/«Стоп» — и для смены
  ## состояния (idle/выполняется), и для переключения языка интерфейса.
  ## Через gtk_label_set_markup, а не gtk_label_set_text: надпись изначально
  ## полужирная (см. onActivate), а gtk_label_set_text сбрасывает
  ## use-markup в FALSE и показывает голый текст без форматирования.
  let text = (if jobRunning: tr("Стоп", "Stop") else: tr("Старт", "Start"))
  gtk_label_set_markup(w.startButtonLabel, cstring("<b>" & text & "</b>"))

proc onProgressTick(userData: pointer): cint {.cdecl.} =
  let (phase, done, total, errMsg) = getStabProgress()

  case phase
  of phaseAnalyze:
    let frac = if total > 0: min(1.0, float(done) / float(total)) else: 0.0
    gtk_progress_bar_set_fraction(w.progressBar, cdouble(frac))
    gtk_label_set_text(w.statusLabel, cstring(tr(
      fmt"Проход 1/2 — анализ движения: {done}/{total} кадров",
      fmt"Pass 1/2 — motion analysis: {done}/{total} frames")))
    return cint(1)   # G_SOURCE_CONTINUE — таймер продолжает тикать

  of phaseEncodePass1:
    let frac = if total > 0: min(1.0, float(done) / float(total)) else: 0.0
    gtk_progress_bar_set_fraction(w.progressBar, cdouble(frac))
    gtk_label_set_text(w.statusLabel, cstring(tr(
      fmt"Кодирование, проход A/2 — сбор статистики битрейта: {done}/{total} кадров",
      fmt"Encoding, pass A/2 — gathering bitrate statistics: {done}/{total} frames")))
    return cint(1)

  of phaseTransform:
    let frac = if total > 0: min(1.0, float(done) / float(total)) else: 0.0
    gtk_progress_bar_set_fraction(w.progressBar, cdouble(frac))
    gtk_label_set_text(w.statusLabel, cstring(tr(
      fmt"Проход 2/2 — стабилизация и кодирование: {done}/{total} кадров",
      fmt"Pass 2/2 — stabilization and encoding: {done}/{total} frames")))
    return cint(1)

  of phaseDone:
    gtk_progress_bar_set_fraction(w.progressBar, 1.0)
    gtk_label_set_text(w.statusLabel, cstring(tr("Готово.", "Done.")))
    jobRunning = false
    updateStartButtonLabel()
    gtk_widget_set_sensitive(cast[ptr GtkWidget](w.startButton), cint(1))
    joinThread(procThread)
    timeoutId = 0   # источник уже удаляется GTK через возврат G_SOURCE_REMOVE ниже
    return G_SOURCE_REMOVE

  of phaseError:
    gtk_label_set_text(w.statusLabel, cstring(tr(fmt"Ошибка: {errMsg}", fmt"Error: {errMsg}")))
    jobRunning = false
    updateStartButtonLabel()
    gtk_widget_set_sensitive(cast[ptr GtkWidget](w.startButton), cint(1))
    joinThread(procThread)
    timeoutId = 0
    return G_SOURCE_REMOVE

  of phaseCancelled:
    gtk_label_set_text(w.statusLabel, cstring(tr("Остановлено пользователем.", "Stopped by user.")))
    jobRunning = false
    updateStartButtonLabel()
    gtk_widget_set_sensitive(cast[ptr GtkWidget](w.startButton), cint(1))
    joinThread(procThread)
    timeoutId = 0
    return G_SOURCE_REMOVE

  else:
    return cint(1)

proc onStartStopClicked(btn: ptr GtkButton; userData: pointer) {.cdecl.} =
  if jobRunning:
    # Стоп: просим фоновый поток остановиться на ближайшей проверке между
    # пакетами (см. requestCancel/isCancelRequested в stabilizer.nim) —
    # сам поток аккуратно закроет файлы и завершится сам, onProgressTick
    # заметит phaseCancelled и вернёт кнопку в состояние «Старт». Пока
    # поток не подтвердил остановку, блокируем кнопку от повторных кликов.
    requestCancel()
    gtk_label_set_text(w.statusLabel, cstring(tr("Останавливаем...", "Stopping...")))
    gtk_widget_set_sensitive(cast[ptr GtkWidget](w.startButton), cint(0))
    return

  if len(cfg.inputFile) == 0 or not fileExists(cfg.inputFile):
    gtk_label_set_text(w.statusLabel, cstring(tr("Сначала выберите исходный файл.", "Choose a source file first.")))
    return
  if len(cfg.outputFile) == 0:
    gtk_label_set_text(w.statusLabel, cstring(tr("Укажите, куда сохранить результат.", "Specify where to save the result.")))
    return

  let jobCfg = collectConfig()
  cfg = jobCfg

  jobRunning = true
  updateStartButtonLabel()
  gtk_progress_bar_set_fraction(w.progressBar, 0.0)
  gtk_label_set_text(w.statusLabel, cstring(tr("Запуск...", "Starting...")))

  initStabProgress()
  createThread(procThread, processingThreadProc, jobCfg)
  # Опрос каждые 200мс — то же значение, что использует прогресс-бар PMI
  # для неблокирующей перерисовки терминального прогресса.
  timeoutId = g_timeout_add_wrapper(cuint(200), onProgressTick, nil)

proc onCloseRequest(window: pointer; userData: pointer): cint {.cdecl.} =
  ## GTK4 вызывает это ПЕРЕД реальным закрытием окна. Без этого обработчика
  ## закрытие окна во время работы фонового потока (см. processingThreadProc)
  ## ничего не останавливает: g_application_run() в runApp() просто
  ## вернётся, и выполнение дойдёт до конца main() ещё до того, как поток
  ## аккуратно домучит avio_closep/av_write_trailer — итоговый файл рискует
  ## остаться недописанным и физически повреждённым, а сам поток продолжит
  ## висеть до принудительного завершения процесса ОС. Поэтому здесь мы,
  ## как и по кнопке «Стоп», просим поток остановиться и СИНХРОННО ждём его
  ## завершения (см. finally-блок runStabilization в stabilizer.nim — он
  ## сам уже подчищает недописанный outputFile при отмене), и только потом
  ## разрешаем закрытие — ценой краткой паузы интерфейса.
  if jobRunning:
    requestCancel()
    joinThread(procThread)
    jobRunning = false
  # F-08 из аудита: если окно закрывают, пока таймер прогресса ещё
  # запланирован (job шёл в момент закрытия), явно снимаем источник —
  # раньше timeoutId просто оставался как есть, и при работающем main
  # context (например, из-за повторной активации приложения — см. F-07)
  # таймер мог сработать уже после уничтожения/замены виджетов этого окна.
  if timeoutId != 0:
    discard g_source_remove(timeoutId)
    timeoutId = 0
  w.window = nil  # окно вот-вот будет уничтожено default-обработчиком — не храним dangling pointer
  return cint(0)  # FALSE (GDK_EVENT_PROPAGATE) — разрешить закрытие окна

# ------------------------------------------------------------------------------
# Сборка главного окна
# ------------------------------------------------------------------------------
proc onActivate(app: ptr GtkApplication; userData: pointer) {.cdecl.} =
  # GTK уже вызвал setlocale(LC_ALL, "") на старте g_application_run
  # (нужно ему для переводов интерфейса) — из-за этого в локалях с
  # запятой как десятичным разделителем (ru_RU, de_DE и т.п.) FFmpeg
  # (av_expr/strtod внутри libavutil) перестаёт понимать числа с точкой,
  # которые Nim подставляет в строки фильтр-графов (mincontrast=0.300,
  # zoom=0.00, luma_amount=0.50 и т.д.) — отсюда падение с "Invalid
  # chars '.300' at the end of expression '0.300'". libavutil всегда
  # ожидает "C"-локаль для чисел, поэтому здесь мы откатываем именно
  # LC_NUMERIC обратно в "C" — уже ПОСЛЕ того, как GTK сделал свой
  # setlocale (сделать это раньше, в Monolit.nim, бесполезно: GTK всё
  # равно перезапишет локаль при инициализации). Остальные категории
  # локали (LC_MESSAGES и т.п.) не трогаем — переводы/шрифты GTK не
  # страдают.
  discard c_setlocale(LC_NUMERIC, "C")

  # F-07 из аудита: "org.monolit.app" — уникальный application ID, поэтому
  # повторный запуск обычно не порождает новый процесс, а шлёт "activate"
  # уже работающему — GTK делает это самостоятельно на уровне GApplication.
  # Раньше обработчик каждый раз строил НОВОЕ окно и перезаписывал
  # глобальный w.window, из-за чего старое окно оставалось живо со своими
  # обработчиками сигналов, но читало/писало уже подменённые глобальные
  # cfg/jobRunning/procThread нового окна. Здесь — однооконная модель:
  # если окно уже существует, просто поднимаем его на передний план.
  if w.window != nil:
    gtk_window_present(w.window)
    return

  let window = gtk_application_window_new(app)
  w.window = cast[ptr GtkWindow](window)
  registerTr(proc () = gtk_window_set_title(w.window, cstring(tr(
    fmt"Monolit v{MONOLIT_VERSION} — стабилизация видео",
    fmt"Monolit v{MONOLIT_VERSION} — video stabilization"))))
  gtk_window_set_default_size(w.window, cint(620), cint(560))

  let root = gtk_box_new(GTK_ORIENTATION_VERTICAL, cint(8))
  gtk_widget_set_margin_top(root, cint(8))
  gtk_widget_set_margin_bottom(root, cint(8))
  gtk_widget_set_margin_start(root, cint(8))
  gtk_widget_set_margin_end(root, cint(8))

  let notebook = cast[ptr GtkNotebook](gtk_notebook_new())
  gtk_widget_set_hexpand(cast[ptr GtkWidget](notebook), cint(1))
  gtk_box_append(cast[ptr GtkBox](root), cast[ptr GtkWidget](notebook))

  buildFileTab(notebook)
  buildStabTab(notebook)
  buildSharpenTab(notebook)
  buildCompressionTab(notebook)

  let
    controlRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, cint(12))
    startStopLabel = gtk_label_new(nil)
    startBtn = gtk_button_new()
  gtk_button_set_child(cast[ptr GtkButton](startBtn), startStopLabel)
  w.startButton = cast[ptr GtkButton](startBtn)
  w.startButtonLabel = cast[ptr GtkLabel](startStopLabel)
  registerTr(updateStartButtonLabel)
  connect(cast[pointer](startBtn), "clicked", onStartStopClicked)

  let pbar = gtk_progress_bar_new()
  gtk_progress_bar_set_show_text(cast[ptr GtkProgressBar](pbar), cint(1))
  gtk_widget_set_hexpand(pbar, cint(1))
  w.progressBar = cast[ptr GtkProgressBar](pbar)

  gtk_box_append(cast[ptr GtkBox](controlRow), startBtn)
  gtk_box_append(cast[ptr GtkBox](controlRow), pbar)
  gtk_box_append(cast[ptr GtkBox](root), controlRow)

  let status = gtk_label_new(nil)
  gtk_label_set_xalign(cast[ptr GtkLabel](status), 0.0)
  w.statusLabel = cast[ptr GtkLabel](status)
  registerTr(proc () = gtk_label_set_text(w.statusLabel, cstring(tr("Готово к запуску.", "Ready to start."))))
  gtk_box_append(cast[ptr GtkBox](root), status)

  gtk_window_set_child(w.window, root)
  connect(cast[pointer](w.window), "close-request", onCloseRequest)
  gtk_window_present(w.window)

# ------------------------------------------------------------------------------
# Публичная точка входа — вызывается из Monolit.nim
# ------------------------------------------------------------------------------
proc runApp*(): int =
  ## Создаёт GtkApplication, строит окно по сигналу "activate" и крутит
  ## главный цикл до закрытия окна. Возвращает код завершения приложения.
  let app = gtk_application_new(cstring("org.monolit.app"), G_APPLICATION_DEFAULT_FLAGS)
  connect(cast[pointer](app), "activate", onActivate)
  result = int(g_application_run(cast[ptr GApplication](app), cint(0), nil))
  g_object_unref(cast[pointer](app))
