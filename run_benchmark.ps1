$ErrorActionPreference = "Stop"
Set-Location "D:\cache\bounty_hunt\reactive_builder"

$cast = "D:\cache\bounty_hunt\bin\cast.exe"
$baseSepoliaRpc = "https://sepolia.base.org"
$oracleAddr = "0x06df840a5ae025a8d86dde667e02e7cff0cff4c4"
$vaultAddr  = "0x8aed78c80024c2c5d8e90f346b87298174cebcce"
$aegisAddr  = "0x5dee49560fce0a1bc26ebb6591f58b7a2af313f1"
$ethAsset   = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE"
$topicProt  = "0x00596cd9a42e74fe9bc252d2fac3e42e35c6ab4777bf5d08d937ae4f662a52a2"

$sec = Read-Host -AsSecureString "Masukkan Private Key 0x8e62...D5E6 (input disembunyikan)"
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
$rawPk = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
$pk = "0x" + $rawPk.Trim().TrimStart("0x")
$rawPk = $null

try {
    $addr = (& $cast wallet address --private-key $pk).Trim()

    # Seed Run #1 already verified on-chain
    $runs = @(
        [ordered]@{
            run = 1; priceUsd = 1900
            originTx = "0xa7f55f1a5548445c0e6323cfb9d1948ff7039bece41f850c85b34218049e8c93"
            originBlock = 60528253; originTimestamp = 1795027519
            callbackTx = "0x2b36077887ec9a78282f8796860f8f852dc4b12d11682041ec2b806838a44037"
            callbackBlock = 60528263; callbackTimestamp = 1795027521
            latencyBlocks = 10; latencySeconds = 2
        }
    )

    $targets = @(
        @{ run = 2; usd = 1750; e8 = "175000000000" },
        @{ run = 3; usd = 1600; e8 = "160000000000" }
    )

    foreach ($t in $targets) {
        $crashOut = (& $cast send $oracleAddr "setPrice(address,uint256)" $ethAsset $t.e8 --rpc-url $baseSepoliaRpc --private-key $pk --json) | ConvertFrom-Json
        $originHash = $crashOut.transactionHash
        $originBlk  = [Convert]::ToInt64($crashOut.blockNumber, 16)
        $originTs   = [Convert]::ToInt64(((& $cast block $originBlk --rpc-url $baseSepoliaRpc --json) | ConvertFrom-Json).timestamp, 16)
        Write-Host "[Run #$($t.run) @ `$$($t.usd)] Origin Tx: $originHash (Blk #$originBlk)" -ForegroundColor White

        $cbTx = ""; $cbBlk = 0; $cbTs = 0
        for ($p = 1; $p -le 30; $p++) {
            Start-Sleep -Seconds 1
            $rpcBody = @{
                jsonrpc = "2.0"; id = 1; method = "eth_getLogs"
                params = @(@{ address = $vaultAddr; topics = @($topicProt); fromBlock = "0x$($originBlk.ToString('x'))"; toBlock = "latest" })
            } | ConvertTo-Json -Depth 5
            $logsResp = (Invoke-RestMethod -Uri $baseSepoliaRpc -Method Post -ContentType "application/json" -Body $rpcBody).result
            if ($logsResp -and $logsResp.Count -gt 0) {
                $ev = $logsResp[-1]
                $cbTx  = $ev.transactionHash
                $cbBlk = [Convert]::ToInt64($ev.blockNumber, 16)
                $cbTs  = [Convert]::ToInt64(((& $cast block $cbBlk --rpc-url $baseSepoliaRpc --json) | ConvertFrom-Json).timestamp, 16)
                break
            }
        }
        $dBlk = if ($cbBlk -gt 0) { $cbBlk - $originBlk } else { $null }
        $dSec = if ($cbTs -gt 0) { $cbTs - $originTs } else { $null }
        Write-Host "  -> Callback: $cbTx (Blk #$cbBlk | +$dBlk blocks | ${dSec}s)" -ForegroundColor Green
        $runs += [ordered]@{
            run = $t.run; priceUsd = $t.usd
            originTx = $originHash; originBlock = $originBlk; originTimestamp = $originTs
            callbackTx = $cbTx; callbackBlock = $cbBlk; callbackTimestamp = $cbTs
            latencyBlocks = $dBlk; latencySeconds = $dSec
        }
        Start-Sleep -Seconds 7
    }

    $csv = @("run,price_usd,origin_tx,origin_block,origin_timestamp,callback_tx,callback_block,callback_timestamp,latency_blocks,latency_seconds")
    foreach ($r in $runs) {
        $csv += "$($r.run),$($r.priceUsd),$($r.originTx),$($r.originBlock),$($r.originTimestamp),$($r.callbackTx),$($r.callbackBlock),$($r.callbackTimestamp),$($r.latencyBlocks),$($r.latencySeconds)"
    }
    $csv | Set-Content -Path "latency.csv" -Encoding utf8
    ([ordered]@{
        priceOracle = $oracleAddr; protectedVault = $vaultAddr; aegisDeleverage = $aegisAddr
        omniCallbackProxy = "0x476F44b11F5C942c58f4c8E3d0300E5710743585"; deployer = $addr
        runs = $runs
    } | ConvertTo-Json -Depth 4) | Set-Content -Path "deployed_omni.json" -Encoding utf8
    Write-Host "`nSelesai! 3-run latency.csv & deployed_omni.json tersimpan." -ForegroundColor Cyan
} finally {
    $pk = $null
}
