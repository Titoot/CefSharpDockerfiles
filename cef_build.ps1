Set-StrictMode -version latest;
$ErrorActionPreference = "Stop";
$WorkingDir = split-path -parent $MyInvocation.MyCommand.Definition;
. (Join-Path $WorkingDir 'functions.ps1')


Function CopyBinaries{
	if (@(dir -Filter "cef_binary_*_windows32.$env:BINARY_EXT" "c:/code/chromium_git/chromium/src/cef/binary_distrib/").Count -ne 1){
		throw "Not able to find win32 file as expected";
	}
	if (@(dir -Filter "cef_binary_*_windows64.$env:BINARY_EXT" "c:/code/chromium_git/chromium/src/cef/binary_distrib/").Count -ne 1){
		throw "Not able to find win64 file as expected";
	}

	mkdir c:/code/binaries -Force;
	copy-item ("c:/code/chromium_git/chromium/src/cef/binary_distrib/*." + $env:BINARY_EXT) -destination  C:/code/binaries;
	Set-Location -Path /;
	if ($env:CEF_SAVE_SOURCES -eq "1"){
		RunProc -errok -proc ($env:ProgramFiles + "\\7-Zip\\7z.exe") -opts "a -aoa -y -mx=1 -r -tzip c:\code\sources.zip c:/code/chromium_git/chromium";
	}
	echo $null >> c:/code/chromium_git/done
}

$build_args_add = "";
if (! $env:BINARY_EXT){
	$env:BINARY_EXT="zip";
}
if ($env:BINARY_EXT -eq "7z"){
	$env:CEF_COMMAND_7ZIP="C:/Program Files/7-Zip/7z.exe";
}
$env:CEF_ARCHIVE_FORMAT = $env:BINARY_EXT;
if ($env:DUAL_BUILD -eq "1" -and $env:CHROME_BRANCH -lt 3396){ #newer builds can take a good bit more time linking just let run with double the proc count
	$cores = ([int]$env:NUMBER_OF_PROCESSORS) + 2; #ninja defaults to number of procs + 2 
	if ($cores % 2 -eq 1){
		$cores +=1;
	}
	$build_args_add = "-j " + ($cores/2);
}
if (Test-Path c:/code/chromium_git/done -PathType Leaf){
	Write-Host "Already Done just copying binaries";
	CopyBinaries;
	exit 0;
}


Function RunBuild{
    [CmdletBinding()]
    Param($build_args_add,$version)
    return RunProc -verbose_mode "host" -proc "c:/code/depot_tools/ninja.exe" -opts "$build_args_add -C out/Release_GN_$version cefclient" -no_wait;
}
RunProc -proc "c:/code/depot_tools/python.bat" -errok -opts "c:/code/automate/automate-git.py --download-dir=c:/code/chromium_git --branch=$env:CHROME_BRANCH --no-build --no-debug-build --no-distrib --no-depot-tools-update";
Set-Location -Path c:/code/chromium_git/chromium/src/cef;
if (! (Test-Path /code/chromium_git/already_patched -PathType Leaf)){
    copy c:/code/*.ps1 .
    copy c:/code/*.diff .
    ./cef_patch.ps1
    "1" > /code/chromium_git/already_patched    
    if ($env:GN_DEFINES -contains "proprietary_codecs" -and $env:CHROME_BRANCH -lt 3396){
    	#I was unable to generate a patch that worked across branches so manually patching the file per: https://bitbucket.org/chromiumembedded/cef/issues/2352/windows-3239-build-fails-due-to-missing
    	#this is only needed for versions < 3396
    	$str = [system.io.file]::ReadAllText("c:/code/chromium_git/chromium/src/cef/BUILD.gn");
    	$str = $str -replace "deps = \[\s+`"//components/crash/core/common`",", "deps = [`n      `"//components/crash/core/common`",`n      `"//media:media_features`",";
    	$str | Out-File "c:/code/chromium_git/chromium/src/cef/BUILD.gn" -Encoding ASCII;
    }
    RunProc -proc "c:/code/chromium_git/chromium/src/cef/cef_create_projects.bat" -errok -opts "";
}
Set-Location -Path c:/code/chromium_git/chromium/src;
$px64 = $null;
$px86 = $null;
$MAX_FAILURES=20;
$x86_fails=-1;
$x64_fails=-1;
#There can be a race conditions we try to patch out the media failures one above
while ($true){
	$retry=$false;
    if ($px64 -eq $null -or ($px64.HasExited -and $px64.ExitCode -ne 0 -and $x64_fails -lt $MAX_FAILURES)){
        $x64_fails++;
        $px64 = RunBuild -build_args_add $build_args_add -version "x64";
        if ($env:DUAL_BUILD -ne "1"){
        	$px64.WaitForExit();
        	Continue; #fully build one before trying the other
        }
        $retry=$true;
    }
    if ($px86 -eq $null -or ($px86.HasExited -and $px86.ExitCode -ne 0 -and $x86_fails -lt $MAX_FAILURES) ){
        $x86_fails++;
        $px86 = RunBuild -build_args_add $build_args_add -version "x86";
        if ($env:DUAL_BUILD -ne "1"){
        	$px86.WaitForExit();
        }
        $retry=$true;
    }    
    if ($px64.HasExited -and $px86.HasExited -and ! $retry){
    	break;
    }
    Start-Sleep -s 15
}
$px64.WaitForExit();
$px86.WaitForExit();
if ($px64.ExitCode -ne 0){
	throw "x64 build failed with $($px64.ExitCode)";
}
if ($px86.ExitCode -ne 0){
	throw "x86 build failed with $($px86.ExitCode)";
}

Set-Location -Path C:/code/chromium_git/chromium/src/cef/tools/;
RunProc -proc "C:/code/chromium_git/chromium/src/cef/tools/make_distrib.bat" -opts "--ninja-build --allow-partial";
RunProc -proc "C:/code/chromium_git/chromium/src/cef/tools/make_distrib.bat" -opts "--ninja-build --allow-partial --x64-build";

CopyBinaries;
#Remove-Item -Recurse -Force c:/code/chromium_git/chromium; #no longer removing source by default as stored in a volume now