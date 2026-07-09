# ==============================================================================
#  config.nims — автосборка одной командой (модель PMI, расширенная):
#
#      nim c -d:release --threads:on Monolit.nim                    (Fedora)
#      nim c -d:release --threads:on --os:windows Monolit.nim       (Windows, кросс)
#
#  ЧТО ОБЩЕГО С config.nims ИЗ PMI:
#    Статическая сборка libx264 + FFmpeg тем же способом (кросс-компиляция
#    под mingw-w64 для Windows, нативно для Fedora), те же bp()/slashify()/
#    findHostExe() хелперы и та же ловушка NimScript с --os:windows,
#    описанная там подробно — здесь не повторяем комментарий целиком,
#    см. PMI/config.nims.
#
#  ЧТО НОВОГО ДЛЯ Monolit:
#    1. FFmpeg собирается с --enable-libvidstab (плюс --enable-filter
#       расширен на vidstabdetect/vidstabtransform/unsharp/format) —
#       остальные включённые кодеки/контейнеры/фильтры унаследованы из
#       PMI без изменений.
#    2. Перед сборкой FFmpeg отдельно собирается статическая libvidstab.a
#       (из исходников georgmartius/vid.stab, автономный CMake-проект,
#       без зависимости от самого FFmpeg).
#    3. GTK4 линкуется ДИНАМИЧЕСКИ через pkg-config (см. обоснование в
#       src/gtk4_api.nim) — на Windows pkg-config должен резолвить
#       mingw64-сборку GTK4 (см. ensureMingwGtk4).
#    4. Для Windows добавлен отдельный шаг packageWindowsDist — копирует
#       Monolit.exe рядом с рантаймом GTK4 (DLL, share/glib-2.0/schemas,
#       share/icons) в один раздаваемый каталог, т.к. эти файлы GTK
#       ищет рядом с собой в рантайме, а не только на этапе линковки.
#    5. Перед FFmpeg отдельно собирается статическая libdav1d.a (Meson-
#       проект videolan/dav1d, не зависит от FFmpeg) и подключается через
#       --enable-libdav1d — Monolit явно предпочитает её для AV1-потоков
#       (см. openDecoderFor в src/stabilizer.nim), т.к. родной AV1-декодер
#       FFmpeg местами ненадёжен именно на согласовании pixel-формата.
# ==============================================================================

import std/[os, strformat, strutils]

proc bp(parts: varargs[string]): string = join(parts, "/")

proc slashify(p: string): string = replace(p, '\\', '/')

proc findHostExe(name: string): string =
  let r = gorgeEx("which " & name & " 2>/dev/null")
  if r.exitCode == 0: strip(r.output) else: ""

proc detectJobs(): string =
  let nproc = gorgeEx("nproc")
  if nproc.exitCode == 0 and strip(nproc.output) != "": return strip(nproc.output)
  echo "[config.nims] [WARN] Не удалось определить число ядер, используем 4."
  return "4"

let
  thisFile        = slashify(currentSourcePath())
  projectDir      = thisFile[0 ..< rfind(thisFile, '/')]
  parentOfProject = projectDir[0 ..< rfind(projectDir, '/')]
  ffmpegBranch    = "release/7.1"
  x264RepoUrl     = "https://code.videolan.org/videolan/x264.git"
  vidstabRepoUrl  = "https://github.com/georgmartius/vid.stab.git"
  vidstabTag      = "v1.1.0"
  dav1dRepoUrl    = "https://code.videolan.org/videolan/dav1d.git"
  dav1dTag        = "1.4.3"

let crossWindows = defined(windows)
const mingwPrefix = "x86_64-w64-mingw32-"

let
  ffmpegSrc  = if getEnv("PMI_FFMPEG_SRC") != "": getEnv("PMI_FFMPEG_SRC")
               elif crossWindows: bp(parentOfProject, "FFmpeg-windows")
               else: bp(parentOfProject, "FFmpeg")
  x264Src    = bp(parentOfProject, "x264-windows")
  vidstabSrc = bp(parentOfProject, if crossWindows: "vid.stab-windows" else: "vid.stab")
  dav1dSrc   = bp(parentOfProject, if crossWindows: "dav1d-windows" else: "dav1d")
  buildDir   = bp(projectDir, if crossWindows: "ffmpeg_build_windows" else: "ffmpeg_build")
  x264Build  = bp(projectDir, "x264_build_windows")
  vidstabBuild = bp(projectDir, if crossWindows: "vidstab_build_windows" else: "vidstab_build")
  dav1dBuild = bp(projectDir, if crossWindows: "dav1d_build_windows" else: "dav1d_build")
  incDir     = bp(buildDir, "include")
  libDir     = bp(buildDir, "lib")

const ffmpegLibs = [
  "libavfilter.a", "libavcodec.a", "libavformat.a",
  "libswscale.a", "libswresample.a", "libavutil.a"
]

proc allLibsExist(dir: string): bool =
  result = true
  for libName in ffmpegLibs:
    if not fileExists(bp(dir, libName)): result = false

proc cloneRepo(url, dst, branch: string) =
  # Раньше здесь просто вызывался git clone — если по каким-то причинам
  # каталог dst уже существует (прерванный предыдущий клон, ручной
  # эксперимент и т.п.), но нужного файла-маркера (CMakeLists.txt/configure)
  # в нём нет, git clone падает с "already exists and is not empty",
  # хотя по факту клонировать НАДО (см. отчёт: ровно так и произошло на
  # vid.stab). Раз вызывающая сторона уже решила, что клон нужен (маркер
  # отсутствует), безопаснее снести незавершённый/чужой каталог и
  # клонировать начисто, чем падать или тихо доверять непонятному
  # содержимому.
  if dirExists(dst):
    echo fmt"[config.nims] {dst} уже существует, но без ожидаемых файлов — " &
         "удаляем и клонируем заново."
    exec "rm -rf \"" & dst & "\""
  echo fmt"[config.nims] Клонируем {url} ({branch}) → {dst}"
  exec "git clone --branch \"" & branch & "\" --depth 1 \"" & url & "\" \"" & dst & "\""

# ------------------------------------------------------------------------------
# mingw-w64 тулчейн (как в PMI) — нужен и для x264/FFmpeg, и теперь для vidstab
# ------------------------------------------------------------------------------
proc ensureMingwToolchain(): string =
  result = findHostExe(mingwPrefix & "gcc")
  if result != "": return
  echo "[config.nims] mingw-w64 тулчейн не найден, пробуем dnf..."
  if findHostExe("dnf") != "":
    exec "sudo dnf install -y mingw64-gcc mingw64-gcc-c++ mingw64-binutils " &
         "mingw64-filesystem mingw64-crt mingw64-headers " &
         "mingw64-winpthreads-static mingw64-cmake nasm yasm git cmake || true"
  result = findHostExe(mingwPrefix & "gcc")
  if result == "":
    echo "[config.nims] [ERROR] " & mingwPrefix & "gcc так и не найден в PATH."
    quit(1)

# ------------------------------------------------------------------------------
# libvidstab — автономный CMake-проект (не зависит от FFmpeg), собирается
# отдельно и раньше FFmpeg; --enable-libvidstab у FFmpeg находит его через
# обычный pkg-config (vidstab.pc), поэтому PKG_CONFIG_PATH указывает и на
# libx264, и на libvidstab одновременно.
# ------------------------------------------------------------------------------
proc buildVidstab(src, prefix: string; windows: bool) =
  if fileExists(bp(prefix, "lib", "libvidstab.a")):
    echo fmt"[config.nims] libvidstab.a уже собрана в {prefix} — пропускаем."
    return
  if not fileExists(bp(src, "CMakeLists.txt")):
    cloneRepo(vidstabRepoUrl, src, vidstabTag)

  let jobs = detectJobs()
  let savedDir = getCurrentDir()
  let buildSubdir = bp(src, "build")
  if not dirExists(buildSubdir): mkDir(buildSubdir)
  cd(buildSubdir)

  var cmakeArgs = @[
    "-DCMAKE_INSTALL_PREFIX=\"" & prefix & "\"",
    "-DBUILD_SHARED_LIBS=OFF",
    "-DCMAKE_BUILD_TYPE=Release",
    # vid.stab v1.1.0 объявляет cmake_minimum_required(VERSION 2.x) в своём
    # CMakeLists.txt, а современный CMake (>=4.0) вообще отказывается
    # работать с проектами, требующими < 3.5 — падает ещё до чтения
    # остального файла. Это не ошибка сборки как таковая, а несовместимость
    # версии CMake с очень старым upstream-манифестом; флаг ниже — штатный
    # способ CMake сказать "считай, что минимум 3.5" без патчинга исходников.
    "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
  ]
  if windows:
    discard ensureMingwToolchain()
    add(cmakeArgs, [
      "-DCMAKE_SYSTEM_NAME=Windows",
      "-DCMAKE_C_COMPILER=" & mingwPrefix & "gcc",
      # ПОЧЕМУ ЭТО ОБЯЗАТЕЛЬНО (это и есть исправление падения сборки под
      # Windows): project() в CMakeLists.txt самого vid.stab не
      # ограничивает список языков явно, поэтому CMake включает C И CXX
      # сразу, даже если исходники библиотеки — чистый C. Без
      # CMAKE_CXX_COMPILER, указанного явно, CMake при кросс-сборке ищет
      # компилятор C++ штатным поиском в PATH и находит ХОСТОВЫЙ
      # (нативный) c++/g++ вместо mingw-w64. Дальше это бьёт незаметно:
      # CMAKE_SYSTEM_NAME=Windows заставляет CMake считать цель PE/COFF и
      # добавлять PE-специфичные флаги компоновщика вроде
      # --major-image-version/--minor-image-version, а получает их
      # нативный линковщик хоста (раз CXX-компилятор хостовый), который
      # эти флаги просто не понимает — отсюда "неизвестный параметр
      # «--major-image-version»", и сборка тестового CXX-компилятора
      # (CMakeTestCXXCompiler) падает ещё до генерации самого проекта.
      # Явное указание mingw-w64 g++ синхронизирует компилятор с тем, что
      # уже подразумевает CMAKE_SYSTEM_NAME=Windows, независимо от того,
      # использует ли vid.stab C++ фактически.
      "-DCMAKE_CXX_COMPILER=" & mingwPrefix & "g++",
      "-DCMAKE_RC_COMPILER=" & mingwPrefix & "windres"
    ])
  echo "[config.nims] Сборка libvidstab..."
  exec "cmake " & join(cmakeArgs, " ") & " .."
  exec fmt"make -j{jobs}"
  exec "make install"
  # vid.stab не всегда ставит .pc-файл сам — на случай его отсутствия
  # генерируем минимальный, иначе --enable-libvidstab у FFmpeg не найдёт
  # библиотеку через pkg-config.
  let pcDir = bp(prefix, "lib", "pkgconfig")
  let pcFile = bp(pcDir, "vidstab.pc")
  if not fileExists(pcFile):
    if not dirExists(pcDir): mkDir(pcDir)
    # ${pcfiledir} — переменная, которую pkg-config подставляет САМ, равна
    # каталогу, где лежит сам .pc-файл (здесь — {prefix}/lib/pkgconfig).
    # Через неё prefix выражается относительно расположения .pc-файла, а
    # не как абсолютный путь, зашитый на момент сборки, — если каталог
    # проекта потом переименуют, скопируют на другую машину или соберут
    # под другим пользователем, .pc остаётся рабочим без правки.
    writeFile(pcFile, fmt"""prefix=${{pcfiledir}}/../..
libdir=${{prefix}}/lib
includedir=${{prefix}}/include

Name: vidstab
Description: Video stabilization library
Version: 1.1.0
Libs: -L${{libdir}} -lvidstab -lm
Cflags: -I${{includedir}}
""")
  cd(savedDir)

# ------------------------------------------------------------------------------
# libx264 под Windows (дословно как в PMI/config.nims)
# ------------------------------------------------------------------------------
proc buildX264Windows(src, prefix: string) =
  if fileExists(bp(prefix, "lib", "libx264.a")):
    echo fmt"[config.nims] libx264.a (Windows) уже собрана — пропускаем."
    return
  discard ensureMingwToolchain()
  if not fileExists(bp(src, "configure")):
    cloneRepo(x264RepoUrl, src, "stable")
  let jobs = detectJobs()
  let savedDir = getCurrentDir()
  cd(src)
  exec "./configure --prefix=\"" & prefix & "\" --host=x86_64-w64-mingw32 " &
       "--cross-prefix=" & mingwPrefix & " --enable-static --enable-pic " &
       "--disable-cli --bit-depth=all"
  exec fmt"make -j{jobs}"
  exec "make install"
  cd(savedDir)
proc ensureMeson(): void =
  if findHostExe("meson") != "" and findHostExe("ninja") != "": return
  echo "[config.nims] meson/ninja не найдены, пробуем dnf..."
  if findHostExe("dnf") != "":
    exec "sudo dnf install -y meson ninja-build || true"
  if findHostExe("meson") == "" or findHostExe("ninja") == "":
    echo "[config.nims] [ERROR] meson/ninja так и не найдены в PATH " &
         "(нужны для сборки libdav1d)."
    quit(1)

proc ensureNasm(): void =
  # dav1d использует nasm для x86-ассемблера; собирается раньше
  # buildFFmpeg, где обычно и стоит установка nasm через dnf — поэтому
  # на чистой системе нужна отдельная проверка именно здесь.
  if findHostExe("nasm") != "": return
  echo "[config.nims] nasm не найден, пробуем dnf..."
  if findHostExe("dnf") != "":
    exec "sudo dnf install -y nasm || true"

# ------------------------------------------------------------------------------
# libdav1d — чисто программный AV1-декодер (Meson-проект, не зависит от
# FFmpeg), собирается отдельно и раньше FFmpeg, аналогично libvidstab.
# Зачем он вообще нужен, раз FFmpeg и так умеет AV1 "из коробки": родной
# декодер FFmpeg ("av1") на некоторых системах ломает декодирование с
# "Failed to get pixel format" / "Your platform doesn't support hardware
# accelerated AV1 decoding" даже когда аппаратное ускорение тут вообще ни
# при чём (это подтверждённая, известная шероховатость самого FFmpeg —
# см. обсуждение в рассылке ffmpeg-devel про av1dec.c). dav1d — тот
# декодер, которым в реальности пользуются браузеры и плееры для AV1;
# у него нет hwaccel-кода вообще, поэтому весь этот класс проблем не
# возникает в принципе. Monolit явно предпочитает его для AV1-потоков
# (см. openDecoderFor в src/stabilizer.nim), но не отказывается от
# остальных декодеров FFmpeg.
# ------------------------------------------------------------------------------
proc buildDav1d(src, prefix: string; windows: bool) =
  if fileExists(bp(prefix, "lib", "libdav1d.a")) or
     fileExists(bp(prefix, "lib64", "libdav1d.a")) or
     fileExists(bp(prefix, "lib", "x86_64-linux-gnu", "libdav1d.a")):
    echo fmt"[config.nims] libdav1d.a уже собрана в {prefix} — пропускаем."
    return
  ensureMeson()
  ensureNasm()
  if not fileExists(bp(src, "meson.build")):
    cloneRepo(dav1dRepoUrl, src, dav1dTag)

  let jobs = detectJobs()
  let savedDir = getCurrentDir()
  let buildSubdir = bp(src, "build")
  # meson setup падает, если каталог build уже существует от прошлой,
  # возможно неудачной, попытки — как и cloneRepo выше, безопаснее
  # снести и настроить начисто, чем разбираться в чужом состоянии.
  if dirExists(buildSubdir):
    exec "rm -rf \"" & buildSubdir & "\""
  cd(src)

  var mesonArgs = @[
    "setup", "build",
    "--prefix=\"" & prefix & "\"",
    "--default-library=static",
    "--buildtype=release",
    "-Denable_tools=false",
    "-Denable_tests=false",
    "-Denable_examples=false"
  ]
  if windows:
    discard ensureMingwToolchain()
    let crossFile = bp(src, "monolit-mingw-cross.ini")
    writeFile(crossFile, fmt"""[binaries]
c = '{mingwPrefix}gcc'
ar = '{mingwPrefix}ar'
strip = '{mingwPrefix}strip'
windres = '{mingwPrefix}windres'
pkg-config = 'pkg-config'

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
""")
    add(mesonArgs, ["--cross-file=\"" & crossFile & "\""])

  echo "[config.nims] Сборка libdav1d (meson)..."
  exec "meson " & join(mesonArgs, " ")
  cd(buildSubdir)
  exec fmt"ninja -j{jobs}"
  exec "ninja install"
  cd(savedDir)


proc buildFFmpeg(src, prefix: string; windows: bool; x264Prefix, vidstabPrefix, dav1dPrefix: string) =
  let jobs = detectJobs()

  if not windows:
    echo "[config.nims] Проверяем системные зависимости (dnf)..."
    if findHostExe("dnf") != "":
      exec "sudo dnf install -y nasm yasm gcc gcc-c++ make cmake pkg-config " &
           "x264-devel zlib-devel bzip2-devel xz-devel gtk4-devel || true"
  # ВАЖНО: сама настройка PKG_CONFIG_LIBDIR/PKG_CONFIG_PATH (включая x264 на
  # Windows) переехала отсюда в orchestration-секцию ниже и выполняется
  # БЕЗУСЛОВНО, а не только когда buildFFmpeg реально запускается — см.
  # комментарий там же про то, почему это было багом.
  if windows:
    discard ensureMingwToolchain()
    buildX264Windows(x264Src, x264Prefix)

  var configureFlags = @[
    "--prefix=\"" & prefix & "\"",
    "--enable-static", "--disable-shared",
    "--enable-gpl", "--enable-version3", "--enable-libx264",
    "--enable-libvidstab", "--enable-libdav1d",
    "--disable-programs", "--disable-doc", "--disable-debug",
    "--disable-autodetect", "--disable-postproc",
    "--enable-protocol=file",
    "--enable-demuxer=matroska,mov,mpegts,avi,flv",
    "--enable-muxer=matroska,mp4,mov,avi",
    # av1 (родной) оставлен как запасной вариант, но Monolit явно
    # предпочитает libdav1d для AV1-потоков (см. openDecoderFor в
    # src/stabilizer.nim) — оба декодера должны быть включены сразу.
    "--enable-decoder=h264,hevc,mpeg4,mpeg2video,vp9,vp8,av1,libdav1d,aac,ac3,mp3," &
      "eac3,dts,opus,vorbis,flac,ass,ssa,srt,subrip",
    "--enable-encoder=libx264",
    "--enable-parser=h264,hevc,aac,ac3,mpegaudio,vp9,av1,mpeg4video",
    "--enable-filter=vidstabdetect,vidstabtransform,unsharp,cas,smartblur," &
      "buffer,buffersink,scale,format,fifo",
    "--enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc,extract_extradata",
    "--pkg-config-flags=\"--static\""
  ]

  if windows:
    add(configureFlags, [
      "--enable-cross-compile", "--arch=x86_64", "--target-os=mingw32",
      "--cross-prefix=" & mingwPrefix,
      "--extra-cflags=\"-O3 -I" & bp(x264Prefix, "include") &
        " -I" & bp(vidstabPrefix, "include") &
        " -I" & bp(dav1dPrefix, "include") & "\"",
      "--extra-ldflags=\"-static -L" & bp(x264Prefix, "lib") &
        " -L" & bp(vidstabPrefix, "lib") &
        " -L" & bp(dav1dPrefix, "lib") & "\""
    ])
  else:
    add(configureFlags, [
      "--enable-pic",
      "--extra-cflags=\"-O3 -march=native -fPIC -I" & bp(vidstabPrefix, "include") &
        " -I" & bp(dav1dPrefix, "include") & "\"",
      "--extra-ldflags=\"-static-libgcc -L" & bp(vidstabPrefix, "lib") &
        " -L" & bp(dav1dPrefix, "lib") &
        " -L" & bp(dav1dPrefix, "lib64") &
        " -L" & bp(dav1dPrefix, "lib", "x86_64-linux-gnu") & "\""
    ])

  let savedDir = getCurrentDir()
  cd(src)
  exec "./configure " & join(configureFlags, " ")
  exec fmt"make -j{jobs}"
  exec "make install"
  cd(savedDir)

# ------------------------------------------------------------------------------
# Оркестрация: vidstab, dav1d → (x264 на Windows) → FFmpeg
# ------------------------------------------------------------------------------
let vidstabPrefix = vidstabBuild
buildVidstab(vidstabSrc, vidstabPrefix, crossWindows)

let dav1dPrefix = dav1dBuild
buildDav1d(dav1dSrc, dav1dPrefix, crossWindows)

# ------------------------------------------------------------------------------
# Единая точка настройки PKG_CONFIG_LIBDIR/PKG_CONFIG_PATH — ВЫПОЛНЯЕТСЯ
# БЕЗУСЛОВНО на каждом запуске, а не только когда buildFFmpeg реально
# запускается (что было багом: при закэшированных FFmpeg-библиотеках
# buildFFmpeg целиком пропускается — см. allLibsExist ниже — и переменные
# окружения раньше просто не выставлялись, из-за чего src/gtk4_api.nim при
# поиске gtk4 через pkg-config либо ничего не находил, либо натыкался на
# что попало из окружения хоста). Здесь же для Windows в те же переменные
# добавлена директория со штатным .pc-файлом mingw64-сборки GTK4 — без неё
# `pkg-config --cflags/--libs gtk4` в src/gtk4_api.nim падал с "Package
# gtk4 was not found in the pkg-config search path", и текст этой ошибки
# (с обратными кавычками) утекал прямо в аргументы gcc.
# ------------------------------------------------------------------------------
var pkgConfigLibDir = bp(vidstabPrefix, "lib", "pkgconfig") & ":" &
                       bp(dav1dPrefix, "lib", "pkgconfig") & ":" &
                       bp(dav1dPrefix, "lib64", "pkgconfig") & ":" &
                       bp(dav1dPrefix, "lib", "x86_64-linux-gnu", "pkgconfig")

if crossWindows:
  pkgConfigLibDir = pkgConfigLibDir & ":" & bp(x264Build, "lib", "pkgconfig") &
    # Fedora кладёт .pc для mingw64-сборок (в т.ч. mingw64-gtk4) именно
    # сюда — это стандартный путь пакетов mingw64-* в дистрибутиве, а не
    # что-то специфичное для Monolit.
    ":/usr/x86_64-w64-mingw32/sys-root/mingw/lib/pkgconfig"
  putEnv("PKG_CONFIG_LIBDIR", pkgConfigLibDir)
  putEnv("PKG_CONFIG_PATH", "")
else:
  # На нативной сборке системную libx264-devel не трогаем — vidstab и
  # dav1d добавляем в PKG_CONFIG_PATH рядом с уже видимыми системными .pc
  # (gtk4.pc там уже виден стандартными путями pkg-config, трогать не надо).
  putEnv("PKG_CONFIG_PATH", pkgConfigLibDir)

proc ensureMingwGtk4() =
  ## Проверка ДО компиляции Nim-исходников: если pkg-config не видит gtk4
  ## для mingw-таргета, падаем сразу с понятным сообщением — вместо того,
  ## чтобы дать src/gtk4_api.nim впустить текст ошибки pkg-config прямо в
  ## аргументы gcc (см. обоснование выше).
  let r = gorgeEx("pkg-config --exists gtk4")
  if r.exitCode != 0:
    echo "[config.nims] [ERROR] pkg-config не находит gtk4 для mingw64. " &
         "Установите рантайм/dev-пакет GTK4 для mingw64, например " &
         "`sudo dnf install mingw64-gtk4` (см. README.md, «Почему GTK4 не " &
         "статический»), либо, если он ставится не в стандартный sys-root, " &
         "укажите его каталог pkgconfig в PKG_CONFIG_LIBDIR перед сборкой."
    quit(1)

if crossWindows:
  ensureMingwGtk4()

if allLibsExist(libDir):
  echo fmt"[config.nims] Готовые библиотеки FFmpeg найдены в {libDir} — пропускаем сборку."
else:
  echo "[config.nims] Статические библиотеки FFmpeg не найдены, начинаем сборку."
  if not fileExists(bp(ffmpegSrc, "configure")):
    cloneRepo("https://github.com/FFmpeg/FFmpeg.git", ffmpegSrc, ffmpegBranch)
  buildFFmpeg(ffmpegSrc, buildDir, crossWindows, x264Build, vidstabPrefix, dav1dPrefix)
  if not allLibsExist(libDir):
    echo "[config.nims] [ERROR] Сборка FFmpeg завершилась, но .a не найдены."
    quit(1)

# ------------------------------------------------------------------------------
# Флаги компилятора/линковщика Nim
# ------------------------------------------------------------------------------
switch("passC", fmt"-I{incDir}")

if crossWindows:
  let mingwGcc = ensureMingwToolchain()
  switch("gcc.exe", mingwGcc)
  switch("gcc.linkerexe", mingwGcc)
  # GTK4 под Windows должен резолвиться через mingw64 sysroot — если
  # разработчик уже настроил PKG_CONFIG_* для mingw в окружении, эти
  # exec-вызовы (см. src/gtk4_api.nim, {.passC/passL: gorge(...).}) вернут
  # корректные флаги; Monolit сам их не переопределяет.

proc findDav1dLib(prefix: string): string =
  for cand in [bp(prefix, "lib", "libdav1d.a"),
               bp(prefix, "lib64", "libdav1d.a"),
               bp(prefix, "lib", "x86_64-linux-gnu", "libdav1d.a")]:
    if fileExists(cand): return cand
  echo "[config.nims] [ERROR] libdav1d.a не найдена ни в одном из ожидаемых " &
       "подкаталогов " & prefix & "/{lib,lib64,lib/x86_64-linux-gnu}."
  quit(1)

switch("passL", "-Wl,--start-group")
for libName in ffmpegLibs:
  switch("passL", bp(libDir, libName))
switch("passL", bp(vidstabPrefix, "lib", "libvidstab.a"))
switch("passL", findDav1dLib(dav1dPrefix))
switch("passL", "-Wl,--end-group")

# libvidstab собирается с OpenMP (motiondetect.c использует #pragma omp —
# find_package(OpenMP) в CMakeLists.txt самого vid.stab добавляет -fopenmp
# ТОЛЬКО на время сборки vidstab_build/lib/libvidstab.a). Эта настройка не
# передаётся дальше: когда мы линкуем готовую libvidstab.a напрямую в
# Monolit, gcc ничего не знает про OpenMP и не подтягивает рантайм —
# отсюда undefined reference на omp_get_num_threads, GOMP_parallel и т.п.
# -fopenmp на линковке (в отличие от -lgomp вручную) — самодостаточный
# способ: gcc сам добавляет -lgomp и нужную инициализацию рантайма.
switch("passL", "-fopenmp")

if crossWindows:
  switch("passL", bp(x264Build, "lib", "libx264.a"))
  switch("passL", "-lz"); switch("passL", "-lbz2"); switch("passL", "-llzma")
  switch("passL", "-lm")
  switch("passL", "-lws2_32"); switch("passL", "-lsecur32"); switch("passL", "-lbcrypt")
  switch("passL", "-lwinpthread")
  # Статично только медиа-часть — GTK4 остаётся динамической зависимостью
  # (см. src/gtk4_api.nim), поэтому "-static" здесь НЕ ставится глобально,
  # в отличие от PMI: тотальный -static конфликтовал бы с -lgtk-4 и т.п.
else:
  switch("passL", "-lx264")
  switch("passL", "-lz"); switch("passL", "-lbz2"); switch("passL", "-llzma")
  switch("passL", "-lpthread"); switch("passL", "-lm"); switch("passL", "-ldl")

switch("mm", "orc")
switch("threads", "on")

# ------------------------------------------------------------------------------
# Задача упаковки Windows-дистрибутива: Monolit.exe + рантайм GTK4 рядом.
# Запуск: nim --os:windows package.nims   (отдельный вспомогательный скрипт,
# см. README.md) — здесь только напоминание, сама логика вынесена, чтобы
# не запускать её при каждой обычной компиляции.
# ------------------------------------------------------------------------------
