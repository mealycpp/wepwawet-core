# REVIEWER: run the adversarial TB (review/tb/tb_adv_seal.sv) under XSim (reference simulator). NOT queued by the reviewer.
# Usage (from a Vivado Tcl job):  powershell -File run_adv_xsim.ps1 -SrcDir <seal_v8\src_p2> -Defines ADV_V8,ADV_P2[,ADV_DET] -Vec vec_7
param([string]$SrcDir, [string]$Defines='ADV_V8,ADV_P2', [string]$Vec='vec_7', [string]$Tag='p2h', [string]$PlusArgs='')
$ErrorActionPreference='Continue'
$review = Split-Path -Parent $PSScriptRoot
$root   = '<WORKDIR>\04_WORK'
$tools  = 'C:\Xilinx\Vivado\2022.2\bin'; $env:PATH="$tools;$env:PATH"
$out = Join-Path $review ("xsim_runs\" + (Get-Date -Format 'yyyyMMdd_HHmmss') + "_$Tag" + "_$Vec")
New-Item -ItemType Directory -Force -Path (Join-Path $out 'vectors'),(Join-Path $out 'vvectors'),(Join-Path $out 'capture') | Out-Null
function L($d){ if (Test-Path (Join-Path $SrcDir $d)) { @(Get-ChildItem (Join-Path $SrcDir $d) -File | Where-Object {$_.Extension -in '.v','.sv'} | Sort-Object Name | ForEach-Object {$_.FullName}) } else { @() } }
$files = (L 'rtl') + @((Join-Path $SrcDir 'reference\wcore_scratchpad.v')) + (L 'hls_ntt') + (L 'hls_intt') + (L 'hls_shake') + (L 'hls_shake128') + (L 'hls_poly') +
         @(Get-ChildItem $SrcDir -File | Where-Object {$_.Extension -in '.v','.sv'} | ForEach-Object {$_.FullName}) + @((Join-Path $review 'tb\tb_adv_seal.sv'))
Copy-Item (Join-Path $root "vectors\$Vec\*.mem") (Join-Path $out 'vectors')
Copy-Item (Join-Path $review "vectors_K\$Vec\K_4x64.mem") (Join-Path $out 'vectors') -ErrorAction SilentlyContinue
Copy-Item (Join-Path $root 'verify_v1\vectors\valid\*.mem') (Join-Path $out 'vvectors')
foreach($d in 'hls_ntt','hls_intt'){ Get-ChildItem (Join-Path $SrcDir $d) -Filter '*.dat' -File | ForEach-Object { Copy-Item $_.FullName $out -Force } }
$dargs = @(); foreach($d in $Defines.Split(',')) { if ($d) { $dargs += @('-d', $d) } }
$files += @(Get-ChildItem (Join-Path $SrcDir 'trng') -Filter '*.v' -File -ErrorAction SilentlyContinue | ForEach-Object {$_.FullName})
$pargs = @(); foreach($p in $PlusArgs.Split(',')) { if ($p) { $pargs += @('-testplusarg', $p) } }
Push-Location $out
# a .prj file avoids "xvlog.bat : The command line is too long" (seen in the BUILDER p2/p3 quick runs)
$prj = @(); foreach($f in $files) { $prj += "sv work `"$f`"" }; $prj | Out-File -Encoding ascii (Join-Path $out 'adv.prj')
& (Join-Path $tools 'xvlog.bat') @dargs -prj (Join-Path $out 'adv.prj') *> 01_compile.log
& (Join-Path $tools 'xelab.bat') tb_adv_seal -s sim_adv *> 02_elab.log
& (Join-Path $tools 'xsim.bat') sim_adv -runall @pargs *> 03_sim.log
Pop-Location
"XSIM_ADV_DONE $out" | Out-File -Append -Encoding ascii (Join-Path $review 'xsim_runs\SUMMARY.txt')
