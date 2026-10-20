@echo off
rem Direct MSVC build of the Flutter Windows chain (no CMake, no flutter tool).
rem Mirrors what app/windows/CMakeLists.txt + flutter/CMakeLists.txt would do:
rem runner + generated registrant + engine wrapper + our plugin, linked against
rem flutter_windows.dll.lib. Used to verify the C++ side on machines where the
rem flutter tool cannot run; `flutter build windows` is the real build.
setlocal
if not defined ROOT set "ROOT=%~dp0.."
for %%i in ("%ROOT%") do set "ROOT=%%~fi"
set "VS=%LP_VS_DIR%"
if not defined VS (
  for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -property installationPath`) do set "VS=%%i"
)
if not defined VS (
  echo could not locate Visual Studio ^(install the C++ desktop workload^) & exit /b 1
)
set ART=%ROOT%\.tools\flutter-sdk\bin\cache\artifacts\engine\windows-x64
set EPH=%ROOT%\app\windows\flutter\ephemeral
if "%~1"=="" (set OUT=%ROOT%\build\msvc-chain) else (set OUT=%~1)
set OBJ=%OUT%\obj

call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 (echo vcvars failed & exit /b 1)
if not exist "%OBJ%" mkdir "%OBJ%"

rem App state for runs: a normal install uses %APPDATA%\lanplayer, but a
rem sandboxed child process may not write outside the project, so running
rem under one should set LP_STATE_DIR to a folder inside the project.
if not defined LP_STATE_DIR set "LP_STATE_DIR=%OUT%\state"

set CXX=/nologo /EHsc /std:c++17 /W4 /WX /wd4100 /MD /O2 /DNDEBUG
set DEFS=/DUNICODE /D_UNICODE /DNOMINMAX /DFLUTTER_VERSION=\"3.27.4\" /DFLUTTER_VERSION_MAJOR=3 /DFLUTTER_VERSION_MINOR=27 /DFLUTTER_VERSION_PATCH=4 /DFLUTTER_VERSION_BUILD=0
set INC=/I"%EPH%" /I"%EPH%\cpp_client_wrapper\include" /I"%ROOT%\app\windows" /I"%ROOT%\app\windows\runner" /I"%ROOT%\app\windows\flutter" /I"%ROOT%\packages\lanplayer_video\windows" /I"%ROOT%\packages\lanplayer_video\windows\include"

echo === compile runner + registrant + wrapper ===
cl %CXX% %DEFS% %INC% /c "%ROOT%\app\windows\runner\main.cpp" /Fo"%OBJ%\main.obj" || exit /b 1
cl %CXX% %DEFS% %INC% /c "%ROOT%\app\windows\runner\flutter_window.cpp" /Fo"%OBJ%\flutter_window.obj" || exit /b 1
cl %CXX% %DEFS% %INC% /c "%ROOT%\app\windows\runner\win32_window.cpp" /Fo"%OBJ%\win32_window.obj" || exit /b 1
cl %CXX% %DEFS% %INC% /c "%ROOT%\app\windows\runner\utils.cpp" /Fo"%OBJ%\utils.obj" || exit /b 1
cl %CXX% %DEFS% %INC% /c "%ROOT%\app\windows\flutter\generated_plugin_registrant.cc" /Fo"%OBJ%\registrant.obj" || exit /b 1
cl %CXX% %DEFS% %INC% /c "%EPH%\cpp_client_wrapper\core_implementations.cc" /Fo"%OBJ%\core_impl.obj" || exit /b 1
cl %CXX% %DEFS% %INC% /c "%EPH%\cpp_client_wrapper\standard_codec.cc" /Fo"%OBJ%\standard_codec.obj" || exit /b 1
cl %CXX% %DEFS% %INC% /c "%EPH%\cpp_client_wrapper\flutter_engine.cc" /Fo"%OBJ%\flutter_engine.obj" || exit /b 1
cl %CXX% %DEFS% %INC% /c "%EPH%\cpp_client_wrapper\flutter_view_controller.cc" /Fo"%OBJ%\view_controller.obj" || exit /b 1
cl %CXX% %DEFS% %INC% /c "%EPH%\cpp_client_wrapper\plugin_registrar.cc" /Fo"%OBJ%\plugin_registrar.obj" || exit /b 1

echo === compile plugin (dll) ===
cl %CXX% %DEFS% /DFLUTTER_PLUGIN_IMPL %INC% /c "%ROOT%\packages\lanplayer_video\windows\lanplayer_video_plugin.cpp" /Fo"%OBJ%\plugin.obj" || exit /b 1

echo === link lanplayer_video_plugin.dll ===
rem flutter_wrapper_plugin = core_implementations + standard_codec + plugin_registrar
link /nologo /DLL /OUT:"%OUT%\lanplayer_video_plugin.dll" /IMPLIB:"%OUT%\lanplayer_video_plugin.lib" ^
  "%OBJ%\plugin.obj" "%OBJ%\core_impl.obj" "%OBJ%\standard_codec.obj" "%OBJ%\plugin_registrar.obj" ^
  "%ART%\flutter_windows.dll.lib" user32.lib version.lib ole32.lib shell32.lib || exit /b 1

echo === link lanplayer.exe ===
link /nologo /OUT:"%OUT%\lanplayer.exe" /SUBSYSTEM:WINDOWS ^
  "%OBJ%\main.obj" "%OBJ%\flutter_window.obj" "%OBJ%\win32_window.obj" "%OBJ%\utils.obj" ^
  "%OBJ%\registrant.obj" "%OBJ%\core_impl.obj" "%OBJ%\standard_codec.obj" ^
  "%OBJ%\flutter_engine.obj" "%OBJ%\view_controller.obj" ^
  "%OUT%\lanplayer_video_plugin.lib" ^
  "%ART%\flutter_windows.dll.lib" dwmapi.lib user32.lib gdi32.lib shell32.lib ole32.lib advapi32.lib || exit /b 1

echo === ok ===
dir /b "%OUT%\*.exe" "%OUT%\*.dll" 2>nul
endlocal
exit /b 0
