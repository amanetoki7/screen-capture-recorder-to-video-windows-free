<#
.SYNOPSIS
  Builds screen-capture-recorder.dll (Win32) and screen-capture-recorder-x64.dll (x64).
.DESCRIPTION
  Needs Visual Studio 2019 or newer with the "Desktop development with C++" workload (located via vswhere).
  The DirectShow BaseClasses are vendored in .\BaseClasses (MIT, from microsoft/Windows-classic-samples) and get
  compiled into strmbase.lib first, so nothing else has to be installed. Everything links the static CRT (/MT), so
  the dlls don't depend on a particular MSVC redistributable.
  The outputs go where the installer (..\innosetup_installer_options.iss) expects them:
    Win32\Release\screen-capture-recorder.dll
    x64\releasex64\screen-capture-recorder-x64.dll
.EXAMPLE
  .\build.ps1                  # both
  .\build.ps1 -Platforms x64   # just the 64 bit one
  .\build.ps1 -Clean           # throw away the intermediate obj dirs first
#>
param(
  [ValidateSet('x86', 'x64')] [string[]] $Platforms = @('x86', 'x64'),
  [switch] $Clean
)
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw "vswhere.exe not found: install Visual Studio 2019+ with the 'Desktop development with C++' workload" }
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) { throw "no Visual Studio installation with the C++ build tools was found" }
$vcvarsall = Join-Path $vsPath 'VC\Auxiliary\Build\vcvarsall.bat'

# copy the environment vcvarsall sets up (PATH, INCLUDE, LIB, ...) into this process
function Import-VcEnvironment([string] $arch) {
  $lines = cmd /c "call `"$vcvarsall`" $arch > nul 2>&1 && set"
  if ($LASTEXITCODE -ne 0) { throw "vcvarsall.bat $arch failed" }
  foreach ($line in $lines) {
    if ($line -match '^([^=]+)=(.*)$') { Set-Item -Path ('env:' + $matches[1]) -Value $matches[2] }
  }
}

function Invoke-Tool([string] $tool, [string[]] $arguments) {
  & $tool @arguments
  if ($LASTEXITCODE -ne 0) { throw "$tool failed with exit code $LASTEXITCODE" }
}

$commonCl = @('/nologo', '/c', '/MP', '/MT', '/O2', '/Oi', '/W3', '/EHsc', '/Zc:wchar_t',
  '/DWIN32', '/DNDEBUG', '/D_WINDOWS', '/DUNICODE', '/D_UNICODE', '/D_CRT_SECURE_NO_WARNINGS', "/I$src\BaseClasses")

foreach ($arch in $Platforms) {
  Write-Host "=== building $arch ===" -ForegroundColor Cyan
  Import-VcEnvironment $arch
  if ($arch -eq 'x64') { $outDir = "$src\x64\releasex64"; $dllName = 'screen-capture-recorder-x64.dll'; $machine = 'X64' }
  else                 { $outDir = "$src\Win32\Release"; $dllName = 'screen-capture-recorder.dll';     $machine = 'X86' }
  $objDir = "$outDir\obj"
  if ($Clean -and (Test-Path $objDir)) { Remove-Item -Recurse -Force $objDir }
  New-Item -ItemType Directory -Force "$objDir\BaseClasses" | Out-Null

  # 1. strmbase.lib from the vendored BaseClasses
  $baseSources = Get-ChildItem "$src\BaseClasses\*.cpp" | ForEach-Object { $_.FullName }
  Invoke-Tool cl ($commonCl + @("/Fo$objDir\BaseClasses\") + $baseSources)
  $baseObjs = Get-ChildItem "$objDir\BaseClasses\*.obj" | ForEach-Object { $_.FullName }
  Invoke-Tool lib (@('/nologo', "/OUT:$objDir\strmbase.lib") + $baseObjs)

  # 2. the filter itself
  $filterSources = 'DibHelper.cpp', 'parent.cpp', 'PushSourceDesktop.cpp', 'PushSourceDesktopAccessories.cpp', 'setup.cpp' | ForEach-Object { "$src\$_" }
  Invoke-Tool cl ($commonCl + @('/D_USRDLL', '/DPUSHSOURCE_EXPORTS', "/Fo$objDir\") + $filterSources)
  Invoke-Tool rc @('/nologo', "/fo$objDir\PushSource.res", "$src\PushSource.rc")
  $filterObjs = $filterSources | ForEach-Object { "$objDir\" + [IO.Path]::GetFileNameWithoutExtension($_) + '.obj' }
  $linkArgs = @('/nologo', '/DLL', "/DEF:$src\PushSource.def", "/OUT:$outDir\$dllName", '/SUBSYSTEM:WINDOWS', "/MACHINE:$machine", '/OPT:REF', '/OPT:ICF') +
    $filterObjs + @("$objDir\PushSource.res", "$objDir\strmbase.lib",
    'strmiids.lib', 'wmcodecdspuuid.lib', 'winmm.lib', 'shlwapi.lib', 'shell32.lib', 'ole32.lib', 'oleaut32.lib', 'uuid.lib', 'advapi32.lib', 'user32.lib', 'gdi32.lib', 'kernel32.lib')
  Invoke-Tool link $linkArgs
  Write-Host "built $outDir\$dllName" -ForegroundColor Green
}
