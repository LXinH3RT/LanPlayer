; LanPlayer Windows 安装包脚本（NSIS 3.x）
;
; 用法（由 scripts\build_windows_installer.py 调用）：
;   makensis.exe /DAPP_VERSION=0.1.0 /DSTAGE=<暂存目录> /DOUTFILE=<输出 exe> \
;                /DAPP_ICON=<图标 ico> installer.nsi
;
; 设计取舍：
;   * 按当前用户安装到 %LOCALAPPDATA%\Programs\LanPlayer，不需要管理员权限，
;     也不会往 Program Files 写 —— 这样「双击就能用」而不弹 UAC。
;   * FFmpeg 的 av*.dll 与 VC++ 运行库全部 app-local 打包（暂存目录里已带），
;     用户不需要另装 Visual C++ Redistributable。
;   * 卸载时默认保留用户数据（服务器列表、设置、缩略图缓存），但在卸载选项页里
;     给一个「同时删除」的勾选项（默认不勾），静默卸载要显式给 /PURGE 才删。
;     数据目录不止一处，见 PurgeUserData 宏。

Unicode true
SetCompressor /SOLID lzma
SetCompressorDictSize 64

!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "LogicLib.nsh"
!include "WinVer.nsh"
!include "nsDialogs.nsh"

; ---- 由命令行传入（有默认值，便于直接右键编译调试）----
!ifndef APP_VERSION
  !define APP_VERSION "0.1.0"
!endif
; VIProductVersion 只认 X.X.X.X 四段纯数字，而本地构建号可能是
; 「0.1.8-local.3」这种形式。取前三段数字补一个 0，展示用的字符串仍用
; APP_VERSION 原样，所以「应用和功能」里看到的还是你指定的那个本地号。
!ifndef APP_VERSION_4
  !define APP_VERSION_4 "0.1.0.0"
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
; 主程序的那个 DLL。它是判断「谁还在占用安装目录」的唯一可靠依据：
; 映像名可以被复制/改名绕过，但 DLL 被映射这件事绕不过去。
!define APP_DLL     "lanplayer.dll"
!define APP_ID      "LanPlayer"
!define UNINST_KEY  "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}"

; 应用把状态目录拼成 %APPDATA%\<CompanyName>\<ProductName>\lanplayer：
; CompanyName 与 ProductName 取自 app/windows/runner/Runner.rc 的版本资源
; （path_provider_windows 的 getApplicationSupportDirectory() 按这两个字段
; 建子目录），末尾那段 lanplayer 是 app/lib/data/stores.dart 自己加的。
; 这三处必须与 Runner.rc 保持一致，否则卸载会去清一个不存在的目录 ——
; tool/check_all.py 的 check_installers() 会比对。
!define APP_COMPANY "dev.lanplayer"
!define APP_PRODUCT "lanplayer"

Name "${APP_NAME} ${APP_VERSION}"
OutFile "${OUTFILE}"
InstallDir "$LOCALAPPDATA\Programs\${APP_NAME}"
; 覆盖升级时的落点：装过一次以后就认注册表里的 InstallDir，
; 否则用户在安装向导里改过目录的话，新版本会装回默认目录，留下两份。
InstallDirRegKey HKCU "Software\${APP_ID}" "InstallDir"
RequestExecutionLevel user
BrandingText "${APP_NAME} ${APP_VERSION}"

VIProductVersion "${APP_VERSION_4}.0"
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
UninstPage custom un.UserDataPage un.UserDataPageLeave
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

; ---------------- 覆盖升级：先把旧版请退 ----------------
; 旧版还在跑的时候 lanplayer.exe 与那几个 DLL 都是已映射的映像，File 写不进去。
; 交互安装会弹「无法打开要写入的文件: ...」，用户再点「中止」，安装器就写
; 「无法写入: <路径>」并退出。静默安装更糟：它按「忽略」处理，exit code 仍是 0，
; 装完之后新旧 DLL 混搭，运行起来行为诡异。卸载也一样 —— Delete 对被映射的文件
; 是静默失败，注册表却删干净了，用户以为卸载成功，下次安装继续撞同一堵墙。
;
; 做法分四步，前一步不够才走下一步：
;   1. 按映像名请退（能被优雅关闭就优雅关闭，让它把设置写盘）；
;   2. 目标 DLL 仍不可写时，把安装目录里的每个 exe 名按映像名强杀；
;   3. 再等三秒，看它自己会不会解锁（杀毒软件的实时扫描会短暂持有句柄）；
;   4. 还被占着，就把占了它的文件改名成 <名>.old，让 File 在原文件名上写新文件。
;
; 第四步是这个安装包最关键的一处：Windows 不允许删除或覆盖被映射的映像文件
; （实测 os.remove 报拒绝访问、连所在目录都改不了名），但**允许重命名它**。
; 所以完全不必等占用方退出——把旧文件让开、写新的，装完再尽力清理 .old 即可。
; 在此之前的所有版本都栽在这一步上：交互安装弹「无法打开要写入的文件」，
; 静默安装更糟，exit code 0 却把写不进去的文件静默跳过，装完新旧混搭。
;
; 第二步为什么不是「按谁映射着 lanplayer.dll 找」——那是更直的判据，但行不通：
; tasklist /M 与 taskkill /FI "MODULES eq ..." 要在 64 位进程的模块表里查，安装器
; 本身是 32 位（RequestExecutionLevel user + 32 位 NSIS 引擎），实测这两条命令在
; nsExec 里会一直不返回（同样的命令在 cmd.exe 里 0.3 秒就结束）。所以改成枚举
; $INSTDIR\*.exe 逐个 taskkill /IM：安装目录里本来就只有 lanplayer.exe、
; uninstall.exe 与用户手动放进来的副本，按名字强杀足够准，也不会挂。
;
; 判据上有两处不能想当然：
;   * 不能用 tasklist 的退出码判断有没有在跑 —— 无匹配时它同样返回 0，只在
;     stdout 打「信息: 没有运行的任务匹配指定标准。」。判断只能靠 findstr 的输出。
;   * findstr 而不是 find：find 是 Git Bash / MSYS2 / Cygwin 都带的 GNU 工具，
;     PATH 里只要有一个 usr/bin 排在 System32 前面，cmd 就会解析到那个 find.exe。
;     GNU find 不认 /FI 与 /I，直接报错返回 1，于是「还在跑」被误判成「没在跑」。
;     findstr 只有 Windows 自带，不会被同名工具遮蔽。
;
; 「可写」用 FileOpen 追加模式探：被映射的映像文件既不能改也不能删（实测
; os.remove 报拒绝访问、目录也改不了名），打开就失败，正好当判据。

; 把被占用的文件改名让开（参数：完整路径）。
; 改名成功后原路径就空出来了，File 会在原文件名上写出新文件；旧的 <名>.old
; 仍被占用方映射着，删除会失败，所以这里只尽力删一次，删不掉留给下次安装或
; 卸载时再清（DeleteMovedAside）。
!macro MoveAsideLocked _p
  ; 先清掉上一轮可能留下的同名 .old（那时占用方早已退出，一般能删掉）
  Delete "${_p}.old"
  ClearErrors
  Rename "${_p}" "${_p}.old"
  ${If} ${Errors}
    DetailPrint "无法重命名 ${_p}，安装可能无法覆盖它。"
  ${Else}
    DetailPrint "已把占用中的 ${_p} 改名为 .old，稍后写入新版本。"
  ${EndIf}
!macroend

; 清理让开时留下的 .old（安装结束时调用）。
; 那时候新文件已经写好、旧进程也已经退出（或仍映射着但已不挡路），
; 删得掉就删，删不掉也不影响使用——下次安装或卸载的 Delete 会再试一次。
!macro DeleteMovedAside
  ; 上一次安装让开留下的 .old。此时占用方一般已退出；还占着就登记到重启后删。
  Delete /REBOOTOK "$INSTDIR\${APP_DLL}.old"
  Delete /REBOOTOK "$INSTDIR\${APP_EXE}.old"
!macroend

!macro StopRunningApp
  ; ---- 第一步：按映像名请退 ----
  nsExec::ExecToStack 'cmd /C tasklist /FI "IMAGENAME eq ${APP_EXE}" /NH | findstr /I /C:"${APP_EXE}"'
  Pop $R8
  Pop $R7   ; 输出（丢掉）

  ${If} $R8 != 0
    DetailPrint "没发现 ${APP_NAME} 在运行。"
  ${Else}
    ; 先礼后兵：不带 /F 的 taskkill 等于给它发 WM_CLOSE，会走正常退出流程，
    ; 把设置安稳写盘，也不会有「文件被占用」的残留句柄。
    nsExec::ExecToStack 'taskkill /IM "${APP_EXE}"'
    Pop $R8
    Pop $R7
    DetailPrint "已通知正在运行的 ${APP_NAME} 退出，等待它收尾。"

    StrCpy $R6 0
    ${Do}
      Sleep 500
      nsExec::ExecToStack 'cmd /C tasklist /FI "IMAGENAME eq ${APP_EXE}" /NH | findstr /I /C:"${APP_EXE}"'
      Pop $R8
      Pop $R7
      ${If} $R8 != 0
        ${ExitDo}
      ${EndIf}
      IntOp $R6 $R6 + 1
    ${LoopUntil} $R6 >= 10

    ${If} $R6 >= 10
      DetailPrint "旧版本 5 秒内没退出，强制结束。"
      nsExec::ExecToStack 'taskkill /IM "${APP_EXE}" /F'
      Pop $R8
      Pop $R7
      Sleep 600
    ${EndIf}
  ${EndIf}

  ; ---- 第二步：目标 DLL 还写不进去，就按安装目录里的 exe 名强杀 ----
  ; 只有真的写不进去才动手，避免无谓地关掉用户正在播的窗口。
  ${If} ${FileExists} "$INSTDIR\${APP_DLL}"
    ClearErrors
    FileOpen $R4 "$INSTDIR\${APP_DLL}" a
    ${If} ${Errors}
      DetailPrint "${APP_DLL} 仍被占用，结束安装目录里的可执行程序。"

      FindFirst $0 $1 "$INSTDIR\*.exe"
      ${DoWhile} $1 != ""
        nsExec::ExecToStack 'taskkill /F /IM "$1"'
        Pop $R8
        Pop $R7
        FindNext $0 $1
      ${Loop}
      FindClose $0
      Sleep 1000
    ${Else}
      FileClose $R4
    ${EndIf}
  ${EndIf}

  ; ---- 第三步：等一会儿，看占用方会不会自己松手 ----
  ; 杀进程只能解决「有人映射着」。杀毒软件的实时扫描、缩略图提取器、被别的
  ; 安装程序拉起来的副本，都可能再短暂持有句柄，所以这里给三秒余量。
  ${If} ${FileExists} "$INSTDIR\${APP_DLL}"
    StrCpy $R2 0
    ${Do}
      ClearErrors
      FileOpen $R4 "$INSTDIR\${APP_DLL}" a
      ${IfNot} ${Errors}
        FileClose $R4
        ${ExitDo}
      ${EndIf}
      Sleep 1000
      IntOp $R2 $R2 + 1
    ${LoopUntil} $R2 >= 3

    ; ---- 第四步：还被占着，就把旧文件改名让开 ----
    ; 不必再和占用方纠缠：改名之后 File 会在原文件名上写出新文件。
    ${If} $R2 >= 3
      !insertmacro MoveAsideLocked "$INSTDIR\${APP_DLL}"
      !insertmacro MoveAsideLocked "$INSTDIR\${APP_EXE}"
    ${EndIf}
  ${EndIf}
!macroend

; ---------------- 卸载时清理用户数据 ----------------
; 应用的状态目录是 app/lib/data/stores.dart 里按顺序试出来的，第一个能写就用：
;   1. %APPDATA%\<CompanyName>\<ProductName>\lanplayer   （正常路径，见文件头注释）
;   2. <安装目录>\state                                  （便携安装、只能写安装目录的沙盒）
;   3. %LOCALAPPDATA%\lanplayer
;   4. %TEMP%\lanplayer
; 卸载要把这四处都清一遍，只清第一处会漏掉其余三种情况。前两层的
; %APPDATA%\<Company>\<Product> 用不带 /r 的 RMDir 收尾：目录非空时它什么也不做，
; 不会误删同一家公司名下的其它数据。
!macro PurgeUserData
  RMDir /r "$APPDATA\${APP_COMPANY}\${APP_PRODUCT}\lanplayer"
  RMDir    "$APPDATA\${APP_COMPANY}\${APP_PRODUCT}"
  RMDir    "$APPDATA\${APP_COMPANY}"
  RMDir /r "$LOCALAPPDATA\lanplayer"
  RMDir /r "$INSTDIR\state"
  RMDir /r "$TEMP\lanplayer"
!macroend

; 判断上述任一处是否真的存有配置。结果放在 $R9（1 = 有）。
!macro UserDataExists
  StrCpy $R9 0
  ${If} ${FileExists} "$APPDATA\${APP_COMPANY}\${APP_PRODUCT}\lanplayer\*.*"
    StrCpy $R9 1
  ${ElseIf} ${FileExists} "$LOCALAPPDATA\lanplayer\*.*"
    StrCpy $R9 1
  ${ElseIf} ${FileExists} "$INSTDIR\state\*.*"
    StrCpy $R9 1
  ${ElseIf} ${FileExists} "$TEMP\lanplayer\*.*"
    StrCpy $R9 1
  ${EndIf}
!macroend

; ---------------- 主安装段 ----------------
Section "LanPlayer 主程序" SecCore
  SectionIn RO
  SetShellVarContext current

  !insertmacro StopRunningApp

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

  ; 让开时留下的 <名>.old 到这里再尽力删一次（旧进程多半已退出）
  !insertmacro DeleteMovedAside

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

; ---------------- 卸载：是否连用户数据一起删 ----------------
; 用全局变量而不是 $R8：Section "Uninstall" 开头的 StopRunningApp 宏会改写 $R8/$R9。
Var chkPurge
Var purgeState
Var purgeWanted

; 静默卸载没有页面，只能靠命令行开关表达意图；交互模式默认不勾（保守），
; 用户主动勾上才删。
Function un.onInit
  StrCpy $purgeWanted 0
  ${GetParameters} $R0
  ${GetOptions} $R0 "/PURGE" $R1
  ${If} ${Errors}
    ${GetOptions} $R0 "/PURGE=" $R1
  ${EndIf}
  ${IfNot} ${Errors}
    StrCpy $purgeWanted 1
  ${EndIf}
FunctionEnd

Function un.UserDataPage
  !insertmacro MUI_HEADER_TEXT "卸载选项" "是否同时删除已保存的服务器、设置与缩略图缓存。"
  !insertmacro UserDataExists
  ${If} $R9 == 0
    ; 没有可删的数据就不打扰用户，直接跳过这一页。
    Abort
  ${EndIf}

  nsDialogs::Create 1018
  Pop $0
  ${If} $0 == error
    Abort
  ${EndIf}

  ${NSD_CreateLabel} 0 0 100% 44u "LanPlayer 在你的用户目录里保存了服务器地址、登录信息、播放设置和缩略图缓存。留着它们，重装后可以直接接着用；勾选下面一项，卸载后本机不再残留任何登录信息。"
  Pop $0

  ${NSD_CreateCheckbox} 0 52u 100% 12u "同时删除已保存的服务器列表、设置和缩略图缓存"
  Pop $chkPurge
  ${If} $purgeWanted == 1
    ${NSD_Check} $chkPurge
  ${EndIf}

  nsDialogs::Show
FunctionEnd

Function un.UserDataPageLeave
  ${NSD_GetState} $chkPurge $purgeState
  ${If} $purgeState == ${BST_CHECKED}
    StrCpy $purgeWanted 1
  ${Else}
    StrCpy $purgeWanted 0
  ${EndIf}
FunctionEnd

; ---------------- 卸载 ----------------
Section "Uninstall"
  SetShellVarContext current
  ; 卸载时如果程序还开着，Delete 同样会失败（文件被映像占用）——
  ; 这里也要先把它请退，否则卸载会留一堆删不掉的 DLL。
  !insertmacro StopRunningApp

  ; 还请不退（副本改名、别的进程映射着等），就把它们改名让开再删。
  ; 否则 Delete 对占用文件是静默失败、注册表却已删干净，用户以为卸载成功，
  ; 下次安装又撞上同一批文件。
  ${If} ${FileExists} "$INSTDIR\${APP_DLL}"
    ClearErrors
    FileOpen $R4 "$INSTDIR\${APP_DLL}" a
    ${If} ${Errors}
      !insertmacro MoveAsideLocked "$INSTDIR\${APP_DLL}"
      !insertmacro MoveAsideLocked "$INSTDIR\${APP_EXE}"
    ${Else}
      FileClose $R4
    ${EndIf}
  ${EndIf}

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
  ; 安装时让开留下的 .old：占用方还没退出的话当场删不掉，登记到重启后删。
  Delete /REBOOTOK "$INSTDIR\${APP_DLL}.old"
  Delete /REBOOTOK "$INSTDIR\${APP_EXE}.old"
  Delete "$INSTDIR\uninstall.exe"
  RMDir /REBOOTOK "$INSTDIR"

  ; 被映射的旧文件当场删不掉，只能等重启。留一行日志，排查时能看出这不是没删而是延后删。
  ${If} ${FileExists} "$INSTDIR\${APP_DLL}.old"
    DetailPrint "占用中的旧文件已登记为重启后删除。"
  ${EndIf}

  Delete "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\卸载 ${APP_NAME}.lnk"
  RMDir  "$SMPROGRAMS\${APP_NAME}"
  Delete "$DESKTOP\${APP_NAME}.lnk"

  DeleteRegKey HKCU "Software\Classes\${APP_ID}.Video"
  DeleteRegKey HKCU "Software\${APP_ID}"
  DeleteRegKey HKCU "${UNINST_KEY}"

  ; 用户数据（服务器列表 / 设置 / 缩略图缓存）：由卸载选项页的勾选框决定，
  ; 静默卸载时由命令行开关 /PURGE 决定。
  ${If} $purgeWanted == 1
    DetailPrint "删除已保存的服务器列表、设置和缩略图缓存。"
    !insertmacro PurgeUserData
  ${Else}
    DetailPrint "保留用户数据（$APPDATA\${APP_COMPANY}\${APP_PRODUCT}\lanplayer）。"
  ${EndIf}
SectionEnd
