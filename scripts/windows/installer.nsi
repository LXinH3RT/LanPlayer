; LanPlayer Windows 安装包脚本（NSIS 3.x）
;
; 用法（由 scripts\build_windows_installer.ps1 调用）：
;   makensis.exe /DAPP_VERSION=0.1.0 /DSTAGE=<暂存目录> /DOUTFILE=<输出 exe> \
;                /DAPP_ICON=<图标 ico> installer.nsi
;
; 设计取舍：
;   * 按当前用户安装到 %LOCALAPPDATA%\Programs\LanPlayer，不需要管理员权限，
;     也不会往 Program Files 写 —— 这样「双击就能用」而不弹 UAC。
;   * FFmpeg 的 av*.dll 与 VC++ 运行库全部 app-local 打包（暂存目录里已带），
;     用户不需要另装 Visual C++ Redistributable。
;   * 卸载时不删用户数据（服务器列表、设置、缩略图缓存），只在结束时提示位置。

Unicode true
SetCompressor /SOLID lzma
SetCompressorDictSize 64

!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "LogicLib.nsh"
!include "WinVer.nsh"

; ---- 由命令行传入（有默认值，便于直接右键编译调试）----
!ifndef APP_VERSION
  !define APP_VERSION "0.1.0"
!endif
!ifndef STAGE
  !define STAGE "..\..\dist\stage\windows"
!endif
!ifndef OUTFILE
  !define OUTFILE "..\..\dist\LanPlayer-${APP_VERSION}-windows-x64-setup.exe"
!endif
!ifndef APP_ICON
  !define APP_ICON "..\..\app\windows\runner\resources\app_icon.ico"
!endif

!define APP_NAME    "LanPlayer"
!define APP_PUBLISHER "LanPlayer"
!define APP_EXE     "lanplayer.exe"
!define APP_ID      "LanPlayer"
!define UNINST_KEY  "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}"

Name "${APP_NAME} ${APP_VERSION}"
OutFile "${OUTFILE}"
InstallDir "$LOCALAPPDATA\Programs\${APP_NAME}"
InstallDirRegKey HKCU "Software\${APP_ID}" "InstallDir"
RequestExecutionLevel user
BrandingText "${APP_NAME} ${APP_VERSION}"

VIProductVersion "${APP_VERSION}.0"
VIAddVersionKey /LANG=2052 "ProductName"     "${APP_NAME}"
VIAddVersionKey /LANG=2052 "FileDescription" "${APP_NAME} 安装程序"
VIAddVersionKey /LANG=2052 "FileVersion"     "${APP_VERSION}"
VIAddVersionKey /LANG=2052 "ProductVersion"  "${APP_VERSION}"
VIAddVersionKey /LANG=2052 "CompanyName"     "${APP_PUBLISHER}"
VIAddVersionKey /LANG=2052 "LegalCopyright"  "MIT License"

; ---------------- 界面 ----------------
!define MUI_ABORTWARNING
!define MUI_ICON   "${APP_ICON}"
!define MUI_UNICON "${APP_ICON}"
!define MUI_FINISHPAGE_RUN "$INSTDIR\${APP_EXE}"
!define MUI_FINISHPAGE_RUN_TEXT "立即启动 ${APP_NAME}"
!define MUI_FINISHPAGE_SHOWREADME ""
!define MUI_FINISHPAGE_SHOWREADME_NOTCHECKED
!define MUI_FINISHPAGE_LINK "项目主页：https://github.com/LXinH3RT/LanPlayer"
!define MUI_FINISHPAGE_LINK_LOCATION "https://github.com/LXinH3RT/LanPlayer"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "..\..\LICENSE"
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

; ---------------- 组件说明 ----------------
LangString DESC_Core      ${LANG_SIMPCHINESE} "LanPlayer 主程序、Flutter 运行时、FFmpeg 解码库。必装。"
LangString DESC_Core      ${LANG_ENGLISH}     "LanPlayer, Flutter runtime and FFmpeg decoders. Required."
LangString DESC_Shortcut  ${LANG_SIMPCHINESE} "在桌面和开始菜单创建快捷方式。"
LangString DESC_Shortcut  ${LANG_ENGLISH}     "Create Desktop and Start Menu shortcuts."
LangString DESC_Assoc     ${LANG_SIMPCHINESE} "把常见视频格式（mp4/mkv/avi/mov/ts/m4v）关联到 LanPlayer。"
LangString DESC_Assoc     ${LANG_ENGLISH}     "Associate common video files (mp4/mkv/avi/mov/ts/m4v) with LanPlayer."

; ---------------- 主安装段 ----------------
Section "LanPlayer 主程序" SecCore
  SectionIn RO
  SetShellVarContext current
  SetOutPath "$INSTDIR"
  ; 主程序 + 所有 DLL（逐文件打包，便于将来做差分升级）
  File "${STAGE}\${APP_EXE}"
  File "${STAGE}\lanplayer.dll"
  File "${STAGE}\lanplayer_video_plugin.dll"
  File "${STAGE}\flutter_windows.dll"
  File "${STAGE}\avcodec-63.dll"
  File "${STAGE}\avfilter-12.dll"
  File "${STAGE}\avformat-63.dll"
  File "${STAGE}\avutil-61.dll"
  File "${STAGE}\swresample-7.dll"
  File "${STAGE}\swscale-10.dll"
  File "${STAGE}\msvcp140.dll"
  File "${STAGE}\msvcp140_1.dll"
  File "${STAGE}\msvcp140_2.dll"
  File "${STAGE}\vcruntime140.dll"
  File "${STAGE}\vcruntime140_1.dll"
  File "${STAGE}\concrt140.dll"

  ; Flutter 资源目录（data\app.so、flutter_assets、icudtl.dat）
  SetOutPath "$INSTDIR\data"
  File /r "${STAGE}\data\*.*"
  SetOutPath "$INSTDIR"

  ; 卸载信息
  WriteRegStr HKCU "Software\${APP_ID}" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\${APP_ID}" "Version" "${APP_VERSION}"
  WriteUninstaller "$INSTDIR\uninstall.exe"

  ; ${GetSize} 的 $0 就是以 KB 为单位的大小（/S=0K），正好是 EstimatedSize 要的单位
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  WriteRegStr   HKCU "${UNINST_KEY}" "DisplayName"     "${APP_NAME}"
  WriteRegStr   HKCU "${UNINST_KEY}" "DisplayVersion"  "${APP_VERSION}"
  WriteRegStr   HKCU "${UNINST_KEY}" "DisplayIcon"     "$INSTDIR\${APP_EXE}"
  WriteRegStr   HKCU "${UNINST_KEY}" "Publisher"       "${APP_PUBLISHER}"
  WriteRegStr   HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr   HKCU "${UNINST_KEY}" "UninstallString" "$\"$INSTDIR\uninstall.exe$\""
  WriteRegStr   HKCU "${UNINST_KEY}" "QuietUninstallString" "$\"$INSTDIR\uninstall.exe$\" /S"
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify"        1
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair"        1
  WriteRegDWORD HKCU "${UNINST_KEY}" "EstimatedSize"   $0
SectionEnd

Section "快捷方式" SecShortcut
  SetShellVarContext current
  CreateDirectory "$SMPROGRAMS\${APP_NAME}"
  CreateShortCut "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}" "" "$INSTDIR\${APP_EXE}" 0
  CreateShortCut "$SMPROGRAMS\${APP_NAME}\卸载 ${APP_NAME}.lnk" "$INSTDIR\uninstall.exe"
  CreateShortCut "$DESKTOP\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}" "" "$INSTDIR\${APP_EXE}" 0
SectionEnd

Section /o "关联视频文件" SecAssoc
  WriteRegStr HKCU "Software\Classes\${APP_ID}.Video" "" "视频文件"
  WriteRegStr HKCU "Software\Classes\${APP_ID}.Video\DefaultIcon" "" "$INSTDIR\${APP_EXE},0"
  WriteRegStr HKCU "Software\Classes\${APP_ID}.Video\shell\open\command" "" "$\"$INSTDIR\${APP_EXE}$\" $\"%1$\""
  ${For} $R0 1 6
    ${If} $R0 == 1
      StrCpy $R1 ".mp4"
    ${ElseIf} $R0 == 2
      StrCpy $R1 ".mkv"
    ${ElseIf} $R0 == 3
      StrCpy $R1 ".avi"
    ${ElseIf} $R0 == 4
      StrCpy $R1 ".mov"
    ${ElseIf} $R0 == 5
      StrCpy $R1 ".ts"
    ${Else}
      StrCpy $R1 ".m4v"
    ${EndIf}
    WriteRegStr HKCU "Software\Classes\$R1\OpenWithProgids" "${APP_ID}.Video" ""
  ${Next}
SectionEnd

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecCore}     $(DESC_Core)
  !insertmacro MUI_DESCRIPTION_TEXT ${SecShortcut} $(DESC_Shortcut)
  !insertmacro MUI_DESCRIPTION_TEXT ${SecAssoc}    $(DESC_Assoc)
!insertmacro MUI_FUNCTION_DESCRIPTION_END

Function .onInit
  ; 只支持 64 位 Windows 10 及以上（Flutter 桌面端的下限）
  ${IfNot} ${AtLeastWin10}
    MessageBox MB_ICONSTOP "LanPlayer 需要 Windows 10 或更高版本。"
    Abort
  ${EndIf}
FunctionEnd

; ---------------- 卸载 ----------------
Section "Uninstall"
  SetShellVarContext current
  Delete "$INSTDIR\${APP_EXE}"
  Delete "$INSTDIR\lanplayer.dll"
  Delete "$INSTDIR\lanplayer_video_plugin.dll"
  Delete "$INSTDIR\flutter_windows.dll"
  Delete "$INSTDIR\avcodec-63.dll"
  Delete "$INSTDIR\avfilter-12.dll"
  Delete "$INSTDIR\avformat-63.dll"
  Delete "$INSTDIR\avutil-61.dll"
  Delete "$INSTDIR\swresample-7.dll"
  Delete "$INSTDIR\swscale-10.dll"
  Delete "$INSTDIR\msvcp140.dll"
  Delete "$INSTDIR\msvcp140_1.dll"
  Delete "$INSTDIR\msvcp140_2.dll"
  Delete "$INSTDIR\vcruntime140.dll"
  Delete "$INSTDIR\vcruntime140_1.dll"
  Delete "$INSTDIR\concrt140.dll"
  RMDir /r "$INSTDIR\data"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"

  Delete "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\卸载 ${APP_NAME}.lnk"
  RMDir  "$SMPROGRAMS\${APP_NAME}"
  Delete "$DESKTOP\${APP_NAME}.lnk"

  DeleteRegKey HKCU "Software\Classes\${APP_ID}.Video"
  DeleteRegKey HKCU "Software\${APP_ID}"
  DeleteRegKey HKCU "${UNINST_KEY}"

  ; 用户数据（服务器列表 / 设置 / 缩略图缓存）保留，避免升级或卸载丢配置
  IfFileExists "$APPDATA\lanplayer\*.*" 0 done
    MessageBox MB_YESNO|MB_ICONQUESTION \
      "是否同时删除已保存的服务器列表、设置和缩略图缓存？$\r$\n（位于 $APPDATA\lanplayer）" \
      IDNO done
    RMDir /r "$APPDATA\lanplayer"
  done:
SectionEnd
