param([string]$SignCases='vec_hint,vec_b80,vec_7,vec_6,vec_3,vec_23',[string]$VerifyCases='valid,bad_msg',[string]$SrcDir='',[string]$Tag='seal',[string]$SignTb='',[string]$VerifyTb='',[string]$SealCases='',[string]$SealTb='',[string]$Defines='',[string]$SignTop='tb_sign_multi',[string]$HedgedCases='',[string]$KeygenCases='',[string]$TbDir='',[string]$PinCases='')
$ErrorActionPreference='Continue'
$here=$PSScriptRoot
$src= if($SrcDir){$SrcDir}else{Join-Path $here 'src'}
$tools='C:\Xilinx\Vivado\2022.2\bin'
$env:PATH="$tools;$env:PATH"
$stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
$base=Join-Path $here "run_${stamp}_$Tag"
New-Item -ItemType Directory -Path $base -Force | Out-Null
function L($d){@(Get-ChildItem (Join-Path $src $d) -File | Where-Object {$_.Extension -in '.v','.sv'} | Sort-Object Name | ForEach-Object {$_.FullName})}
$rtl=(L 'rtl')+@((Join-Path $src 'reference\wcore_scratchpad.v'))+(L 'hls_ntt')+(L 'hls_intt')+(L 'hls_shake')+(L 'hls_shake128')+(L 'hls_poly')+@(Get-ChildItem $src -File | Where-Object {$_.Extension -in '.v','.sv'} | Sort-Object Name | ForEach-Object {$_.FullName})
function Run($name,$tb,$top,$vecdir,$extra,$vv){
  $out=Join-Path $base $name
  New-Item -ItemType Directory -Path (Join-Path $out 'vectors'),(Join-Path $out 'capture') -Force | Out-Null
  Copy-Item (Join-Path $vecdir '*.mem') (Join-Path $out 'vectors')
  if($vv){ New-Item -ItemType Directory -Path (Join-Path $out 'vvec') -Force | Out-Null; Copy-Item (Join-Path $vroot "verify_v1\vectors\$vv\*.mem") (Join-Path $out 'vvec') }
  foreach($d in 'hls_ntt','hls_intt','hls_poly','hls_shake','hls_shake128'){Get-ChildItem (Join-Path $src $d) -Filter '*.dat' -File | ForEach-Object {Copy-Item $_.FullName $out -Force}}
  Push-Location $out
  $dargs=@(); foreach($d in $Defines.Split(',')){ if($d){$dargs+=@('-d',$d)} }
  # project file instead of a long command line (cmd.exe 8191-char limit)
  ($rtl+@($tb) | ForEach-Object { 'sv work "' + $_ + '"' }) | Out-File -Encoding ascii files.prj
  & (Join-Path $tools 'xvlog.bat') -prj files.prj @dargs *> 01_compile.log
  & (Join-Path $tools 'xelab.bat') $top -s sim_$top *> 02_elab.log
  & (Join-Path $tools 'xsim.bat') sim_$top -runall $extra *> 03_sim.log
  Pop-Location
  "$name SIM_EXIT=$LASTEXITCODE" | Out-File -Append -Encoding ascii (Join-Path $base 'SUMMARY.txt')
}
$vroot='<WORKDIR>\04_WORK'
foreach($c in $SignCases.Split(',')){ if(-not $c){continue}
  $vd= if(Test-Path (Join-Path $here "vectors\$c")){Join-Path $here "vectors\$c"}elseif(Test-Path (Join-Path $vroot "omega_v1\vectors\$c")){Join-Path $vroot "omega_v1\vectors\$c"}else{Join-Path $vroot "vectors\$c"}
  Run "sign_$c" $(if($SignTb){$SignTb}else{Join-Path $here "tb\$SignTop.sv"}) $SignTop $vd @() }
foreach($c in $VerifyCases.Split(',')){ if(-not $c){continue}
  Run "verify_$c" $(if($VerifyTb){$VerifyTb}else{Join-Path $here 'tb\tb_verify_axil.sv'}) 'tb_verify_axil' (Join-Path $vroot "verify_v1\vectors\$c") @() }
foreach($cc in $SealCases.Split(',')){ if(-not $cc){continue}
  $c=$cc.Split(':')[0]; $vv= if($cc.Contains(':')){$cc.Split(':')[1]}else{''}
  $vd= if(Test-Path (Join-Path $here "vectors\$c")){Join-Path $here "vectors\$c"}elseif(Test-Path (Join-Path $vroot "omega_v1\vectors\$c")){Join-Path $vroot "omega_v1\vectors\$c"}else{Join-Path $vroot "vectors\$c"}
  Run "seal_$c" $(if($SealTb){$SealTb}else{Join-Path $here 'tb\tb_seal.sv'}) 'tb_seal' $vd @() $vv }
foreach($c in $HedgedCases.Split(',')){ if(-not $c){continue}
  Run "hedged_$c" $(Join-Path $(if($TbDir){$TbDir}else{Join-Path $here 'tb'}) 'tb_hedged.sv') 'tb_hedged' (Join-Path $here "vectors\$c") @() }
foreach($c in $KeygenCases.Split(',')){ if(-not $c){continue}
  Run "keygen_$c" $(Join-Path $(if($TbDir){$TbDir}else{Join-Path $here 'tb'}) 'tb_keygen.sv') 'tb_keygen' (Join-Path $here "vectors\$c") @() }
foreach($c in $PinCases.Split(',')){ if(-not $c){continue}
  Run "pin_$c" $(Join-Path $(if($TbDir){$TbDir}else{Join-Path $here 'tb'}) 'tb_pin.sv') 'tb_pin' (Join-Path $here "vectors\$c") @() }
'ALL_SIMS_FINISHED' | Out-File -Append -Encoding ascii (Join-Path $base 'SUMMARY.txt')
