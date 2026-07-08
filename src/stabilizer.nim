# ==============================================================================
#  stabilizer.nim  — двухпроходная стабилизация видео через libvidstab  (v1)
#
#  АРХИТЕКТУРНОЕ ОТЛИЧИЕ ОТ PMI:
#  PMI режет видео на независимые сегменты и интерполирует их ПАРАЛЛЕЛЬНО
#  в отдельных потоках ОС, потому что minterpolate — локальный фильтр
#  (кадру нужно только несколько соседних кадров). vid.stab устроен
#  принципиально иначе: vidstabdetect накапливает ГЛОБАЛЬНУЮ историю
#  движения камеры по ВСЕМУ ролику и лишь потом (во втором проходе)
#  vidstabtransform сглаживает эту траекторию с учётом кадров и до, и
#  после текущего. Если резать видео на куски и гонять их параллельно,
#  каждый кусок получит свою, никак не связанную с соседями траекторию —
#  на стыках сегментов появятся видимые рывки, и вся идея стабилизации
#  обесценивается. Поэтому Monolit сознательно НЕ повторяет
#  segment-parallel модель PMI: оба прохода идут по видео целиком,
#  последовательно. Параллелизм при этом никуда не делся — он просто
#  переехал на уровень ниже: декодер/энкодер/фильтр-граф используют
#  многопоточность самого FFmpeg (thread_count/thread_type, см. ниже),
#  как и в PMI, а сама сборка GUI-приложения остаётся асинхронной —
#  вся обработка идёт в отдельном потоке ОС, чтобы не блокировать
#  GTK-цикл событий (см. Monolit.nim).
#
#  ПРОХОД 1 (detect):  decode → buffer → vidstabdetect → buffersink
#    Кадры не кодируются и не пишутся — vidstabdetect анализирует
#    межкадровое движение и накапливает его в файл транформаций
#    (result=...trf). Файл фактически дозаписывается фильтром при
#    его освобождении (avfilter_graph_free) — поэтому граф ОБЯЗАН быть
#    корректно закрыт по завершении прохода, что гарантирует defer.
#
#  ПРОХОД 2 (transform): decode → buffer → vidstabtransform[,unsharp]
#                         → buffersink → encode(libx264) → mux
#    vidstabtransform читает тот же .trf и сглаживает траекторию
#    (smoothing), при необходимости зумирует кадр, чтобы скрыть
#    смещение (zoom/optzoom), либо оставляет чёрные поля (crop=keep).
#    Аудио- и субтитровые потоки не декодируются — копируются "как
#    есть" (stream copy), как в PMI/concat.nim.
# ==============================================================================

import std/[strformat, strutils, os]
import ffmpeg_api

# ------------------------------------------------------------------------------
# Публичная конфигурация — один-в-один соответствует вкладкам GUI в Monolit.nim
# ------------------------------------------------------------------------------
type
  InterpolMode* = enum
    interpNone = "no", interpLinear = "linear", interpBilinear = "bilinear",
    interpBicubic = "bicubic"

  CropMode* = enum
    # "keep" — вместо чёрной рамки по краю vidstabtransform дотягивает
    # (staleness/дублирует) картинку с предыдущего кадра, поэтому рамка
    # не чёрная, а "смазанная" продолжением предыдущего кадра.
    cropKeep = "keep"
    # "black" — реальные чёрные поля по краям кадра там, где после
    # компенсации тряски не хватает исходного изображения.
    cropBlack = "black"

  EncodeMode* = enum
    ## Режим управления битрейтом энкодера libx264 (вкладка «Компрессия»).
    emCRF          = "crf"    # 1 проход: постоянное качество (CRF), размер файла заранее неизвестен
    emBitrate2Pass = "2pass"  # 2 прохода: точное попадание в заданный целевой битрейт/размер файла

  StabConfig* = object
    inputFile*:    string
    outputFile*:   string
    tempDir*:      string      # куда пишется файл transforms.trf
    copyAudio*:    bool
    saveSubtitles*:   bool     # копировать субтитровые потоки "как есть"
    saveAttachments*: bool     # копировать вложения контейнера (шрифты и т.п.)

    # --- Проход 1: vidstabdetect (анализ движения) ---
    shakiness*:    int         # 1..10, выше — сильнее анализ мелкой тряски
    accuracy*:     int         # 1..15, выше — точнее (и медленнее) анализ
    stepsize*:     int         # шаг поиска локального минимума, обычно 6
    mincontrast*:  float       # 0..1, порог отбраковки областей без контраста

    # --- Проход 2: vidstabtransform (компенсация) ---
    smoothing*:    int         # окно сглаживания траектории (кадров)
    zoom*:         float       # базовый зум, %; 0 = без принудительного зума
    optzoom*:      int         # 0=выкл,1=статичный оптимальный,2=адаптивный
    crop*:         CropMode    # keep=дотянуть с предыдущего кадра; black=чёрные поля
    interpol*:     InterpolMode
    maxShift*:     int         # -1 = без ограничения (px)
    maxAngle*:     float       # -1 = без ограничения (радианы)

    # --- Резкость/шумоподавление (опционально, применяются ПОСЛЕ стабилизации) ---
    sharpenEnabled*: bool
    sharpenAmount*:  float     # 0.0..3.0, передаётся в unsharp luma_amount

    smartblurEnabled*:   bool
    smartblurRadius*:    float  # 0.1..5.0 — luma_radius (lr)
    smartblurStrength*:  float  # -1.0..1.0 — luma_strength (ls); отрицательное = блюр наоборот (резче)
    smartblurThreshold*: float  # -30..30 — luma_threshold (lt)

    casEnabled*:   bool
    casStrength*:  float       # 0.0..1.0 — сила Contrast Adaptive Sharpening

    # --- Компрессия ---
    preset*:       string      # x264 preset: ultrafast..veryslow
    encodeMode*:   EncodeMode  # emCRF (1 проход) | emBitrate2Pass (2 прохода)
    crf*:          int         # 0..51, ниже — лучше качество/больше размер; только для emCRF
    videoBitrateKbps*: int     # целевой битрейт видео, кбит/с; только для emBitrate2Pass

proc defaultStabConfig*(): StabConfig =
  ## Значения по умолчанию — максимальное качество ЛЮБОЙ ценой скорости:
  ## два прохода, максимально точный анализ (accuracy=15) с самым мелким
  ## шагом поиска (stepsize=1 — самый исчерпывающий, а не "стандартный
  ## 6"), адаптивный зум, бикубическая интерполяция, самый медленный/
  ## качественный x264-пресет (slow) при CRF=16 (почти неотличимо от
  ## оригинала) и включённый по умолчанию cas — из трёх фильтров резкости
  ## он меньше всего "звенит" на контрастных краях, то есть безопаснее
  ## всего в качестве "включено из коробки".
  StabConfig(
    inputFile:      "input.mp4",
    outputFile:     "output.mp4",
    tempDir:        "",
    copyAudio:      true,
    saveSubtitles:    true,
    saveAttachments:  true,
    shakiness:      10,
    accuracy:       15,
    stepsize:       1,
    mincontrast:    0.3,
    smoothing:      30,
    zoom:           0.0,
    optzoom:        2,
    crop:           cropKeep,
    interpol:       interpBicubic,
    maxShift:       -1,
    maxAngle:       -1.0,
    sharpenEnabled: false,
    sharpenAmount:  0.5,
    smartblurEnabled:   false,
    smartblurRadius:    1.0,
    smartblurStrength:  1.0,
    smartblurThreshold: 0.0,
    casEnabled:     true,
    casStrength:    0.7,
    preset:         "slow",
    encodeMode:     emCRF,
    crf:            16,
    videoBitrateKbps: 8000)

# ------------------------------------------------------------------------------
# Прогресс — та же идея, что progressBuf в PMI/worker.nim: фоновый поток
# пишет только в shared-память, GTK-поток читает её из g_idle_add колбэка
# (см. Monolit.nim). Здесь всего один "воркер" (не N сегментов, как в
# PMI), поэтому вместо массива — просто счётчики двух фаз плюс общий
# ожидаемый объём кадров для оценки процента.
# ------------------------------------------------------------------------------
const ERR_BUF_LEN = 256

type
  StabPhase* = enum
    phaseIdle, phaseAnalyze, phaseEncodePass1, phaseTransform, phaseDone,
    phaseError, phaseCancelled
    # phaseEncodePass1 — только для emBitrate2Pass: первый (статистический)
    # проход кодирования, вывод отбрасывается, пишется лишь лог x264

  # ВАЖНО: НИКАКИХ GC-управляемых полей (string/seq/ref) здесь быть не
  # должно — ProgressState живёт в allocShared-памяти вне поля зрения
  # GC/ORC, как и progressBuf в PMI/worker.nim (см. комментарий там же).
  # string внутри такой памяти — источник утечек/повреждений: `=destroy`
  # для него никогда не вызывается, а `=copy` ожидает корректно
  # инициализированный GC-объект по месту записи. Поэтому сообщение об
  # ошибке хранится как обычный fixed-size буфер байт, без хуков GC.
  ProgressState = object
    phase:          StabPhase
    framesDone:     int64
    framesTotal:    int64
    errLen:         int
    errBuf:         array[ERR_BUF_LEN, char]
    cancelRequested: bool   # выставляется из GTK-потока по кнопке «Стоп»,
                            # проверяется фоновым потоком между пакетами —
                            # см. requestCancel/isCancelRequested ниже

  StabCancelledError* = object of CatchableError
    ## Поднимается изнутри циклов чтения пакетов (см. runDetectPass/
    ## runTransformPass), когда пользователь нажал «Стоп». Отдельный тип
    ## нужен, чтобы runStabilization мог отличить осознанную остановку от
    ## настоящей ошибки — разный текст статуса и разная судьба недописанного
    ## выходного файла.

var progress: ptr ProgressState

proc initStabProgress*() =
  if progress != nil: deallocShared(progress)
  progress = cast[ptr ProgressState](allocShared0(sizeof(ProgressState)))
  progress.phase = phaseIdle

proc freeStabProgress*() =
  if progress != nil:
    deallocShared(progress)
    progress = nil

proc getStabProgress*(): (StabPhase, int64, int64, string) {.gcsafe.} =
  if progress == nil: return (phaseIdle, 0'i64, 0'i64, "")
  var msg = newString(progress.errLen)
  for i in 0 ..< progress.errLen: msg[i] = progress.errBuf[i]
  result = (progress.phase, progress.framesDone, progress.framesTotal, msg)

proc setPhase(p: StabPhase; total: int64 = 0) {.gcsafe.} =
  if progress == nil: return
  progress.phase = p
  progress.framesDone = 0
  if total > 0: progress.framesTotal = total

proc bumpProgress() {.inline, gcsafe.} =
  if progress != nil: inc progress.framesDone

proc setError(msg: string) {.gcsafe.} =
  if progress == nil: return
  progress.phase = phaseError
  progress.errLen = min(len(msg), ERR_BUF_LEN - 1)
  for i in 0 ..< progress.errLen: progress.errBuf[i] = msg[i]

proc requestCancel*() {.gcsafe.} =
  ## Вызывается из GTK-потока по клику на «Стоп». Сам фоновый поток
  ## останавливается не мгновенно — только на ближайшей проверке
  ## isCancelRequested() между пакетами (см. оба цикла чтения ниже),
  ## чтобы гарантированно выйти из декодера/фильтра/энкодера аккуратно,
  ## а не оборвать процесс на полуслове.
  if progress != nil: progress.cancelRequested = true

proc isCancelRequested(): bool {.inline, gcsafe.} =
  progress != nil and progress.cancelRequested

# ------------------------------------------------------------------------------
# Общие мелочи для обоих проходов
# ------------------------------------------------------------------------------
proc transformFilePath(cfg: StabConfig): string =
  let dir = if len(cfg.tempDir) > 0: cfg.tempDir else: getTempDir()
  dir / "monolit_transforms.trf"

{.emit: """
/* monolit_sw_only_get_format — см. openDecoderFor в этом же файле (.nim).
 * Декодер (например av1) предлагает список форматов, начинающийся с
 * аппаратных (hwaccel) вариантов. Штатный get_format по умолчанию
 * пробует их по очереди и должен тихо откатиться на программный
 * формат, если ни один не подошёл — но на некоторых системах вместо
 * отката декодирование целиком проваливается ("Failed to get pixel
 * format", "Get current frame error"). Поэтому здесь мы сразу и
 * однозначно выбираем ПЕРВЫЙ программный (не-hwaccel) формат из
 * списка, минуя hwaccel-согласование вообще.
 *
 * Написано как чистый C, а не выведено из Nim: три попытки повторить
 * сигнатуру AVCodecContext.get_format средствами Nim (distinct cint,
 * отдельный importc-тип под "enum AVPixelFormat", отдельный тип под
 * "const enum AVPixelFormat*") каждый раз давали немного другую
 * C-сигнатуру, чем в реальном заголовке — а GCC 14+ считает такое
 * несовпадение указателей на функцию жёсткой ошибкой компиляции, а не
 * предупреждением. Здесь сигнатура прописана буква-в-букву руками, как
 * в libavcodec/avcodec.h, поэтому вопрос совместимости типов снят.
 */
#include <libavcodec/avcodec.h>
#include <libavutil/pixdesc.h>

static enum AVPixelFormat monolit_sw_only_get_format(struct AVCodecContext *ctx,
                                                      const enum AVPixelFormat *fmts) {
  const enum AVPixelFormat *p;
  for (p = fmts; *p != AV_PIX_FMT_NONE; p++) {
    const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(*p);
    if (!d || !(d->flags & AV_PIX_FMT_FLAG_HWACCEL))
      return *p;
  }
  return fmts[0];  /* ничего программного не нашли — отдаём то, что предложили первым */
}
""".}

proc openDecoderFor(fmtCtx: ptr AVFormatContext; streamIdx: cint;
                     threads: int): ptr AVCodecContext =
  let stream = fmtCtx.streams[streamIdx]
  var codec: ptr AVCodec = nil
  # Для AV1 явно предпочитаем libdav1d, а не родной декодер FFmpeg "av1":
  # именно родной декодер печатает "Failed to get pixel format" / "Your
  # platform doesn't support hardware accelerated AV1 decoding" даже там,
  # где это не имеет отношения к делу (это подтверждённая, известная
  # шероховатость самого FFmpeg — наш собственный get_format ниже её не
  # убирает полностью). dav1d — чисто программный декодер, у него в
  # принципе нет кода для hwaccel-согласования, поэтому весь этот класс
  # проблем снимается целиком. Если по какой-то причине libdav1d не
  # скомпилирован в этой сборке FFmpeg, тихо откатываемся на обычный
  # поиск декодера по codec_id — на остальных кодеках ничего не меняется.
  if stream.codecpar.codec_id == AV_CODEC_ID_AV1:
    codec = avcodec_find_decoder_by_name("libdav1d")
  if codec == nil:
    codec = avcodec_find_decoder(stream.codecpar.codec_id)
  if codec == nil:
    raise newException(IOError, "декодер не найден для потока " & $streamIdx)
  result = avcodec_alloc_context3(codec)
  if result == nil:
    raise newException(IOError, "avcodec_alloc_context3 (decoder) failed")
  ffCheck(avcodec_parameters_to_context(result, stream.codecpar),
          "parameters_to_context")
  result.thread_count = cint(threads)
  result.thread_type  = cint(FF_THREAD_FRAME or FF_THREAD_SLICE)
  {.emit: "`result`->get_format = monolit_sw_only_get_format;".}
  ffCheck(avcodec_open2(result, codec, nil), "avcodec_open2 decoder")

proc estimateFrameCount(fmtCtx: ptr AVFormatContext; vidIdx: cint): int64 =
  let stream = fmtCtx.streams[vidIdx]
  if stream.nb_frames > 0:
    return stream.nb_frames
  let
    fps = getStreamFps(stream)
    dur =
      if fmtCtx.duration > 0: float(fmtCtx.duration) / float(AV_TIME_BASE)
      elif stream.duration > 0: float(stream.duration) * av_q2d(stream.time_base)
      else: 0.0
  result = max(1'i64, int64(dur * fps))

# ------------------------------------------------------------------------------
# ПРОХОД 1 — vidstabdetect: строим transforms.trf, ничего не кодируем
# ------------------------------------------------------------------------------
proc runDetectPass(cfg: StabConfig; trfPath: string; threads: int) =
  var fmtCtx: ptr AVFormatContext
  ffCheck(avformat_open_input(addr fmtCtx, cstring(cfg.inputFile), nil, nil),
          "открытие: " & cfg.inputFile)
  defer: avformat_close_input(addr fmtCtx)
  ffCheck(avformat_find_stream_info(fmtCtx, nil), "find_stream_info")

  var decoder: ptr AVCodec
  let vidIdx = av_find_best_stream(
    fmtCtx, AVMEDIA_TYPE_VIDEO, cint(-1), cint(-1), cast[pointer](addr decoder), cint(0))
  if vidIdx < 0:
    raise newException(IOError, "видеопоток не найден: " & cfg.inputFile)

  setPhase(phaseAnalyze, estimateFrameCount(fmtCtx, cint(vidIdx)))

  var decCtx = openDecoderFor(fmtCtx, cint(vidIdx), threads)
  defer: avcodec_free_context(addr decCtx)

  let stream = fmtCtx.streams[vidIdx]

  # --- Фильтрграф прохода 1: buffer → vidstabdetect → buffersink -----------
  var graph = avfilter_graph_alloc()
  if graph == nil: raise newException(IOError, "avfilter_graph_alloc failed")
  # avfilter_graph_free() — ЕДИНСТВЕННЫЙ момент, когда vidstabdetect
  # физически дописывает transforms.trf на диск (см. заголовок файла),
  # поэтому этот defer критичен для корректности всего прохода 1.
  defer: avfilter_graph_free(addr graph)

  let
    bufFilt = avfilter_get_by_name("buffer")
    sinkFilt = avfilter_get_by_name("buffersink")
  if bufFilt == nil or sinkFilt == nil:
    raise newException(IOError, "фильтры buffer/buffersink не найдены")

  let
    tb = stream.time_base
    fr = getStreamFpsRat(stream)
    srcArgs = fmt"video_size={decCtx.width}x{decCtx.height}" &
              fmt":pix_fmt={cint(decCtx.pix_fmt)}" &
              fmt":time_base={tb.num}/{tb.den}" &
              fmt":pixel_aspect=1/1:frame_rate={fr.num}/{fr.den}"

  var srcCtx, sinkCtx: ptr AVFilterContext
  ffCheck(avfilter_graph_create_filter(addr srcCtx, bufFilt, "in",
          cstring(srcArgs), nil, graph), "buffersrc create")
  ffCheck(avfilter_graph_create_filter(addr sinkCtx, sinkFilt, "out",
          nil, nil, graph), "buffersink create")

  # result=<trf> — vidstabdetect пишет туда бинарный лог траектории.
  # shakiness/accuracy/stepsize/mincontrast — см. описание в StabConfig;
  # значения по умолчанию (10/15/6/0.3) соответствуют "наивысшему
  # качеству анализа" из требований, ценой самой медленной обработки.
  let filterDesc = fmt"vidstabdetect=result={trfPath}" &
                   fmt":shakiness={cfg.shakiness}:accuracy={cfg.accuracy}" &
                   fmt":stepsize={cfg.stepsize}:mincontrast={cfg.mincontrast:.3f}"
  writeLine(stderr, "[Monolit] Проход 1 (vidstabdetect): " & filterDesc)
  flushFile(stderr)

  var
    inputs = avfilter_inout_alloc()
    outputs = avfilter_inout_alloc()
  outputs.name = av_strdup("in");  outputs.filter_ctx = srcCtx;  outputs.pad_idx = 0; outputs.next = nil
  inputs.name  = av_strdup("out"); inputs.filter_ctx  = sinkCtx; inputs.pad_idx  = 0; inputs.next  = nil
  let pr = avfilter_graph_parse_ptr(graph, cstring(filterDesc), addr inputs, addr outputs, nil)
  avfilter_inout_free(addr inputs)
  avfilter_inout_free(addr outputs)
  if pr < 0:
    raise newException(IOError, "vidstabdetect graph parse: " & ffErrStr(pr) &
                        "  [" & filterDesc & "]")
  ffCheck(avfilter_graph_config(graph, nil), "avfilter_graph_config (detect)")

  # --- Главный цикл: decode → отдать фильтру → сразу выкинуть кадр ---------
  var
    pkt = av_packet_alloc()
    decFrame = av_frame_alloc()
    filtFrame = av_frame_alloc()
  defer:
    av_packet_free(addr pkt)
    av_frame_free(addr decFrame)
    av_frame_free(addr filtFrame)

  proc drain() =
    while true:
      let gr = av_buffersink_get_frame(sinkCtx, filtFrame)
      if gr == AVERROR_EAGAIN or gr == AVERROR_EOF: break
      if gr < 0: break
      av_frame_unref(filtFrame)
      bumpProgress()

  while true:
    if isCancelRequested():
      raise newException(StabCancelledError, "остановлено пользователем")
    let rd = av_read_frame(fmtCtx, pkt)
    if rd == AVERROR_EOF: break
    if rd < 0: break
    if pkt.stream_index != cint(vidIdx):
      av_packet_unref(pkt); continue
    if avcodec_send_packet(decCtx, pkt) < 0:
      av_packet_unref(pkt); continue
    av_packet_unref(pkt)
    while true:
      let rr = avcodec_receive_frame(decCtx, decFrame)
      if rr == AVERROR_EAGAIN or rr == AVERROR_EOF: break
      if rr < 0: break
      discard av_buffersrc_add_frame_flags(srcCtx, decFrame, AV_BUFFERSRC_FLAG_KEEP_REF)
      av_frame_unref(decFrame)
      drain()

  # flush: декодер → фильтр → фильтр(nil) — иначе последние кадры и,
  # что важнее, ХВОСТ траектории (нужный vidstabtransform для сглаживания
  # конца ролика) не попадут в анализ.
  discard avcodec_send_packet(decCtx, nil)
  while true:
    let rr = avcodec_receive_frame(decCtx, decFrame)
    if rr == AVERROR_EAGAIN or rr == AVERROR_EOF: break
    if rr < 0: break
    discard av_buffersrc_add_frame_flags(srcCtx, decFrame, AV_BUFFERSRC_FLAG_KEEP_REF)
    av_frame_unref(decFrame)
    drain()
  discard av_buffersrc_add_frame_flags(srcCtx, nil, 0)
  drain()
  # ВАЖНО: сам .trf дописывается только при avfilter_graph_free (defer выше) —
  # vidstabdetect сбрасывает накопленные данные на диск в своём uninit().

# ------------------------------------------------------------------------------
# ПРОХОД 2 — vidstabtransform[,unsharp] → encode(libx264) → mux; аудио copy
# ------------------------------------------------------------------------------
type
  StreamMap = object
    inIdx, outIdx: cint
    inTB: AVRational

proc buildTransformFilterDesc(cfg: StabConfig; trfPath: string): string =
  # CropMode.`$` возвращает ровно то, что ждёт vidstabtransform:
  # "keep" — дотягивать картинку с предыдущего кадра по краям,
  # "black" — честные чёрные поля там, где кадр после компенсации
  # сдвига/зума не покрывает исходный размер.
  result = fmt"vidstabtransform=input={trfPath}" &
           fmt":smoothing={cfg.smoothing}" &
           fmt":optzoom={cfg.optzoom}" &
           fmt":zoom={cfg.zoom:.2f}" &
           fmt":crop={$cfg.crop}" &
           fmt":interpol={$cfg.interpol}"
  if cfg.maxShift >= 0:
    result &= fmt":maxshift={cfg.maxShift}"
  if cfg.maxAngle >= 0.0:
    result &= fmt":maxangle={cfg.maxAngle:.4f}"
  # smartblur — опциональное шумоподавление/смягчение, ставится ПЕРЕД
  # фильтрами резкости: резкость усиливает уже имеющийся шум, поэтому
  # шумоподавление имеет смысл делать раньше в цепочке, а не после.
  if cfg.smartblurEnabled:
    result &= fmt",smartblur=lr={cfg.smartblurRadius:.2f}" &
              fmt":ls={cfg.smartblurStrength:.2f}:lt={cfg.smartblurThreshold:.1f}"
  # unsharp — опциональный фильтр резкости, ставится ПОСЛЕ стабилизации:
  # затачивать имеет смысл уже финальный (стабилизированный/зумированный)
  # кадр, а не исходный дрожащий — иначе усиливаются и артефакты тряски.
  if cfg.sharpenEnabled:
    result &= fmt",unsharp=luma_msize_x=5:luma_msize_y=5:luma_amount={cfg.sharpenAmount:.2f}"
  # cas (Contrast Adaptive Sharpening) — альтернативная/дополнительная
  # резкость, локально учитывающая контраст (меньше "звона" на краях,
  # чем классический unsharp). Независимый переключатель — можно включить
  # вместе с unsharp, если нужен более выраженный эффект.
  if cfg.casEnabled:
    result &= fmt",cas=strength={cfg.casStrength:.2f}"
  result &= ",format=pix_fmts=yuv420p"

proc runTransformPass(cfg: StabConfig; trfPath: string; threads: int;
                       passNum: int = 0; statsIn: string = ""): string =
  ## Проход 2 (компенсация + кодирование). Поведение зависит от passNum:
  ##   0 — обычный однопроходный режим (emCRF): полноценный вывод сразу.
  ##   1 — 1-й проход emBitrate2Pass: только сбор статистики x264 для
  ##       заданного целевого битрейта; кодированные кадры НИКУДА не
  ##       пишутся (нет ни выходного контейнера, ни копирования
  ##       аудио/субтитров — они не нужны для статистики). Возвращает
  ##       накопленную статистику (encCtx.stats_out), которую нужно
  ##       передать вторым проходом через statsIn.
  ##   2 — 2-й проход emBitrate2Pass: полноценный вывод, распределяющий
  ##       битрейт по всему ролику на основе статистики из прохода 1.
  result = ""
  let statsOnlyPass = (passNum == 1)   # true только для сбора статистики (без вывода)

  var inFmt: ptr AVFormatContext
  ffCheck(avformat_open_input(addr inFmt, cstring(cfg.inputFile), nil, nil),
          "открытие: " & cfg.inputFile)
  defer: avformat_close_input(addr inFmt)
  ffCheck(avformat_find_stream_info(inFmt, nil), "find_stream_info")

  var decoder: ptr AVCodec
  let vidIdx = av_find_best_stream(
    inFmt, AVMEDIA_TYPE_VIDEO, cint(-1), cint(-1), cast[pointer](addr decoder), cint(0))
  if vidIdx < 0:
    raise newException(IOError, "видеопоток не найден: " & cfg.inputFile)

  if statsOnlyPass:
    setPhase(phaseEncodePass1, estimateFrameCount(inFmt, cint(vidIdx)))
  else:
    setPhase(phaseTransform, estimateFrameCount(inFmt, cint(vidIdx)))

  var decCtx = openDecoderFor(inFmt, cint(vidIdx), threads)
  defer: avcodec_free_context(addr decCtx)
  let inStream = inFmt.streams[vidIdx]

  # --- Выходной контейнер -----------------------------------------------
  # На статистическом проходе (statsOnlyPass) выходной файл вообще не
  # создаётся — кодированные пакеты только считываются и отбрасываются,
  # реального вывода/копирования аудио-субтитров на этом проходе не
  # существует, поэтому outFmt/outVidStream остаются nil.
  var
    outFmt: ptr AVFormatContext = nil
    outVidStream: ptr AVStream = nil
  if not statsOnlyPass:
    ffCheck(avformat_alloc_output_context2(addr outFmt, nil, nil, cstring(cfg.outputFile)),
            "alloc_output_context2")
    outVidStream = avformat_new_stream(outFmt, nil)
    if outVidStream == nil:
      raise newException(IOError, "avformat_new_stream (video) failed")
  defer:
    if outFmt != nil:
      if outFmt.pb != nil: discard avio_closep(addr outFmt.pb)
      avformat_free_context(outFmt)

  let encoder = avcodec_find_encoder_by_name("libx264")
  if encoder == nil: raise newException(IOError, "libx264 не найден")

  var encCtx = avcodec_alloc_context3(encoder)
  if encCtx == nil:
    raise newException(IOError, "avcodec_alloc_context3 (encoder) failed")
  encCtx.width  = decCtx.width
  encCtx.height = decCtx.height
  encCtx.pix_fmt = AV_PIX_FMT_YUV420P
  # ВАЖНО: encCtx.time_base — это единица измерения для frame.pts, который
  # ниже (encodeAndWrite) увеличивается РОВНО НА 1 на каждый кадр, потому
  # что vidstabtransform отдаёт кадры 1-в-1 (не дублирует и не пропускает
  # их). Значит "1 тик pts" здесь всегда должен означать "ровно 1/fps
  # секунды". Раньше сюда подставлялся inStream.time_base — тайм-база
  # ВХОДНОГО КОНТЕЙНЕРА, которая для многих mkv/mp4 равна, например,
  # 1/1000 (миллисекунды) и НЕ СВЯЗАНА с реальной частотой кадров. При
  # pts=0,1,2,3... и time_base=1/1000 плеер видел "1 кадр = 1 мс" —
  # т.е. 1000 кадров в секунду, отчего весь ролик "сжимался" в несколько
  # секунд и кадры мельтешили (реальная частота кадров/длительность
  # звука при этом не менялись, т.к. аудио копируется потоково со своим,
  # корректно рассчитанным, таймингом). Правильная тайм-база для
  # honest "1 pts-тик = 1 кадр" — это период кадра, av_inv_q(framerate).
  let encFr = getStreamFpsRat(inStream)
  encCtx.framerate = encFr
  encCtx.time_base = av_inv_q(encFr)
  encCtx.gop_size = cint(int(getStreamFps(inStream)))
  encCtx.max_b_frames = cint(2)
  encCtx.thread_count = cint(threads)
  encCtx.thread_type  = cint(FF_THREAD_FRAME or FF_THREAD_SLICE)
  encCtx.sample_aspect_ratio = decCtx.sample_aspect_ratio
  if outFmt != nil and outFmt.oformat != nil and
     (outFmt.oformat.flags and AVFMT_GLOBALHEADER) != 0:
    encCtx.flags = encCtx.flags or AV_CODEC_FLAG_GLOBAL_HEADER

  # --- Управление битрейтом: CRF (1 проход) либо ABR 2-прохода -----------
  var encOpts: ptr AVDictionary = nil
  discard av_dict_set(addr encOpts, "preset", cstring(cfg.preset), 0)
  case cfg.encodeMode
  of emCRF:
    discard av_dict_set(addr encOpts, "crf", cstring($cfg.crf), 0)
  of emBitrate2Pass:
    # Целевой битрейт видео — из него libx264 в 2 прохода вычисляет,
    # сколько бит выделить на каждую сцену, чтобы в среднем по ролику
    # попасть точно в заданное значение (в отличие от CRF, где итоговый
    # размер файла заранее не предсказать).
    encCtx.bit_rate = int64(cfg.videoBitrateKbps) * 1000'i64
    if passNum == 1:
      encCtx.flags = encCtx.flags or AV_CODEC_FLAG_PASS1
    elif passNum == 2:
      encCtx.flags = encCtx.flags or AV_CODEC_FLAG_PASS2
      # statsIn должен пережить весь проход кодирования — он живёт как
      # параметр этой функции, поэтому указатель остаётся валидным до
      # самого её завершения (avcodec_free_context ниже, через defer).
      encCtx.stats_in = cstring(statsIn)
  ffCheck(avcodec_open2(encCtx, encoder, addr encOpts), "avcodec_open2 x264")
  av_dict_free(addr encOpts)
  defer: avcodec_free_context(addr encCtx)

  if not statsOnlyPass:
    ffCheck(avcodec_parameters_from_context(outVidStream.codecpar, encCtx),
            "parameters_from_context")
    outVidStream.time_base = encCtx.time_base

  # --- Аудио/субтитры/вложения: прямое копирование потоков (без перекодирования) ---
  # На статистическом проходе не нужны вообще — стрим-мапы остаются пустыми,
  # а findMap() ниже просто откинет все непопавшие в неё пакеты.
  var streamMaps: seq[StreamMap] = @[]
  if not statsOnlyPass:
    for i in 0 ..< int(inFmt.nb_streams):
      let st = inFmt.streams[i]
      if i == vidIdx: continue
      let
        mtype = st.codecpar.codec_type
        keep =
          (mtype == AVMEDIA_TYPE_AUDIO      and cfg.copyAudio) or
          (mtype == AVMEDIA_TYPE_SUBTITLE   and cfg.saveSubtitles) or
          (mtype == AVMEDIA_TYPE_ATTACHMENT and cfg.saveAttachments)
      if not keep: continue
      let outSt = avformat_new_stream(outFmt, nil)
      if outSt == nil: continue
      ffCheck(avcodec_parameters_copy(outSt.codecpar, st.codecpar),
              "audio/sub/attachment parameters_copy")
      outSt.codecpar.codec_tag = cuint(0)
      outSt.time_base = st.time_base
      add(streamMaps, StreamMap(inIdx: cint(i), outIdx: outSt.index, inTB: st.time_base))

    ffCheck(avio_open(addr outFmt.pb, cstring(cfg.outputFile), AVIO_FLAG_WRITE), "avio_open")
    ffCheck(avformat_write_header(outFmt, nil), "write_header")

  # --- Фильтрграф прохода 2 -------------------------------------------------
  var graph = avfilter_graph_alloc()
  if graph == nil: raise newException(IOError, "avfilter_graph_alloc failed (pass2)")
  defer: avfilter_graph_free(addr graph)
  let
    bufFilt = avfilter_get_by_name("buffer")
    sinkFilt = avfilter_get_by_name("buffersink")

  let
    tb = inStream.time_base
    fr = getStreamFpsRat(inStream)
    srcArgs = fmt"video_size={decCtx.width}x{decCtx.height}" &
              fmt":pix_fmt={cint(decCtx.pix_fmt)}" &
              fmt":time_base={tb.num}/{tb.den}" &
              fmt":pixel_aspect=1/1:frame_rate={fr.num}/{fr.den}"

  var srcCtx, sinkCtx: ptr AVFilterContext
  ffCheck(avfilter_graph_create_filter(addr srcCtx, bufFilt, "in",
          cstring(srcArgs), nil, graph), "buffersrc create (pass2)")
  ffCheck(avfilter_graph_create_filter(addr sinkCtx, sinkFilt, "out",
          nil, nil, graph), "buffersink create (pass2)")

  let filterDesc = buildTransformFilterDesc(cfg, trfPath)
  writeLine(stderr, "[Monolit] Проход " & (if statsOnlyPass: "2a (сбор статистики x264)"
                                           else: (if passNum == 2: "2b (финальный вывод)" else: "2")) &
                    " (vidstabtransform): " & filterDesc)
  flushFile(stderr)
  var
    inputs = avfilter_inout_alloc()
    outputs = avfilter_inout_alloc()
  outputs.name = av_strdup("in");  outputs.filter_ctx = srcCtx;  outputs.pad_idx = 0; outputs.next = nil
  inputs.name  = av_strdup("out"); inputs.filter_ctx  = sinkCtx; inputs.pad_idx  = 0; inputs.next  = nil
  let pr = avfilter_graph_parse_ptr(graph, cstring(filterDesc), addr inputs, addr outputs, nil)
  avfilter_inout_free(addr inputs)
  avfilter_inout_free(addr outputs)
  if pr < 0:
    raise newException(IOError, "vidstabtransform graph parse: " & ffErrStr(pr) &
                        "  [" & filterDesc & "]")
  ffCheck(avfilter_graph_config(graph, nil), "avfilter_graph_config (transform)")

  # --- Кодирование одного кадра из sink'а -----------------------------------
  var
    tmpPkt = av_packet_alloc()
    ptsCounter: int64 = 0
    statsAccum = ""   # накопитель статистики x264 — заполняется только на statsOnlyPass

  proc drainPackets() =
    ## Слить все готовые пакеты из энкодера. Вынесено в отдельную функцию,
    ## т.к. вызывается из ДВУХ мест encodeAndWrite ниже: после успешной
    ## отправки кадра и — что критично — ПЕРЕД повторной попыткой отправки
    ## того же кадра при AVERROR(EAGAIN) (см. комментарий там же).
    while true:
      let rp = avcodec_receive_packet(encCtx, tmpPkt)
      if rp == AVERROR_EAGAIN or rp == AVERROR_EOF: break
      if rp < 0: break
      if statsOnlyPass:
        # Кодированные данные тут не нужны — важна только статистика,
        # которую x264 после каждого пакета кладёт в encCtx.stats_out.
        if encCtx.stats_out != nil:
          add(statsAccum, $encCtx.stats_out)
      else:
        tmpPkt.stream_index = outVidStream.index
        av_packet_rescale_ts(tmpPkt, encCtx.time_base, outVidStream.time_base)
        tmpPkt.pos = -1
        discard av_interleaved_write_frame(outFmt, tmpPkt)
      av_packet_unref(tmpPkt)

  proc encodeAndWrite(frame: ptr AVFrame) =
    if frame != nil:
      frame.pts = ptsCounter
      inc ptsCounter
      frame.pict_type = AV_PICTURE_TYPE_NONE
    # avcodec_send_frame ОБЯЗАН обрабатываться в цикле: пока внутренний
    # буфер энкодера (b-frames/rc_lookahead/threads — у libx264 это
    # реально бывает: threads=8, rc_lookahead=23, b_pyramid=2) заполнен,
    # он возвращает AVERROR(EAGAIN) и требует СНАЧАЛА забрать готовые
    # пакеты через avcodec_receive_packet, а ПОТОМ повторить отправку
    # ТОГО ЖЕ кадра — так документирован контракт этой функции в
    # libavcodec/avcodec.h. Раньше при EAGAIN мы просто выходили из
    # encodeAndWrite без повторной попытки — кадр молча терялся
    # НАВСЕГДА (pts-счётчик при этом всё равно увеличивался, так что
    # потеря была незаметна по числу "обработанных" кадров в прогрессе).
    # При многопоточном libx264 с lookahead это происходит регулярно на
    # всём протяжении кодирования, а не только в начале — в результате
    # реально попадает в файл лишь малая часть кадров, что и объясняет
    # крайне низкое качество/размер результата НЕЗАВИСИМО от CRF или
    # целевого битрейта: дело было не в настройках сжатия, а в потере
    # самих кадров до кодирования.
    while true:
      let sr = avcodec_send_frame(encCtx, frame)
      if sr == AVERROR_EAGAIN:
        drainPackets()
        continue
      if sr < 0 and sr != AVERROR_EOF:
        return
      break
    drainPackets()

  proc drainAndEncode(filtFrame: ptr AVFrame) =
    while true:
      let gr = av_buffersink_get_frame(sinkCtx, filtFrame)
      if gr == AVERROR_EAGAIN or gr == AVERROR_EOF: break
      if gr < 0: break
      encodeAndWrite(filtFrame)
      av_frame_unref(filtFrame)
      bumpProgress()

  # --- Главный цикл: читаем видео (через фильтр+энкодер) и аудио (copy) ----
  var
    pkt = av_packet_alloc()
    decFrame = av_frame_alloc()
    filtFrame = av_frame_alloc()
  defer:
    av_packet_free(addr pkt)
    av_packet_free(addr tmpPkt)
    av_frame_free(addr decFrame)
    av_frame_free(addr filtFrame)

  proc findMap(inIdx: cint): int =
    for i, m in streamMaps:
      if m.inIdx == inIdx: return i
    return -1

  while true:
    if isCancelRequested():
      raise newException(StabCancelledError, "остановлено пользователем")
    let rd = av_read_frame(inFmt, pkt)
    if rd == AVERROR_EOF: break
    if rd < 0: break

    if pkt.stream_index == cint(vidIdx):
      if avcodec_send_packet(decCtx, pkt) >= 0:
        while true:
          let rr = avcodec_receive_frame(decCtx, decFrame)
          if rr == AVERROR_EAGAIN or rr == AVERROR_EOF: break
          if rr < 0: break
          discard av_buffersrc_add_frame_flags(srcCtx, decFrame, AV_BUFFERSRC_FLAG_KEEP_REF)
          av_frame_unref(decFrame)
          drainAndEncode(filtFrame)
      av_packet_unref(pkt)
    else:
      let mi = findMap(pkt.stream_index)
      if mi < 0:
        av_packet_unref(pkt); continue
      let outSt = outFmt.streams[streamMaps[mi].outIdx]
      av_packet_rescale_ts(pkt, streamMaps[mi].inTB, outSt.time_base)
      pkt.stream_index = outSt.index
      pkt.pos = -1
      discard av_interleaved_write_frame(outFmt, pkt)
      av_packet_unref(pkt)

  # flush: decoder → filter → filter(nil) → encoder(nil)
  discard avcodec_send_packet(decCtx, nil)
  while true:
    let rr = avcodec_receive_frame(decCtx, decFrame)
    if rr == AVERROR_EAGAIN or rr == AVERROR_EOF: break
    if rr < 0: break
    discard av_buffersrc_add_frame_flags(srcCtx, decFrame, AV_BUFFERSRC_FLAG_KEEP_REF)
    av_frame_unref(decFrame)
    drainAndEncode(filtFrame)
  discard av_buffersrc_add_frame_flags(srcCtx, nil, 0)
  drainAndEncode(filtFrame)
  encodeAndWrite(nil)

  if not statsOnlyPass:
    ffCheck(av_write_trailer(outFmt), "write_trailer")

  result = statsAccum

# ------------------------------------------------------------------------------
# Публичная точка входа — вызывается из фонового потока Monolit.nim
# ------------------------------------------------------------------------------
proc runStabilization*(cfg: StabConfig; cpuThreads: int = 0) =
  let
    threads = if cpuThreads > 0: cpuThreads else: max(1, int(av_cpu_count()))
    trfPath = transformFilePath(cfg)
  writeLine(stderr,
    "[Monolit] Старт: \"" & cfg.inputFile & "\" -> \"" & cfg.outputFile & "\" " &
    "(потоков: " & $threads & ", .trf: " & trfPath & ")")
  writeLine(stderr,
    "[Monolit] Стабилизация: shakiness=" & $cfg.shakiness & " accuracy=" & $cfg.accuracy &
    " stepsize=" & $cfg.stepsize & " mincontrast=" & $cfg.mincontrast &
    " | smoothing=" & $cfg.smoothing & " zoom=" & $cfg.zoom &
    " optzoom=" & $cfg.optzoom & " crop=" & $cfg.crop & " interpol=" & $cfg.interpol)
  writeLine(stderr,
    "[Monolit] Кодирование: preset=" & cfg.preset & " режим=" & $cfg.encodeMode &
    " crf=" & $cfg.crf & " битрейт=" & $cfg.videoBitrateKbps & " кбит/с")
  flushFile(stderr)
  try:
    runDetectPass(cfg, trfPath, threads)
    case cfg.encodeMode
    of emCRF:
      discard runTransformPass(cfg, trfPath, threads, passNum = 0)
    of emBitrate2Pass:
      # Проход A — только статистика x264 (ничего не пишется на диск, кроме .trf).
      let stats = runTransformPass(cfg, trfPath, threads, passNum = 1)
      # Проход B — реальный вывод, битрейт распределяется по всему ролику
      # на основе статистики, собранной проходом A.
      discard runTransformPass(cfg, trfPath, threads, passNum = 2, statsIn = stats)
    writeLine(stderr, "[Monolit] Готово: \"" & cfg.outputFile & "\"")
    flushFile(stderr)
    setPhase(phaseDone)
  except StabCancelledError:
    writeLine(stderr, "[Monolit] Остановлено пользователем.")
    flushFile(stderr)
    # Недописанный результат неполон (а зачастую и физически повреждён —
    # обрыв мьюксера посреди файла), оставлять его под именем, которое
    # пользователь может перепутать с настоящим результатом, не стоит.
    if fileExists(cfg.outputFile):
      try: removeFile(cfg.outputFile) except OSError: discard
    setPhase(phaseCancelled)
  except CatchableError as e:
    writeLine(stderr, "[Monolit] ОШИБКА: " & e.msg)
    flushFile(stderr)
    setError(e.msg)
  finally:
    if fileExists(trfPath) and len(cfg.tempDir) == 0:
      # transforms.trf во временной папке ОС — подчищаем; если пользователь
      # явно указал tempDir (например, для отладки), файл оставляем.
      try: removeFile(trfPath) except OSError: discard
