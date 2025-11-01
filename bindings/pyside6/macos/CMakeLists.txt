cmake_minimum_required(VERSION 3.21)

# Python + Shiboken6 + PySide6
find_package(Python3 REQUIRED COMPONENTS Interpreter Development.Module)
find_program(SHIBOKEN6_GEN shiboken6 REQUIRED)

# --- Locate Homebrew + Qt prefix locally (root is minimal)
if(NOT DEFINED QT_HOMEBREW_ROOT OR QT_HOMEBREW_ROOT STREQUAL "")
  find_program(BREW_EXECUTABLE NAMES brew HINTS /opt/homebrew/bin /usr/local/bin)
  if(NOT BREW_EXECUTABLE)
    message(FATAL_ERROR "Homebrew 'brew' not found. Please install Homebrew or add it to PATH.")
  endif()
  execute_process(
    COMMAND "${BREW_EXECUTABLE}" --prefix qt
    OUTPUT_VARIABLE QT_HOMEBREW_ROOT
    OUTPUT_STRIP_TRAILING_WHITESPACE
    RESULT_VARIABLE _brew_qt_res
  )
  if(NOT _brew_qt_res EQUAL 0 OR QT_HOMEBREW_ROOT STREQUAL "")
    execute_process(
      COMMAND "${BREW_EXECUTABLE}" --prefix qt@6
      OUTPUT_VARIABLE QT_HOMEBREW_ROOT
      OUTPUT_STRIP_TRAILING_WHITESPACE
      RESULT_VARIABLE _brew_qt6_res
    )
    if(NOT _brew_qt6_res EQUAL 0 OR QT_HOMEBREW_ROOT STREQUAL "")
      message(FATAL_ERROR "Failed to query Homebrew for Qt prefix (tried 'qt' and 'qt@6'). Try `brew install qt`.")
    endif()
  endif()
endif()
if(NOT IS_DIRECTORY "${QT_HOMEBREW_ROOT}")
  message(FATAL_ERROR "QT_HOMEBREW_ROOT is not a valid directory: '${QT_HOMEBREW_ROOT}'.")
endif()

# --- Derive PySide6 Qt frameworks dir from the venv (PySide6/Qt/lib)
if(NOT DEFINED PYSIDE_QT_LIBDIR)
  execute_process(
    COMMAND ${Python3_EXECUTABLE} -c "import os, PySide6; print(os.path.join(os.path.dirname(PySide6.__file__), 'Qt', 'lib'))"
    OUTPUT_VARIABLE PYSIDE_QT_LIBDIR
    OUTPUT_STRIP_TRAILING_WHITESPACE
  )
endif()
if(NOT EXISTS "${PYSIDE_QT_LIBDIR}")
  message(FATAL_ERROR "PySide6 Qt frameworks not found: ${PYSIDE_QT_LIBDIR}")
endif()

# --- Explicit framework binaries inside the venv
set(QTCORE_BIN    "${PYSIDE_QT_LIBDIR}/QtCore.framework/Versions/A/QtCore")
set(QTGUI_BIN     "${PYSIDE_QT_LIBDIR}/QtGui.framework/Versions/A/QtGui")
set(QTWIDGETS_BIN "${PYSIDE_QT_LIBDIR}/QtWidgets.framework/Versions/A/QtWidgets")
foreach(_f ${QTCORE_BIN} ${QTGUI_BIN} ${QTWIDGETS_BIN})
  if(NOT EXISTS "${_f}")
    message(FATAL_ERROR "Framework binary not found: ${_f}")
  endif()
endforeach()

# --- Qt header shim (SDK headers from Homebrew)
set(QT_FRAMEWORKS_DIR "${QT_HOMEBREW_ROOT}/Frameworks")
foreach(_mod QtCore QtGui QtWidgets)
  if(NOT EXISTS "${QT_FRAMEWORKS_DIR}/${_mod}.framework/Headers")
    message(FATAL_ERROR "Missing ${_mod}.framework/Headers under: ${QT_FRAMEWORKS_DIR}")
  endif()
endforeach()
set(QT_HDRSHIM "${CMAKE_BINARY_DIR}/qt_hdrshim")
file(MAKE_DIRECTORY "${QT_HDRSHIM}")
file(CREATE_LINK "${QT_FRAMEWORKS_DIR}/QtCore.framework/Headers"    "${QT_HDRSHIM}/QtCore"    SYMBOLIC)
file(CREATE_LINK "${QT_FRAMEWORKS_DIR}/QtGui.framework/Headers"     "${QT_HDRSHIM}/QtGui"     SYMBOLIC)
file(CREATE_LINK "${QT_FRAMEWORKS_DIR}/QtWidgets.framework/Headers" "${QT_HDRSHIM}/QtWidgets" SYMBOLIC)

# --- Locate frameworks (from venv) for CMake’s linker
find_library(QTCORE_FW    NAMES QtCore    PATHS "${PYSIDE_QT_LIBDIR}" NO_DEFAULT_PATH REQUIRED)
find_library(QTGUI_FW     NAMES QtGui     PATHS "${PYSIDE_QT_LIBDIR}" NO_DEFAULT_PATH REQUIRED)
find_library(QTWIDGETS_FW NAMES QtWidgets PATHS "${PYSIDE_QT_LIBDIR}" NO_DEFAULT_PATH REQUIRED)

# --- Typesystem dirs from venv
execute_process(
  COMMAND ${Python3_EXECUTABLE} -c "import os,shiboken6;print(os.path.join(os.path.dirname(shiboken6.__file__),'typesystems'))"
  OUTPUT_VARIABLE SHIBOKEN_TYPESYS
  OUTPUT_STRIP_TRAILING_WHITESPACE
)
execute_process(
  COMMAND ${Python3_EXECUTABLE} -c "import os,PySide6;print(os.path.join(os.path.dirname(PySide6.__file__),'typesystems'))"
  OUTPUT_VARIABLE PYSIDE_TYPESYS
  OUTPUT_STRIP_TRAILING_WHITESPACE
)

# --- Shiboken include (runtime first, fallback to generator)
execute_process(
  COMMAND ${Python3_EXECUTABLE} -c "import os,importlib; m=importlib.import_module('shiboken6'); print(os.path.join(os.path.dirname(m.__file__),'include'))"
  OUTPUT_VARIABLE SHIBOKEN_INCLUDE_DIR
  OUTPUT_STRIP_TRAILING_WHITESPACE
)
if(NOT EXISTS "${SHIBOKEN_INCLUDE_DIR}/shiboken.h")
  execute_process(
    COMMAND ${Python3_EXECUTABLE} -c "import os,importlib; m=importlib.import_module('shiboken6_generator'); print(os.path.join(os.path.dirname(m.__file__),'include'))"
    OUTPUT_VARIABLE SHIBOKEN_INCLUDE_DIR
    OUTPUT_STRIP_TRAILING_WHITESPACE
  )
endif()
if(NOT EXISTS "${SHIBOKEN_INCLUDE_DIR}/shiboken.h")
  message(FATAL_ERROR "Cannot find shiboken.h in shiboken6/include nor shiboken6_generator/include.")
endif()
message(STATUS "Shiboken include dir: ${SHIBOKEN_INCLUDE_DIR}")

# --- Shiboken runtime library
execute_process(
  COMMAND ${Python3_EXECUTABLE} -c "import os,glob,importlib; d=os.path.dirname(importlib.import_module('shiboken6').__file__); m=glob.glob(os.path.join(d,'libshiboken*.dylib')) or glob.glob(os.path.join(d,'libshiboken*.so*')); print(m[0] if m else '')"
  OUTPUT_VARIABLE SHIBOKEN_LIBRARY
  OUTPUT_STRIP_TRAILING_WHITESPACE
)
if(NOT SHIBOKEN_LIBRARY)
  execute_process(
    COMMAND ${Python3_EXECUTABLE} -c "import os,glob,importlib; d=os.path.dirname(importlib.import_module('PySide6').__file__); m=glob.glob(os.path.join(d,'libshiboken*.dylib')) or glob.glob(os.path.join(d,'libshiboken*.so*')); print(m[0] if m else '')"
    OUTPUT_VARIABLE SHIBOKEN_LIBRARY
    OUTPUT_STRIP_TRAILING_WHITESPACE
  )
endif()
if(NOT SHIBOKEN_LIBRARY)
  message(FATAL_ERROR "libshiboken*.dylib/.so not found in the venv.")
endif()
message(STATUS "Shiboken library: ${SHIBOKEN_LIBRARY}")

# --- PySide6 include & library
execute_process(
  COMMAND ${Python3_EXECUTABLE} -c "import os, PySide6; print(os.path.join(os.path.dirname(PySide6.__file__), 'include'))"
  OUTPUT_VARIABLE PYSIDE_INCLUDE_DIR
  OUTPUT_STRIP_TRAILING_WHITESPACE
)
execute_process(
  COMMAND ${Python3_EXECUTABLE} -c "import os, glob, PySide6 as P; d=os.path.dirname(P.__file__); m=sorted(glob.glob(os.path.join(d,'libpyside6.abi3*.dylib'))+glob.glob(os.path.join(d,'libpyside6.abi3*.so*'))); print(m[0] if m else '')"
  OUTPUT_VARIABLE PYSIDE_LIBRARY
  OUTPUT_STRIP_TRAILING_WHITESPACE
)
if(NOT PYSIDE_LIBRARY)
  message(FATAL_ERROR "libpyside6.abi3*.dylib not found in the PySide6 venv.")
endif()
message(STATUS "PySide library   : ${PYSIDE_LIBRARY}")
get_filename_component(PYSIDE_LIB_DIR "${PYSIDE_LIBRARY}" DIRECTORY)

# --- Include paths for Shiboken generator
set(SHIBOKEN_INCLUDE_LIST
  "${QT_HDRSHIM}"                             # QtCore/QtGui/QtWidgets shim
  "${PROJECT_SOURCE_DIR}/src/macos"           # your native headers (fixed path)
  "${SHIBOKEN_INCLUDE_DIR}"                   # shiboken.h
  "${QT_HOMEBREW_ROOT}/Frameworks/QtCore.framework/Headers/"
  "${QT_HOMEBREW_ROOT}/Frameworks/QtGui.framework/Headers/"
  "${QT_HOMEBREW_ROOT}/Frameworks/QtWidgets.framework/Headers/"
)
if(EXISTS "${PYSIDE_INCLUDE_DIR}")
  list(APPEND SHIBOKEN_INCLUDE_LIST
    "${PYSIDE_INCLUDE_DIR}"
    "${PYSIDE_INCLUDE_DIR}/QtCore"
    "${PYSIDE_INCLUDE_DIR}/QtGui"
    "${PYSIDE_INCLUDE_DIR}/QtWidgets"
  )
endif()
list(JOIN SHIBOKEN_INCLUDE_LIST ":" SHIBOKEN_INCLUDE_ARG)
message(STATUS "Shiboken include paths:\n  ${SHIBOKEN_INCLUDE_ARG}")

# --- Shiboken code generation
set(GEN_DIR ${CMAKE_CURRENT_BINARY_DIR}/shiboken_out)
file(MAKE_DIRECTORY ${GEN_DIR})

set(HEADERS    "${PROJECT_SOURCE_DIR}/src/macos/WKWebViewWidget.h")  # fixed
set(TYPESYSTEM "${CMAKE_CURRENT_SOURCE_DIR}/typesystem_wkwebview.xml")

message(STATUS "Running shiboken6: output -> ${GEN_DIR}")
execute_process(
  COMMAND "${SHIBOKEN6_GEN}"
          --generator-set=shiboken
          --enable-pyside-extensions
          --include-paths=${SHIBOKEN_INCLUDE_ARG}
          --typesystem-paths=${SHIBOKEN_TYPESYS}
          --typesystem-paths=${PYSIDE_TYPESYS}
          --output-directory=${GEN_DIR}
          ${HEADERS}
          ${TYPESYSTEM}
  RESULT_VARIABLE SHIBOKEN_RV
  OUTPUT_VARIABLE SHIBOKEN_STDOUT
  ERROR_VARIABLE  SHIBOKEN_STDERR
  WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
)
if (NOT SHIBOKEN_RV EQUAL 0)
  message(STATUS "Shiboken stdout:\n${SHIBOKEN_STDOUT}")
  message(STATUS "Shiboken stderr:\n${SHIBOKEN_STDERR}")
  message(FATAL_ERROR "Shiboken generation failed with code ${SHIBOKEN_RV}")
endif()

file(GLOB_RECURSE SHIBOKEN_SRCS ${GEN_DIR}/*.cpp)
if (SHIBOKEN_SRCS STREQUAL "")
  message(FATAL_ERROR "No sources generated in ${GEN_DIR}")
endif()

# --- Python extension module
add_library(_wkwebview MODULE ${SHIBOKEN_SRCS})
target_compile_features(_wkwebview PRIVATE cxx_std_17)

# Installa l'estensione nella cartella del pacchetto Python
install(TARGETS _wkwebview
  LIBRARY DESTINATION fit_webview_bridge            # macOS/Linux (.so)
  RUNTIME DESTINATION fit_webview_bridge            # Windows (.pyd/.dll)
)
# (se il nome finale deve essere "wkwebview", lascia PREFIX/SUFFIX come già fai)

# Correct Python extension suffix (e.g. .cpython-311-darwin.so)
execute_process(
  COMMAND ${Python3_EXECUTABLE} -c "import sysconfig; print(sysconfig.get_config_var('EXT_SUFFIX') or '.so')"
  OUTPUT_VARIABLE PY_EXT_SUFFIX
  OUTPUT_STRIP_TRAILING_WHITESPACE
)

# Includes
target_include_directories(_wkwebview PRIVATE
  ${GEN_DIR}
  "${PROJECT_SOURCE_DIR}/src/macos"
  ${Python3_INCLUDE_DIRS}
  ${SHIBOKEN_INCLUDE_DIR}
  ${QT_HDRSHIM}
  "${QT_HOMEBREW_ROOT}/Frameworks/QtCore.framework/Headers/"
  "${QT_HOMEBREW_ROOT}/Frameworks/QtGui.framework/Headers/"
  "${QT_HOMEBREW_ROOT}/Frameworks/QtWidgets.framework/Headers/"
)
if(EXISTS "${PYSIDE_INCLUDE_DIR}")
  target_include_directories(_wkwebview PRIVATE
    "${PYSIDE_INCLUDE_DIR}"
    "${PYSIDE_INCLUDE_DIR}/QtCore"
    "${PYSIDE_INCLUDE_DIR}/QtGui"
    "${PYSIDE_INCLUDE_DIR}/QtWidgets"
  )
endif()

# Link search paths (Qt frameworks from the venv)
target_link_directories(_wkwebview PRIVATE "${PYSIDE_QT_LIBDIR}")

# Link: Qt frameworks (venv) + shiboken + pyside + Python module + native lib
target_link_libraries(_wkwebview PRIVATE
  "${QTCORE_BIN}"
  "${QTGUI_BIN}"
  "${QTWIDGETS_BIN}"
  "${SHIBOKEN_LIBRARY}"
  "${PYSIDE_LIBRARY}"
  Python3::Module
  wkwebview
)

# RPATHs for runtime on macOS
get_filename_component(SHIBOKEN_LIB_DIR "${SHIBOKEN_LIBRARY}" DIRECTORY)

option(FITWVB_VENDORIZE "Vendorize PySide/Qt lookup via @loader_path" ON)

set_target_properties(_wkwebview PROPERTIES
  PREFIX "" OUTPUT_NAME "wkwebview" SUFFIX "${PY_EXT_SUFFIX}"
  MACOSX_RPATH ON BUILD_WITH_INSTALL_RPATH ON
)

if(FITWVB_VENDORIZE)
  set_target_properties(_wkwebview PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${PROJECT_SOURCE_DIR}/fit_webview_bridge"
  )
  set_property(TARGET _wkwebview APPEND PROPERTY BUILD_RPATH
    "@loader_path" "@loader_path/../PySide6" "@loader_path/../PySide6/Qt/lib" "@loader_path/../shiboken6")
  set_property(TARGET _wkwebview APPEND PROPERTY INSTALL_RPATH
    "@loader_path" "@loader_path/../PySide6" "@loader_path/../PySide6/Qt/lib" "@loader_path/../shiboken6")
else()
  set_target_properties(_wkwebview PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
  )
  set_property(TARGET _wkwebview APPEND PROPERTY BUILD_RPATH
    "@loader_path" "${PYSIDE_QT_LIBDIR}" "${SHIBOKEN_LIB_DIR}" "${PYSIDE_LIB_DIR}")
  set_property(TARGET _wkwebview APPEND PROPERTY INSTALL_RPATH
    "@loader_path" "${PYSIDE_QT_LIBDIR}" "${SHIBOKEN_LIB_DIR}" "${PYSIDE_LIB_DIR}")
endif()