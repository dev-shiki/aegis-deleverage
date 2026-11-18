$ErrorActionPreference = "Stop"
Set-Location "D:\cache\bounty_hunt\reactive_builder"

$forge = "D:\cache\bounty_hunt\bin\forge.exe"
$cast  = "D:\cache\bounty_hunt\bin\cast.exe"
$baseSepoliaRpc = "https://sepolia.base.org"
$lasnaRpc = "https://lasna-rpc.rnk.dev/"
$omniCallbackProxy = "0x476F44b11F5C942c58f4c8E3d0300E5710743585"
$ethAsset = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE"

$sec = Read-Host -AsSecureString "Masukkan Private Key 0x8e62...D5E6 (input disembunyikan)"
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
$rawPk = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

$env:PRIVATE_KEY = "0x" + $rawPk.Trim().TrimStart("0x")
$rawPk = $null

try {
    $addr = (& $cast wallet address --private-key $env:PRIVATE_KEY).Trim()
    $baseBal = [double]((& $cast balance $addr --rpc-url $baseSepoliaRpc).Trim()) / 1e18
    $lasnaBal = [double]((& $cast balance $addr --rpc-url $lasnaRpc).Trim()) / 1e18
    Write-Host "`n[1/6] Wallet: $addr | Base Sepolia: $([math]::Round($baseBal, 6)) ETH | Lasna: $([math]::Round($lasnaBal, 6)) lREACT" -ForegroundColor Cyan

    Write-Host "`n[2/6] Deploy PriceOracle & ProtectedVault ke Base Sepolia (Omni Proxy $omniCallbackProxy)..." -ForegroundColor Cyan
    & $forge script script/DeployOriginAndCallback.s.sol:DeployOriginAndCallback --rpc-url $baseSepoliaRpc --broadcast

    $baseRun = Get-Content "broadcast\DeployOriginAndCallback.s.sol\84532\run-latest.json" -Raw | ConvertFrom-Json
    $oracleAddr = ($baseRun.transactions | Where-Object { $_.contractName -eq "PriceOracle" -and $_.contractAddress } | Select-Object -First 1).contractAddress
    $vaultAddr  = ($baseRun.transactions | Where-Object { $_.contractName -eq "ProtectedVault" -and $_.contractAddress } | Select-Object -First 1).contractAddress
    if (-not $oracleAddr -or -not $vaultAddr) { throw "Gagal membaca alamat PriceOracle / ProtectedVault" }
    $env:PRICE_ORACLE = $oracleAddr
    $env:PROTECTED_VAULT = $vaultAddr
    Write-Host "  PriceOracle    : $oracleAddr" -ForegroundColor Green
    Write-Host "  ProtectedVault : $vaultAddr" -ForegroundColor Green

    Write-Host "`n[3/6] Deploy AegisDeleverage (reactive-lib-omni) ke Reactive Lasna (5318007)..." -ForegroundColor Cyan
    & $forge script script/DeployReactive.s.sol:DeployReactive --rpc-url $lasnaRpc --broadcast --legacy
    $lasnaRun = Get-Content "broadcast\DeployReactive.s.sol\5318007\run-latest.json" -Raw | ConvertFrom-Json
    $aegisAddr = ($lasnaRun.transactions | Where-Object { $_.contractName -eq "AegisDeleverage" -and $_.contractAddress } | Select-Object -First 1).contractAddress
    $aegisTx   = ($lasnaRun.transactions | Where-Object { $_.contractName -eq "AegisDeleverage" -and $_.hash } | Select-Object -First 1).hash
    if (-not $aegisAddr) { throw "Gagal membaca alamat AegisDeleverage" }
    $env:AEGIS_REACTIVE = $aegisAddr
    Write-Host "  AegisDeleverage: $aegisAddr (Tx: $aegisTx)" -ForegroundColor Green

    Write-Host "`n[4/6] Bind CallbackSender, Deposit, Borrow, dan ConfigureGuard di Base Sepolia..." -ForegroundColor Cyan
    & $forge script script/LiveDemoFlow.s.sol:LiveDemoFlow --rpc-url $baseSepoliaRpc --broadcast
    $demoRun = Get-Content "broadcast\LiveDemoFlow.s.sol\84532\run-latest.json" -Raw | ConvertFrom-Json
    $demoHashes = @($demoRun.transactions | ForEach-Object { @{ function = $_.function; hash = $_.hash } })

    Write-Host "`n[5/6] Menunggu 8 detik agar ReactVM mensinkronkan GuardConfigured di blok terpisah..." -ForegroundColor Yellow
    Start-Sleep -Seconds 8

    Write-Host "`n[6/6] Menjalankan 3-Run Live Latency Benchmark (`$1,900 -> `$1,750 -> `$1,600)..." -ForegroundColor Cyan
    $topicProt = (& $cast keccak "ProtectionExecuted(address,address,uint256,uint256,uint256,uint256,uint256)").Trim()
    $runs = @()
    $csvRows = @("run,price_usd,origin_tx,origin_block,origin_timestamp,callback_tx,callback_block,callback_timestamp,latency_blocks,latency_seconds")

    $crashPrices = @(
        @{ usd = 1900; e8 = "190000000000" },
        @{ usd = 1750; e8 = "175000000000" },
        @{ usd = 1600; e8 = "160000000000" }
    )

    for ($idx = 0; $idx -lt $crashPrices.Count; $idx++) {
        $runNum = $idx + 1
        $target = $crashPrices[$idx]
        if ($idx -gt 0) {
            Write-Host "  Cooldown buffer 7 detik sebelum trigger #$runNum..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 7
        }

        $crashOut = (& $cast send $oracleAddr "setPrice(address,uint256)" $ethAsset $target.e8 --rpc-url $baseSepoliaRpc --private-key $env:PRIVATE_KEY --json) | ConvertFrom-Json
        $originHash = $crashOut.transactionHash
        $originBlk  = [Convert]::ToInt64($crashOut.blockNumber, 16)
        $originBlkInfo = (& $cast block $originBlk --rpc-url $baseSepoliaRpc --json) | ConvertFrom-Json
        $originTs = [Convert]::ToInt64($originBlkInfo.timestamp, 16)
        Write-Host "  [Run #$runNum @ `$$($target.usd)] Origin Tx: $originHash (Blk #$originBlk)" -ForegroundColor White

        $cbTx = ""
        $cbBlk = 0
        $cbTs = 0
        for ($p = 1; $p -le 30; $p++) {
            Start-Sleep -Seconds 1
            $rpcBody = @{
                jsonrpc = "2.0"
                id = 1
                method = "eth_getLogs"
                params = @(@{
                    address = $vaultAddr
                    topics = @($topicProt)
                    fromBlock = "0x$($originBlk.ToString('x'))"
                    toBlock = "latest"
                })
            } | ConvertTo-Json -Depth 5
            $logsResp = (Invoke-RestMethod -Uri $baseSepoliaRpc -Method Post -ContentType "application/json" -Body $rpcBody).result
            if ($logsResp -and $logsResp.Count -gt 0) {
                $ev = $logsResp[-1]
                $cbTx  = $ev.transactionHash
                $cbBlk = [Convert]::ToInt64($ev.blockNumber, 16)
                $cbBlkInfo = (& $cast block $cbBlk --rpc-url $baseSepoliaRpc --json) | ConvertFrom-Json
                $cbTs = [Convert]::ToInt64($cbBlkInfo.timestamp, 16)
                break
            }
        }

        if ($cbTx) {
            $dBlk = $cbBlk - $originBlk
            $dSec = $cbTs - $originTs
            Write-Host "    -> Callback Delivered: $cbTx (Blk #$cbBlk | +$dBlk blocks | ${dSec}s)" -ForegroundColor Green
            $csvRows += "$runNum,$($target.usd),$originHash,$originBlk,$originTs,$cbTx,$cbBlk,$cbTs,$dBlk,$dSec"
            $runs += [ordered]@{
                run = $runNum
                priceUsd = $target.usd
                originTx = $originHash
                originBlock = $originBlk
                originTimestamp = $originTs
                callbackTx = $cbTx
                callbackBlock = $cbBlk
                callbackTimestamp = $cbTs
                latencyBlocks = $dBlk
                latencySeconds = $dSec
            }
        } else {
            Write-Host "    -> Callback belum terdeteksi dalam 30 detik." -ForegroundColor Yellow
            $csvRows += "$runNum,$($target.usd),$originHash,$originBlk,$originTs,,,,,,"
            $runs += [ordered]@{
                run = $runNum
                priceUsd = $target.usd
                originTx = $originHash
                originBlock = $originBlk
                originTimestamp = $originTs
                callbackTx = ""
                callbackBlock = $null
                callbackTimestamp = $null
                latencyBlocks = $null
                latencySeconds = $null
            }
        }
    }

    $csvRows | Set-Content -Path "latency.csv" -Encoding utf8

    $summary = [ordered]@{
        priceOracle = $oracleAddr
        protectedVault = $vaultAddr
        aegisDeleverage = $aegisAddr
        omniCallbackProxy = $omniCallbackProxy
        deployer = $addr
        deployLasnaTx = $aegisTx
        setupTransactions = $demoHashes
        runs = $runs
    } | ConvertTo-Json -Depth 4
    $summary | Set-Content -Path "deployed_omni.json" -Encoding utf8
    Write-Host "`n=== SELESAI! Benchmark & tx tersimpan di latency.csv dan deployed_omni.json ===" -ForegroundColor Cyan
} finally {
    Remove-Item Env:PRIVATE_KEY -ErrorAction SilentlyContinue
    Remove-Item Env:PRICE_ORACLE -ErrorAction SilentlyContinue
    Remove-Item Env:PROTECTED_VAULT -ErrorAction SilentlyContinue
    Remove-Item Env:AEGIS_REACTIVE -ErrorAction SilentlyContinue
    Write-Host "Private key telah dihapus dari memori sesi PowerShell." -ForegroundColor DarkGray
}
