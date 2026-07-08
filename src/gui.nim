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
import gtk4_api
import stabilizer

const MONOLIT_VERSION* = "1.3"

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
  # этот порядок).
  ENCODE_MODE_ITEMS = ["1 проход (CRF)", "2 прохода (задать битрейт)"]
  ENCODE_MODE_DEFAULT_IDX = 0

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
                                     # текст между "Старт" и "Стоп"
    progressBar:   ptr GtkProgressBar
    statusLabel:   ptr GtkLabel

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
proc labeledRow(box: ptr GtkBox; caption: string; control: ptr GtkWidget) =
  let
    row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12.cint)
    lbl = gtk_label_new(caption.cstring)
  gtk_label_set_xalign(cast[ptr GtkLabel](lbl), 0.0)
  gtk_widget_set_hexpand(lbl, 0.cint)
  gtk_widget_set_hexpand(control, 1.cint)
  gtk_box_append(cast[ptr GtkBox](row), lbl)
  gtk_box_append(cast[ptr GtkBox](row), control)
  gtk_box_append(box, row)

proc newScaleRow(box: ptr GtkBox; caption: string;
                  min, max, step, initial: float; digits: int): ptr GtkRange =
  let scale = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL,
                                        min.cdouble, max.cdouble, step.cdouble)
  gtk_scale_set_digits(cast[ptr GtkScale](scale), digits.cint)
  # Показываем текущее числовое значение прямо на ползунке (справа от
  # него) — стандартный механизм GTK, без отдельного синхронизируемого
  # вручную GtkLabel.
  gtk_scale_set_draw_value(cast[ptr GtkScale](scale), 1.cint)
  gtk_scale_set_value_pos(cast[ptr GtkScale](scale), GTK_POS_RIGHT)
  gtk_range_set_value(cast[ptr GtkRange](scale), initial.cdouble)
  labeledRow(box, caption, scale)
  result = cast[ptr GtkRange](scale)

proc newDropDownRow(box: ptr GtkBox; caption: string;
                     items: openArray[string]; defaultIdx: int): ptr GtkDropDown =
  let dd = newDropDown(items)
  gtk_drop_down_set_selected(cast[ptr GtkDropDown](dd), defaultIdx.cuint)
  labeledRow(box, caption, dd)
  result = cast[ptr GtkDropDown](dd)

# ------------------------------------------------------------------------------
# Хелперы для текста с Pango-разметкой (жирный/курсив). gtk_label_new()
# и gtk_check_button_new_with_label() размечать текст сами не умеют —
# разметка ставится отдельным вызовом gtk_label_set_markup() уже после
# создания виджета, а для чекбокса/кнопки подпись приходится собирать
# вручную как child-виджет вместо параметра label.
# ------------------------------------------------------------------------------
proc newBoldLabel(text: string): ptr GtkWidget =
  result = gtk_label_new(nil)
  gtk_label_set_markup(cast[ptr GtkLabel](result), ("<b>" & text & "</b>").cstring)
  gtk_label_set_xalign(cast[ptr GtkLabel](result), 0.0)

proc newItalicLabel(text: string): ptr GtkWidget =
  result = gtk_label_new(nil)
  gtk_label_set_markup(cast[ptr GtkLabel](result), ("<i>" & text & "</i>").cstring)
  gtk_label_set_xalign(cast[ptr GtkLabel](result), 0.0)

proc newBoldCheckButton(caption: string): ptr GtkWidget =
  result = gtk_check_button_new()
  let lbl = newBoldLabel(caption)
  gtk_check_button_set_child(cast[ptr GtkCheckButton](result), lbl)

proc newBoldButton(caption: string): ptr GtkWidget =
  result = gtk_button_new()
  let lbl = newBoldLabel(caption)
  gtk_button_set_child(cast[ptr GtkButton](result), lbl)

proc newPage(tabTitle: string; notebook: ptr GtkNotebook): ptr GtkBox =
  let page = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8.cint)
  gtk_widget_set_margin_top(page, 12.cint)
  gtk_widget_set_margin_bottom(page, 12.cint)
  gtk_widget_set_margin_start(page, 12.cint)
  gtk_widget_set_margin_end(page, 12.cint)
  discard gtk_notebook_append_page(notebook, page, gtk_label_new(tabTitle.cstring))
  result = cast[ptr GtkBox](page)

# ------------------------------------------------------------------------------
# Вкладка «Файл»
# ------------------------------------------------------------------------------
proc selectedContainerExt(): string =
  ## Расширение (без точки), выбранное в выпадающем списке «Контейнер
  ## результата» на вкладке «Файл» — "mp4" или "mkv".
  CONTAINER_ITEMS[gtk_drop_down_get_selected(w.container).int]

proc onOpenResponse(dialog: pointer; response: cint; userData: pointer) {.cdecl.} =
  if GtkResponseType(response) == GTK_RESPONSE_ACCEPT:
    let file = gtk_file_chooser_get_file(dialog)
    if file != nil:
      let path = g_file_get_path(file)
      if path != nil:
        cfg.inputFile = $path
        gtk_label_set_text(w.inputLabel, cfg.inputFile.cstring)
        if not outputExplicit:
          # По умолчанию сохраняем рядом со входным файлом, пока
          # пользователь явно не укажет другое место через «Куда
          # сохранить...» — после этого outputExplicit=true и
          # автоподстановка больше не трогает выбор (см. onSaveResponse).
          let (dir, _, _) = splitFile(cfg.inputFile)
          let ext = selectedContainerExt()
          cfg.outputFile = (if dir.len > 0: dir / ("stabilized." & ext)
                             else: "stabilized." & ext)
          gtk_label_set_text(w.outputLabel, cfg.outputFile.cstring)
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
        if not outPath.toLowerAscii().endsWith("." & wantExt):
          outPath = changeFileExt(outPath, wantExt)
        cfg.outputFile = outPath
        gtk_label_set_text(w.outputLabel, cfg.outputFile.cstring)
        outputExplicit = true
  gtk_native_dialog_destroy(dialog)

proc onContainerChanged(dd: pointer; pspec: pointer; userData: pointer) {.cdecl.} =
  ## При смене контейнера сразу меняем расширение УЖЕ выбранного пути
  ## сохранения — иначе легко получить mkv-файл с именем output.mp4
  ## просто потому что забыли поправить расширение вручную.
  if cfg.outputFile.len == 0: return
  let wantExt = selectedContainerExt()
  if not cfg.outputFile.toLowerAscii().endsWith("." & wantExt):
    cfg.outputFile = changeFileExt(cfg.outputFile, wantExt)
    gtk_label_set_text(w.outputLabel, cfg.outputFile.cstring)

proc onPickInput(btn: ptr GtkButton; userData: pointer) {.cdecl.} =
  let filt = gtk_file_filter_new()
  gtk_file_filter_set_name(filt, "Видео".cstring)
  for pat in ["*.mp4", "*.mkv", "*.mov", "*.avi", "*.webm"]:
    gtk_file_filter_add_pattern(filt, pat.cstring)
  let dlg = gtk_file_chooser_native_new(
    "Выберите исходное видео".cstring, w.window,
    GTK_FILE_CHOOSER_ACTION_OPEN, "Открыть".cstring, "Отмена".cstring)
  gtk_file_chooser_add_filter(cast[pointer](dlg), filt)
  connect(cast[pointer](dlg), "response", onOpenResponse)
  gtk_native_dialog_show(cast[pointer](dlg))

proc onPickOutput(btn: ptr GtkButton; userData: pointer) {.cdecl.} =
  let ext = selectedContainerExt()
  let dlg = gtk_file_chooser_native_new(
    "Сохранить стабилизированное видео как".cstring, w.window,
    GTK_FILE_CHOOSER_ACTION_SAVE, "Сохранить".cstring, "Отмена".cstring)
  let filt = gtk_file_filter_new()
  gtk_file_filter_set_name(filt, (ext & " видео").cstring)
  gtk_file_filter_add_pattern(filt, ("*." & ext).cstring)
  gtk_file_chooser_add_filter(cast[pointer](dlg), filt)
  gtk_file_chooser_set_current_name(cast[pointer](dlg), ("stabilized." & ext).cstring)
  connect(cast[pointer](dlg), "response", onSaveResponse)
  gtk_native_dialog_show(cast[pointer](dlg))

proc buildFileTab(notebook: ptr GtkNotebook) =
  let page = newPage("Файл", notebook)

  let
    inRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12.cint)
    inBtn = gtk_button_new_with_label("Выбрать исходное видео...".cstring)
  w.inputLabel = cast[ptr GtkLabel](gtk_label_new(cfg.inputFile.cstring))
  gtk_label_set_xalign(w.inputLabel, 0.0)
  gtk_widget_set_hexpand(cast[ptr GtkWidget](w.inputLabel), 1.cint)
  connect(cast[pointer](inBtn), "clicked", onPickInput)
  gtk_box_append(cast[ptr GtkBox](inRow), inBtn)
  gtk_box_append(cast[ptr GtkBox](inRow), cast[ptr GtkWidget](w.inputLabel))
  gtk_box_append(page, inRow)

  let
    outRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12.cint)
    outBtn = gtk_button_new_with_label("Куда сохранить...".cstring)
  w.outputLabel = cast[ptr GtkLabel](gtk_label_new(cfg.outputFile.cstring))
  gtk_label_set_xalign(w.outputLabel, 0.0)
  gtk_widget_set_hexpand(cast[ptr GtkWidget](w.outputLabel), 1.cint)
  connect(cast[pointer](outBtn), "clicked", onPickOutput)
  gtk_box_append(cast[ptr GtkBox](outRow), outBtn)
  gtk_box_append(cast[ptr GtkBox](outRow), cast[ptr GtkWidget](w.outputLabel))
  gtk_box_append(page, outRow)

  w.container = newDropDownRow(page, "Контейнер результата",
                                CONTAINER_ITEMS, CONTAINER_DEFAULT_IDX)
  connect(cast[pointer](w.container), "notify::selected", onContainerChanged)
  let containerNote = newItalicLabel(
    "mkv надёжнее сохраняет субтитры и вложения (шрифты); mp4 — самый\n" &
    "совместимый вариант для проигрывателей и сайтов. Расширение файла\n" &
    "в диалоге «Куда сохранить...» подставляется по этому выбору.")
  gtk_widget_set_margin_bottom(containerNote, 6.cint)
  gtk_box_append(page, containerNote)

  let audioChk = gtk_check_button_new_with_label("Копировать звук без перекодирования".cstring)
  gtk_check_button_set_active(cast[ptr GtkCheckButton](audioChk), 1.cint)
  w.copyAudio = cast[ptr GtkCheckButton](audioChk)
  gtk_box_append(page, audioChk)

  # Раньше субтитры копировались автоматически вместе со звуком (одним
  # флагом copyAudio на оба типа потоков) — теперь это два независимых
  # переключателя: можно, например, сохранить звук, но выкинуть субтитры,
  # или наоборот.
  let subsChk = gtk_check_button_new_with_label("Сохранить субтитры".cstring)
  gtk_check_button_set_active(cast[ptr GtkCheckButton](subsChk), 1.cint)
  w.saveSubtitles = cast[ptr GtkCheckButton](subsChk)
  gtk_box_append(page, subsChk)

  # "Вложения" контейнера — это, как правило, встроенные в mkv шрифты
  # (нужны для корректного отображения стилизованных субтитров ASS/SSA)
  # и другие произвольные файлы, которые можно прикрепить к mkv-контейнеру.
  let attachChk = gtk_check_button_new_with_label("Сохранить вложения (шрифты и т.п.)".cstring)
  gtk_check_button_set_active(cast[ptr GtkCheckButton](attachChk), 1.cint)
  w.saveAttachments = cast[ptr GtkCheckButton](attachChk)
  gtk_box_append(page, attachChk)

# ------------------------------------------------------------------------------
# Вкладка «Стабилизация»
# ------------------------------------------------------------------------------
proc buildStabTab(notebook: ptr GtkNotebook) =
  let page = newPage("Стабилизация", notebook)

  let hdr1 = newBoldLabel("Проход 1 — анализ движения (vidstabdetect)")
  gtk_box_append(page, hdr1)

  w.shakiness   = newScaleRow(page, "Резкость тряски (shakiness)",   1, 10, 1, 10, 0)
  w.accuracy    = newScaleRow(page, "Точность анализа (accuracy)",    1, 15, 1, 15, 0)
  w.stepsize    = newScaleRow(page, "Шаг поиска (stepsize)",          1, 32, 1, 1,  0)
  w.mincontrast = newScaleRow(page, "Мин. контраст (mincontrast)",    0.0, 1.0, 0.05, 0.3, 2)

  let hdr2 = newBoldLabel("Проход 2 — компенсация (vidstabtransform)")
  gtk_widget_set_margin_top(hdr2, 12.cint)
  gtk_box_append(page, hdr2)

  w.smoothing = newScaleRow(page, "Сглаживание (кадров)", 0, 200, 1, 30, 0)
  w.zoom      = newScaleRow(page, "Базовый зум, %",       0, 50,  1, 0,  0)
  w.optzoom   = newDropDownRow(page, "Автозум (optzoom): 0=выкл 1=статич. 2=адаптивн.",
                                ["0", "1", "2"], 2)
  w.crop      = newDropDownRow(page, "Края кадра (crop)", CROP_ITEMS, CROP_DEFAULT_IDX)
  w.interpol  = newDropDownRow(page, "Интерполяция (interpol)", INTERPOL_ITEMS,
                                INTERPOL_DEFAULT_IDX)
  w.maxShift  = newScaleRow(page, "Макс. сдвиг, px (-1 = без ограничения)",
                             -1, 500, 1, -1, 0)
  w.maxAngle  = newScaleRow(page, "Макс. угол, рад (-1 = без ограничения)",
                             -1, 3, 0.05, -1, 2)

  let note = newItalicLabel(
    "«Чёрные поля» = crop=black; вариант «keep» дотягивает картинку\n" &
    "с предыдущего кадра вместо чёрной рамки.")
  gtk_widget_set_margin_top(note, 6.cint)
  gtk_box_append(page, note)

# ------------------------------------------------------------------------------
# Вкладка «Резкость»
# ------------------------------------------------------------------------------
# Три чекбокса-фильтра (Smart Blur/unsharp/CAS) взаимно исключают друг
# друга — см. пояснение в buildSharpenTab ниже. Один обработчик подключён
# сразу к "toggled" всех трёх; при включении любого из них он гасит два
# остальных, а при выключении (галочку сняли) ничего не трогает — так
# допустимо состояние "все три выключены" (резкость не применяется вовсе).
proc onFilterToggled(cb: ptr GtkCheckButton; userData: pointer) {.cdecl.} =
  if gtk_check_button_get_active(cb) == 0:
    return
  if cb != w.smartblurEnabled: gtk_check_button_set_active(w.smartblurEnabled, 0.cint)
  if cb != w.sharpenEnabled:   gtk_check_button_set_active(w.sharpenEnabled, 0.cint)
  if cb != w.casEnabled:       gtk_check_button_set_active(w.casEnabled, 0.cint)

proc buildSharpenTab(notebook: ptr GtkNotebook) =
  let page = newPage("Резкость", notebook)

  # --- smartblur: опциональное шумоподавление/смягчение ---------------------
  let sbChk = newBoldCheckButton(
    "Применить Smart Blur (smartblur) — шумоподавление/смягчение")
  w.smartblurEnabled = cast[ptr GtkCheckButton](sbChk)
  gtk_box_append(page, sbChk)

  w.smartblurRadius    = newScaleRow(page, "Радиус (luma_radius)",    0.1, 5.0, 0.1, 1.0, 1)
  w.smartblurStrength  = newScaleRow(page, "Сила (luma_strength)",   -1.0, 1.0, 0.05, 1.0, 2)
  w.smartblurThreshold = newScaleRow(page, "Порог (luma_threshold)", -30, 30, 1, 0, 0)

  let sbNote = newItalicLabel(
    "Smart Blur ставится ПЕРЕД фильтрами резкости ниже: резкость усиливает\n" &
    "уже имеющийся шум, поэтому шумоподавление имеет смысл делать раньше.")
  gtk_widget_set_margin_top(sbNote, 6.cint)
  gtk_widget_set_margin_bottom(sbNote, 6.cint)
  gtk_box_append(page, sbNote)

  # --- unsharp: классическая резкость ----------------------------------------
  let chk = newBoldCheckButton("Повысить резкость после стабилизации (unsharp)")
  w.sharpenEnabled = cast[ptr GtkCheckButton](chk)
  gtk_box_append(page, chk)

  w.sharpenAmount = newScaleRow(page, "Сила резкости (luma_amount)", 0.0, 3.0, 0.1, 0.5, 2)

  # --- cas: Contrast Adaptive Sharpening -------------------------------------
  let casChk = newBoldCheckButton("Применить Contrast Adaptive Sharpening (cas)")
  w.casEnabled = cast[ptr GtkCheckButton](casChk)
  gtk_widget_set_margin_top(casChk, 6.cint)
  # По умолчанию включаем именно cas: из трёх фильтров резкости он меньше
  # всего «звенит» на контрастных краях (см. заметку ниже), поэтому это
  # наиболее безопасный/качественный выбор "из коробки". Устанавливаем
  # активным ДО connect(...) ниже, чтобы не спровоцировать одноразовый
  # холостой вызов onFilterToggled при старте.
  gtk_check_button_set_active(cast[ptr GtkCheckButton](casChk), 1.cint)
  gtk_box_append(page, casChk)

  w.casStrength = newScaleRow(page, "Сила (strength)", 0.0, 1.0, 0.05, 0.7, 2)

  # Три фильтра исключают друг друга: одновременное включение двух-трёх из
  # них, по всей видимости, лишено смысла (каждый по-своему борется с
  # резкостью/шумом кадра, и их эффекты только мешали бы друг другу).
  # Поэтому включение любого из трёх сразу выключает два других — см.
  # onFilterToggled, подключённый ниже одним обработчиком на все три.
  connect(cast[pointer](sbChk),   "toggled", onFilterToggled)
  connect(cast[pointer](chk),     "toggled", onFilterToggled)
  connect(cast[pointer](casChk),  "toggled", onFilterToggled)

  let note = newItalicLabel(
    "Резкость (unsharp/cas) применяется ПОСЛЕ стабилизации/зума — иначе\n" &
    "усиливаются артефакты исходной тряски вместо деталей кадра. Включить\n" &
    "можно только один из трёх фильтров — cas меньше «звенит» на\n" &
    "контрастных краях, чем классический unsharp.")
  gtk_widget_set_margin_top(note, 6.cint)
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
  let isTwoPass = gtk_drop_down_get_selected(cast[ptr GtkDropDown](dd)) == 1.cuint
  gtk_widget_set_sensitive(cast[ptr GtkWidget](w.crf), (not isTwoPass).cint)
  gtk_widget_set_sensitive(cast[ptr GtkWidget](w.videoBitrate), isTwoPass.cint)

proc buildCompressionTab(notebook: ptr GtkNotebook) =
  let page = newPage("Компрессия", notebook)

  w.encodeMode = newDropDownRow(page, "Режим сжатия", ENCODE_MODE_ITEMS,
                                 ENCODE_MODE_DEFAULT_IDX)
  connect(cast[pointer](w.encodeMode), "notify::selected", onEncodeModeChanged)

  w.preset = newDropDownRow(page, "Preset libx264", PRESET_ITEMS, PRESET_DEFAULT_IDX)
  w.crf    = newScaleRow(page, "CRF (0=без потерь, 51=худшее качество)", 0, 51, 1, 16, 0)
  w.videoBitrate = newScaleRow(page, "Целевой битрейт видео, кбит/с",
                                500, 50000, 100, 8000, 0)

  # По умолчанию выбран режим "1 проход (CRF)" — битрейт в нём не участвует
  # в кодировании вообще, поэтому сразу блокируем ползунок, чтобы не вводить
  # в заблуждение (актуальное состояние поддерживается onEncodeModeChanged).
  gtk_widget_set_sensitive(cast[ptr GtkWidget](w.videoBitrate), 0.cint)

  # Курсив + два отдельных виджета вместо одного текстового блока: между
  # предложениями нужен явный вертикальный отступ, а не просто перенос
  # строки внутри одной подписи — margin_top у второго абзаца и даёт этот
  # "вертикальный пробел".
  let noteCRF = newItalicLabel(
    "«1 проход (CRF)» — постоянное качество на всём ролике; быстрее, но\n" &
    "итоговый размер файла заранее не предсказать. Для «наивысшего\n" &
    "качества» — preset=slow/slower и CRF 16-18.")
  gtk_widget_set_margin_top(noteCRF, 6.cint)
  gtk_box_append(page, noteCRF)

  let note2Pass = newItalicLabel(
    "«2 прохода (битрейт)» — libx264 сначала проходит весь ролик, считая\n" &
    "статистику сложности сцен, затем кодирует повторно, распределяя биты\n" &
    "так, чтобы точно попасть в заданный битрейт/размер файла — вдвое\n" &
    "медленнее, зато предсказуемый результат.")
  gtk_widget_set_margin_top(note2Pass, 10.cint)   # вертикальный пробел между абзацами
  gtk_box_append(page, note2Pass)

# ------------------------------------------------------------------------------
# Считать значения со всех виджетов в StabConfig непосредственно перед стартом
# ------------------------------------------------------------------------------
proc collectConfig(): StabConfig =
  result = cfg   # inputFile/outputFile уже выставлены обработчиками выбора файла
  result.shakiness   = int(gtk_range_get_value(w.shakiness))
  result.accuracy    = int(gtk_range_get_value(w.accuracy))
  result.stepsize    = int(gtk_range_get_value(w.stepsize))
  result.mincontrast = gtk_range_get_value(w.mincontrast).float

  result.smoothing = int(gtk_range_get_value(w.smoothing))
  result.zoom      = gtk_range_get_value(w.zoom).float
  result.optzoom   = int(gtk_drop_down_get_selected(w.optzoom))
  result.crop      = CropMode(gtk_drop_down_get_selected(w.crop).int)
  result.interpol  = InterpolMode(gtk_drop_down_get_selected(w.interpol).int)
  result.maxShift  = int(gtk_range_get_value(w.maxShift))
  result.maxAngle  = gtk_range_get_value(w.maxAngle).float

  result.sharpenEnabled = gtk_check_button_get_active(w.sharpenEnabled) != 0
  result.sharpenAmount  = gtk_range_get_value(w.sharpenAmount).float

  result.smartblurEnabled   = gtk_check_button_get_active(w.smartblurEnabled) != 0
  result.smartblurRadius    = gtk_range_get_value(w.smartblurRadius).float
  result.smartblurStrength  = gtk_range_get_value(w.smartblurStrength).float
  result.smartblurThreshold = gtk_range_get_value(w.smartblurThreshold).float

  result.casEnabled  = gtk_check_button_get_active(w.casEnabled) != 0
  result.casStrength = gtk_range_get_value(w.casStrength).float

  result.preset     = PRESET_ITEMS[gtk_drop_down_get_selected(w.preset).int]
  # Индекс 0 = "1 проход (CRF)" = emCRF, индекс 1 = "2 прохода" = emBitrate2Pass
  # (см. ENCODE_MODE_ITEMS выше — порядок жёстко согласован с EncodeMode).
  result.encodeMode = if gtk_drop_down_get_selected(w.encodeMode) == 0.cuint:
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

proc onProgressTick(userData: pointer): cint {.cdecl.} =
  let (phase, done, total, errMsg) = getStabProgress()

  case phase
  of phaseAnalyze:
    let frac = if total > 0: min(1.0, done.float / total.float) else: 0.0
    gtk_progress_bar_set_fraction(w.progressBar, frac.cdouble)
    gtk_label_set_text(w.statusLabel,
      fmt"Проход 1/2 — анализ движения: {done}/{total} кадров".cstring)
    return 1.cint   # G_SOURCE_CONTINUE — таймер продолжает тикать

  of phaseEncodePass1:
    let frac = if total > 0: min(1.0, done.float / total.float) else: 0.0
    gtk_progress_bar_set_fraction(w.progressBar, frac.cdouble)
    gtk_label_set_text(w.statusLabel,
      fmt"Кодирование, проход A/2 — сбор статистики битрейта: {done}/{total} кадров".cstring)
    return 1.cint

  of phaseTransform:
    let frac = if total > 0: min(1.0, done.float / total.float) else: 0.0
    gtk_progress_bar_set_fraction(w.progressBar, frac.cdouble)
    gtk_label_set_text(w.statusLabel,
      fmt"Проход 2/2 — стабилизация и кодирование: {done}/{total} кадров".cstring)
    return 1.cint

  of phaseDone:
    gtk_progress_bar_set_fraction(w.progressBar, 1.0)
    gtk_label_set_text(w.statusLabel, "Готово.".cstring)
    jobRunning = false
    gtk_label_set_text(w.startButtonLabel, "Старт".cstring)
    gtk_widget_set_sensitive(cast[ptr GtkWidget](w.startButton), 1.cint)
    joinThread(procThread)
    return G_SOURCE_REMOVE

  of phaseError:
    gtk_label_set_text(w.statusLabel, fmt"Ошибка: {errMsg}".cstring)
    jobRunning = false
    gtk_label_set_text(w.startButtonLabel, "Старт".cstring)
    gtk_widget_set_sensitive(cast[ptr GtkWidget](w.startButton), 1.cint)
    joinThread(procThread)
    return G_SOURCE_REMOVE

  of phaseCancelled:
    gtk_label_set_text(w.statusLabel, "Остановлено пользователем.".cstring)
    jobRunning = false
    gtk_label_set_text(w.startButtonLabel, "Старт".cstring)
    gtk_widget_set_sensitive(cast[ptr GtkWidget](w.startButton), 1.cint)
    joinThread(procThread)
    return G_SOURCE_REMOVE

  else:
    return 1.cint

proc onStartStopClicked(btn: ptr GtkButton; userData: pointer) {.cdecl.} =
  if jobRunning:
    # Стоп: просим фоновый поток остановиться на ближайшей проверке между
    # пакетами (см. requestCancel/isCancelRequested в stabilizer.nim) —
    # сам поток аккуратно закроет файлы и завершится сам, onProgressTick
    # заметит phaseCancelled и вернёт кнопку в состояние «Старт». Пока
    # поток не подтвердил остановку, блокируем кнопку от повторных кликов.
    requestCancel()
    gtk_label_set_text(w.statusLabel, "Останавливаем...".cstring)
    gtk_widget_set_sensitive(cast[ptr GtkWidget](w.startButton), 0.cint)
    return

  if cfg.inputFile.len == 0 or not fileExists(cfg.inputFile):
    gtk_label_set_text(w.statusLabel, "Сначала выберите исходный файл.".cstring)
    return
  if cfg.outputFile.len == 0:
    gtk_label_set_text(w.statusLabel, "Укажите, куда сохранить результат.".cstring)
    return

  let jobCfg = collectConfig()
  cfg = jobCfg

  jobRunning = true
  gtk_label_set_text(w.startButtonLabel, "Стоп".cstring)
  gtk_progress_bar_set_fraction(w.progressBar, 0.0)
  gtk_label_set_text(w.statusLabel, "Запуск...".cstring)

  initStabProgress()
  createThread(procThread, processingThreadProc, jobCfg)
  # Опрос каждые 200мс — то же значение, что использует прогресс-бар PMI
  # для неблокирующей перерисовки терминального прогресса.
  timeoutId = g_timeout_add_wrapper(200.cuint, onProgressTick, nil)

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

  let window = gtk_application_window_new(app)
  w.window = cast[ptr GtkWindow](window)
  gtk_window_set_title(w.window, fmt"Monolit v{MONOLIT_VERSION} — стабилизация видео".cstring)
  gtk_window_set_default_size(w.window, 620.cint, 560.cint)

  let root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8.cint)
  gtk_widget_set_margin_top(root, 8.cint)
  gtk_widget_set_margin_bottom(root, 8.cint)
  gtk_widget_set_margin_start(root, 8.cint)
  gtk_widget_set_margin_end(root, 8.cint)

  let notebook = cast[ptr GtkNotebook](gtk_notebook_new())
  gtk_widget_set_hexpand(cast[ptr GtkWidget](notebook), 1.cint)
  gtk_box_append(cast[ptr GtkBox](root), cast[ptr GtkWidget](notebook))

  buildFileTab(notebook)
  buildStabTab(notebook)
  buildSharpenTab(notebook)
  buildCompressionTab(notebook)

  let
    controlRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12.cint)
    startStopLabel = newBoldLabel("Старт")
    startBtn = gtk_button_new()
  gtk_button_set_child(cast[ptr GtkButton](startBtn), startStopLabel)
  w.startButton = cast[ptr GtkButton](startBtn)
  w.startButtonLabel = cast[ptr GtkLabel](startStopLabel)
  connect(cast[pointer](startBtn), "clicked", onStartStopClicked)

  let pbar = gtk_progress_bar_new()
  gtk_progress_bar_set_show_text(cast[ptr GtkProgressBar](pbar), 1.cint)
  gtk_widget_set_hexpand(pbar, 1.cint)
  w.progressBar = cast[ptr GtkProgressBar](pbar)

  gtk_box_append(cast[ptr GtkBox](controlRow), startBtn)
  gtk_box_append(cast[ptr GtkBox](controlRow), pbar)
  gtk_box_append(cast[ptr GtkBox](root), controlRow)

  let status = gtk_label_new("Готово к запуску.".cstring)
  gtk_label_set_xalign(cast[ptr GtkLabel](status), 0.0)
  w.statusLabel = cast[ptr GtkLabel](status)
  gtk_box_append(cast[ptr GtkBox](root), status)

  gtk_window_set_child(w.window, root)
  gtk_window_present(w.window)

# ------------------------------------------------------------------------------
# Публичная точка входа — вызывается из Monolit.nim
# ------------------------------------------------------------------------------
proc runApp*(): int =
  ## Создаёт GtkApplication, строит окно по сигналу "activate" и крутит
  ## главный цикл до закрытия окна. Возвращает код завершения приложения.
  let app = gtk_application_new("org.monolit.app".cstring, G_APPLICATION_DEFAULT_FLAGS)
  connect(cast[pointer](app), "activate", onActivate)
  result = g_application_run(cast[ptr GApplication](app), 0.cint, nil).int
  g_object_unref(cast[pointer](app))
